// 受信サーバのセキュリティ系（Issue #19 / Red）。契約は server.test.mjs の冒頭コメントを見ろ。
//
// 値の行き先を全数で数える（lessons #11）。受信したイベント・ヘッダの値が出ていく先:
//   (1) SQLite（events テーブル）           → store.test.mjs / server.test.mjs [SQL]
//   (2) /api/state の JSON                    → ここ [leak]（DB パス等の内部情報を載せない）。値の内容は derive 経由のみ
//   (3) SSE の data                           → sse.test.mjs（検証済みレコードだけ）
//   (4) HTTP エラーレスポンス本文（4xx / 5xx）→ server-reject.test.mjs [schema] 入力値を載せない / ここ [5xx] 内部情報を載せない
//   (5) stderr / stdout のログ                → ここ [log]（in-process は stderr を捕捉、CLI は stdout・stderr の両方）
// 入力値が出ていってはならない先（4）（5）には、入力の「どの部分」でも載らないことを固有マーカーで検査する。

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { basename } from 'node:path';
import {
  cleanupTmp, fixture, getState, openStream, parseSse, postEvent, request, SID, spawnCli, startServer,
} from './helpers.mjs';

after(cleanupTmp);

const base = (event, extra = {}) => ({ schema_version: 1, event, session_id: SID, ...extra });

function captureStderr() {
  const original = process.stderr.write.bind(process.stderr);
  const chunks = [];
  process.stderr.write = (chunk, ...rest) => {
    chunks.push(typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8'));
    const cb = rest.find((x) => typeof x === 'function');
    if (cb) cb();
    return true;
  };
  return { text: () => chunks.join(''), restore: () => { process.stderr.write = original; } };
}

const LEAK_PATTERNS = [/sqlite/i, /database/i, /\.mjs/, /node:/, /not open/i, /statement/i, /\bat\s+\S+\s*\(/, /\n\s+at\s/, /stack/i, /ERR_[A-Z_]+/, /\/(Users|home|var|tmp|private)\//];

function assertNoInternalLeak(body, extra = []) {
  for (const re of LEAK_PATTERNS) assert.ok(!re.test(body), `5xx 本文に内部情報（${re}）: ${body}`);
  for (const s of extra) assert.ok(!body.includes(s), `5xx 本文に ${s} が含まれる: ${body}`);
}

// ---------- [5xx] ----------

test('[5xx] DB を閉じて強制的に失敗させても、本文に例外メッセージ・スタック・パスが出ない（POST / GET state）', async () => {
  const s = await startServer();
  const marker = 'LEAKMARKER_z81c';
  const cap = captureStderr();
  let post;
  let get;
  try {
    s.store.close();
    post = await postEvent(s.port, base('PreToolUse', { tool_name: 'Read', tool_use_id: 'toolu_x', file_path: `${marker}.txt` }));
    get = await getState(s.port);
  } finally { cap.restore(); }
  try {
    for (const r of [post, get]) {
      assert.equal(r.status, 500, r.body);
      assertNoInternalLeak(r.body, [s.dbPath, s.dir, basename(s.dbPath), marker]);
      const parsed = JSON.parse(r.body);
      assert.equal(parsed.data, null);
      assert.equal(parsed.error.code, 'INTERNAL_ERROR');
      assert.equal(typeof parsed.error.message, 'string');
    }
    assert.ok(!cap.text().includes(marker), 'stderr にイベント本文（マーカー）が出た');
    assert.ok(!cap.text().includes(s.dbPath), 'stderr に DB パスが出た');
    // 失敗後もサーバは次のリクエストに応答する（落ちない）
    const again = await request(s.port, { path: '/api/state' });
    assert.equal(again.status, 500);
  } finally { await s.close(); }
});

test('[5xx] 検証で拒否される入力は DB が壊れていても 4xx のまま（DB に触れる前に弾く）', async () => {
  const s = await startServer();
  try {
    s.store.close();
    const r = await postEvent(s.port, { ...fixture('Stop'), cwd: '/x' });
    assert.equal(r.status, 400);
    const ct = await postEvent(s.port, fixture('Stop'), { headers: { 'Content-Type': 'text/plain' } });
    assert.equal(ct.status, 415);
  } finally { await s.close(); }
});

// ---------- [leak] /api/state・SSE ----------

test('[leak] /api/state と SSE に DB パス・一時ディレクトリ・ホーム配下パスが載らない', async () => {
  const s = await startServer();
  try {
    const stream = await openStream(s.port);
    for (const n of ['SessionStart', 'UserPromptSubmit', 'PreToolUse.read']) await postEvent(s.port, fixture(n));
    await stream.waitFor((t) => parseSse(t).length >= 3);
    const state = await request(s.port, { path: '/api/state' });
    for (const text of [state.body, stream.text]) {
      assert.ok(!text.includes(s.dbPath));
      assert.ok(!text.includes(s.dir));
      assert.ok(!/\/(Users|home)\//.test(text));
    }
    stream.destroy();
  } finally { await s.close(); }
});

// ---------- [log] ----------

test('[log] 受理・拒否・不正入力の全経路で stderr にイベント本文・ヘッダ値・DB パスを出さない（in-process）', async () => {
  const s = await startServer();
  const marker = 'LOGMARKER_5e7b';
  const cap = captureStderr();
  try {
    await postEvent(s.port, base('PreToolUse', { tool_name: 'Bash', tool_use_id: 'toolu_l1', bash_command: 'logmarkercmd', file_path: `${marker}.txt` }));
    await postEvent(s.port, { ...base('Stop'), session_id: `bad ${marker}` });
    await postEvent(s.port, null, { raw: `{"x":"${marker}` });
    await postEvent(s.port, base('Stop'), { headers: { Host: `${marker}.example` } });
    await postEvent(s.port, base('Stop'), { headers: { Origin: `http://${marker}.example` } });
    await postEvent(s.port, base('Stop'), { headers: { 'Content-Type': `text/${marker}` } });
    await request(s.port, { path: `/${marker}` });
    await request(s.port, { path: '/api/state', headers: { 'X-Marker': marker } });
  } finally { cap.restore(); await s.close(); }
  const logged = cap.text();
  assert.ok(!logged.includes('LOGMARKER'), `stderr にマーカーが出た: ${logged.slice(0, 300)}`);
  assert.ok(!logged.includes('logmarkercmd'));
  assert.ok(!logged.includes(s.dbPath));
});

test('[log] CLI の stdout / stderr にもイベント本文・ヘッダ値を出さない（行き先: stdout・stderr の両方）', async () => {
  const marker = 'CLIMARKER_8f3a';
  const cli = spawnCli({});
  try {
    const { port } = await cli.listening;
    await postEvent(port, base('PreToolUse', { tool_name: 'Bash', tool_use_id: 'toolu_c1', bash_command: 'climarkercmd', file_path: `${marker}.txt` }));
    await postEvent(port, { ...base('Stop'), session_id: `bad ${marker}` });
    await postEvent(port, null, { raw: `{"x":"${marker}` });
    await postEvent(port, base('Stop'), { headers: { Host: `${marker}.example` } });
    await postEvent(port, base('Stop'), { headers: { Origin: `http://${marker}.example` } });
    await request(port, { path: `/${marker}` });
    await request(port, { path: '/api/state' });
  } finally { await cli.stop(); }
  const all = `${cli.out.stdout}\n${cli.out.stderr}`;
  assert.ok(!all.includes('CLIMARKER'), `ログにマーカーが出た: ${all.slice(0, 400)}`);
  assert.ok(!all.includes('climarkercmd'));
});

// ---------- 既知の限界（security.md「監視の限界（受信側）」の既知の限界として固定） ----------

test('known_limit_local_process_can_write: 同一端末の任意プロセスは Host / Origin を正しく付ければ認証なしで書き込め、読み出せる', async () => {
  // 認証を持たない（叩き台の前提）。Host / Origin / Content-Type はブラウザ経由の攻撃を塞ぐだけで、
  // 同一端末のプロセスが自分で正しいヘッダを付けるのは止められない。セキュリティ境界ではない。
  const s = await startServer();
  try {
    const hdr = { Host: `localhost:${s.port}`, Origin: `http://localhost:${s.port}` };
    const forged = base('SubagentStart', { session_id: 'forged-session-0001', agent_id: 'f0f0f0f0', agent_type: 'sub-agent-forged' });
    const w = await postEvent(s.port, forged, { headers: hdr });
    assert.equal(w.status, 201, '認証なしで書き込めてしまう（既知の限界）');
    const r = await request(s.port, { path: '/api/state', headers: hdr });
    assert.equal(r.status, 200, '認証なしで読み出せてしまう（既知の限界）');
    const session = JSON.parse(r.body).sessions.find((x) => x.session_id === 'forged-session-0001');
    assert.ok(session, '偽造した session がそのまま状態に載る');
    assert.equal(session.tree.children[0].agent_type, 'sub-agent-forged');
    assert.equal(w.headers.authorization, undefined);
  } finally { await s.close(); }
});
