// サーバのループ状態配信（Issue #22 / Red）。server/server.mjs の契約テスト。読み取り自体は loop-state.test.mjs。
//
// ════════════════════════════════════════════════════════════════════════════
//  Coder への契約
// ════════════════════════════════════════════════════════════════════════════
//  createServer({ ..., loopStatePath, loopPollMs })
//    loopStatePath 省略時は DEFAULT_LOOP_STATE_PATH（export。<リポジトリ>/.claude/memory/loop-state.json を server.mjs の位置から導出）
//    loopPollMs 既定 2000。テストは 50ms 程度に縮める。fs.watch は使わない（ポーリング）
//  CLI: process.env.MONITOR_LOOP_STATE があればそれを loopStatePath にする
//  GET /api/state の本文に loop（= readLoopState の結果）を足す。sessions と last_seq は変えない
//  起動時に 1 回読む（最初の /api/state から loop が載る）。以後 loopPollMs ごとに読み、前回と内容が変わったら
//    (a) /api/state のキャッシュを新しい loop に差し替える
//    (b) 全 SSE クライアントへ名前付きイベント `event: loop\ndata: {}\n\n` を送る（データは空オブジェクト。値は載せない）
//  変化が無ければ loop イベントを送らない。既存の無名イベント（id: <seq> + data: <record>）の形式は変えない
//  close() でポーリングのタイマーを止める
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（server/server.mjs に左の変異を入れた隔離コピーで右のテストが FAIL するべき）
// ════════════════════════════════════════════════════════════════════════════
//   /api/state に loop を載せない              [state] loop が載る・missing・running/halted の反映
//   読み取り結果を unknown に倒さず空や running を返す  [state] ファイル無し → unknown/missing・削除 → unknown
//   リンクを辿って読む（readLoopState の lstat 拒否を外した場合）  [state] リンクの状態ファイルが symlink
//   ポーリングを止める / 周期を無視する        [poll] rename 置換・削除が周期内に /api/state へ反映
//   キャッシュ（stateCache）を無効化しない      [poll] 置換後の /api/state が古い loop のまま
//   SSE に loop イベントを送らない              [sse] event: loop が届く
//   loop イベントに状態の値を載せる             [sse] data が {} 完全一致・issue/branch/halt_reason が本文に無い
//   毎周期 loop イベントを送る（変化比較なし）   [sse] 変化が無ければ送らない
//   loop イベントを無名イベントで送る           [sse] `event: loop` 行・既存レコードのパース
//   既存イベントの形式を変える                  [sse] 無名イベント（event: 行が無い）・id・record
//   close でタイマーを止めない                  [close] close 前後でタイマー数が増えたまま
//   sessions / last_seq を消す                  [state] 既存キーが残る
//   MONITOR_LOOP_STATE を CLI が見ない           [cli] 子プロセスの /api/state が指定ファイルの内容

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  cleanupTmp, fixture, getState, load, makeTmpDir, MONITOR_DIR, openStream, postEvent, request, sleep, spawnCli, startServer, withServer,
} from './helpers.mjs';

after(cleanupTmp);

const POLL_MS = 50;
const WITHIN_MS = 1500; // 周期 50ms に対して十分な余裕（遅い CI でも「周期以内」の意味を保つ）

const state = (over = {}) => ({
  issue: '22', branch: 'feat/22-loop-state-panel', epic: 'ai-monitor', status: 'running',
  started_at: '2026-10-10T05:14:26Z',
  limits: { max_retry: 3, max_minutes: 180, max_same_gate_fail: 2 },
  retry: 1, gates: { G1: { result: 'pass', reason: 'r' } }, halt_reason: null,
  awake_start: 1, boot_id: 'B', history: [], ...over,
});

/** 原子的置換: 同じディレクトリの一時ファイルへ書いて rename（loop-state.sh の write_state と同じ形） */
function atomicWrite(path, obj) {
  const tmp = `${path}.tmp-${process.pid}-${Math.random().toString(16).slice(2)}`;
  writeFileSync(tmp, typeof obj === 'string' ? obj : JSON.stringify(obj));
  renameSync(tmp, path);
}

function loopFile(obj) {
  const dir = makeTmpDir();
  const path = join(dir, 'loop-state.json');
  if (obj !== undefined) writeFileSync(path, typeof obj === 'string' ? obj : JSON.stringify(obj));
  return path;
}

// 失敗したテストが SSE 接続を残すと close() が終わらない。必ず切ってから close する
const opened = [];
async function open(port) {
  const st = await openStream(port);
  opened.push(st);
  return st;
}
async function withLoop(fn, opts) {
  try { await withServer(async (s) => { try { await fn(s); } finally { for (const st of opened.splice(0)) st.destroy(); } }, opts); } finally { opened.splice(0); }
}

async function waitLoop(port, pred, ms = WITHIN_MS) {
  const t0 = Date.now();
  let last;
  while (Date.now() - t0 < ms) {
    last = (await getState(port)).json?.loop;
    if (last && pred(last)) return last;
    await sleep(20);
  }
  throw new Error(`loop が ${ms}ms 以内に条件を満たさない。最後: ${JSON.stringify(last)}`);
}

// ---------- 既定値 ----------

test('[default] DEFAULT_LOOP_STATE_PATH は <リポジトリ>/.claude/memory/loop-state.json（server.mjs の位置から導出）', async () => {
  const m = await load('server.mjs');
  assert.equal(m.DEFAULT_LOOP_STATE_PATH, join(MONITOR_DIR, '..', 'memory', 'loop-state.json'));
});

// ---------- /api/state ----------

test('[state] /api/state に loop が載り、既存の sessions と last_seq も残る', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const { status, json } = await getState(s.port);
    assert.equal(status, 200);
    assert.ok(Object.hasOwn(json, 'sessions'));
    assert.ok(Object.hasOwn(json, 'last_seq'));
    assert.equal(json.loop.status, 'running');
    assert.equal(json.loop.issue, '22');
    assert.deepEqual(json.loop.gates, { G1: { result: 'pass' } });
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[state] loop は許可リスト外（awake_start / history / gates.*.reason）を含まない', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const r = await request(s.port, { path: '/api/state' });
    assert.ok(r.body.includes('"loop"'), 'loop が載っていない');
    for (const bad of ['awake_start', 'boot_id', 'history', '"reason"']) {
      assert.ok(!r.body.includes(bad), `${bad} が出ている`);
    }
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[state] 状態ファイルが無ければ loop は { status: unknown, reason: missing }', async () => {
  const path = loopFile();
  await withLoop(async (s) => {
    const { json } = await getState(s.port);
    assert.deepEqual(json.loop, { status: 'unknown', reason: 'missing' });
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[state] 状態ファイルがリンクなら loop は unknown/symlink（妥当な JSON でも）', async () => {
  const dir = makeTmpDir();
  const real = join(dir, 'real.json');
  writeFileSync(real, JSON.stringify(state()));
  const link = join(dir, 'loop-state.json');
  symlinkSync(real, link);
  await withLoop(async (s) => {
    const { json } = await getState(s.port);
    assert.deepEqual(json.loop, { status: 'unknown', reason: 'symlink' });
  }, { loopStatePath: link, loopPollMs: POLL_MS });
});

test('[state] 壊れた JSON は unknown/invalid_json（running を返さない）', async () => {
  const path = loopFile('{"status":"running"');
  await withLoop(async (s) => {
    const { json } = await getState(s.port);
    assert.deepEqual(json.loop, { status: 'unknown', reason: 'invalid_json' });
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[state] halted の状態が halt_reason 付きで載る', async () => {
  const path = loopFile(state({ status: 'halted', halt_reason: 'リトライ上限' }));
  await withLoop(async (s) => {
    const { json } = await getState(s.port);
    assert.equal(json.loop.status, 'halted');
    assert.equal(json.loop.halt_reason, 'リトライ上限');
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[state] ポーリング周期より長い既定（loopPollMs 省略）でも起動時の内容が載る', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const { json } = await getState(s.port);
    assert.equal(json.loop.status, 'running');
  }, { loopStatePath: path });
});

// ---------- [poll] 反映 ----------

test('[poll] rename による原子的置換が周期以内に /api/state へ反映される（running -> halted）', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    assert.equal((await getState(s.port)).json.loop.status, 'running');
    atomicWrite(path, state({ status: 'halted', halt_reason: '置換後の理由' }));
    const loop = await waitLoop(s.port, (l) => l.status === 'halted');
    assert.equal(loop.halt_reason, '置換後の理由');
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[poll] 置換を繰り返しても毎回追従する（retry 0 -> 1 -> 2 -> 3）', async () => {
  const path = loopFile(state({ retry: 0 }));
  await withLoop(async (s) => {
    for (const n of [1, 2, 3]) {
      atomicWrite(path, state({ retry: n }));
      await waitLoop(s.port, (l) => l.retry === n);
    }
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[poll] 状態ファイルの削除が周期以内に unknown/missing として反映される', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    assert.equal((await getState(s.port)).json.loop.status, 'running');
    rmSync(path);
    const loop = await waitLoop(s.port, (l) => l.status === 'unknown');
    assert.deepEqual(loop, { status: 'unknown', reason: 'missing' });
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[poll] 無かった状態ファイルが後から現れても反映される（missing -> running）', async () => {
  const path = loopFile();
  await withLoop(async (s) => {
    assert.equal((await getState(s.port)).json.loop.reason, 'missing');
    atomicWrite(path, state());
    await waitLoop(s.port, (l) => l.status === 'running');
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[poll] 置換後にリンクへ差し替えられたら unknown/symlink に倒れる', async () => {
  const path = loopFile(state());
  const real = join(makeTmpDir(), 'real.json');
  writeFileSync(real, JSON.stringify(state()));
  await withLoop(async (s) => {
    rmSync(path);
    symlinkSync(real, path);
    const loop = await waitLoop(s.port, (l) => l.status === 'unknown');
    assert.equal(loop.reason, 'symlink');
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[poll] ループ状態が変わっても sessions / last_seq は変わらない（既存のキャッシュ契約を壊さない）', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    await postEvent(s.port, fixture('PreToolUse.bash'));
    const before = (await getState(s.port)).json;
    atomicWrite(path, state({ retry: 2 }));
    await waitLoop(s.port, (l) => l.retry === 2);
    const after2 = (await getState(s.port)).json;
    assert.equal(after2.last_seq, before.last_seq);
    assert.deepEqual(after2.sessions, before.sessions);
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

// ---------- [sse] ----------

test('[sse] 置換で `event: loop` + `data: {}` が全クライアントに届く（値は載らない）', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const a = await open(s.port);
    const b = await open(s.port);
    atomicWrite(path, state({ status: 'halted', halt_reason: 'SECRET-HALT-REASON', branch: 'feat/SECRET-BRANCH' }));
    for (const st of [a, b]) {
      await st.waitFor((t) => t.includes('event: loop\ndata: {}\n\n'), WITHIN_MS);
      assert.ok(!st.text.includes('SECRET'), `loop イベントに値が載った: ${st.text}`);
      assert.ok(!st.text.includes('halted'));
      assert.ok(!st.text.includes('22'));
      st.destroy();
    }
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[sse] 削除でも loop イベントが届く', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const st = await open(s.port);
    rmSync(path);
    await st.waitFor((t) => t.includes('event: loop\ndata: {}\n\n'), WITHIN_MS);
    st.destroy();
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[sse] loop イベントを受けた時点で /api/state は新しい loop を返している（通知の後に取得して古いままにならない）', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const st = await open(s.port);
    atomicWrite(path, state({ retry: 3 }));
    await st.waitFor((t) => t.includes('event: loop'), WITHIN_MS);
    assert.equal((await getState(s.port)).json.loop.retry, 3);
    st.destroy();
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[sse] 変化が無ければ loop イベントを送らない（接続直後も、複数周期の間も）', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const st = await open(s.port);
    await sleep(POLL_MS * 8);
    assert.ok(!st.text.includes('event: loop'), `変化が無いのに送られた: ${st.text}`);
    // 同じ内容で置換しても（内容が同じなら）送らない
    atomicWrite(path, state());
    await sleep(POLL_MS * 8);
    assert.ok(!st.text.includes('event: loop'), `同内容の置換で送られた: ${st.text}`);
    // 陽性対照: 実際に変えれば送られる（送信機構が無い実装でこのテストが素通りしない）
    atomicWrite(path, state({ retry: 3 }));
    await st.waitFor((t) => t.includes('event: loop\ndata: {}\n\n'), WITHIN_MS);
    st.destroy();
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[sse] 変化は 1 回につき loop イベント 1 回（連続して送り続けない）', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const st = await open(s.port);
    atomicWrite(path, state({ retry: 2 }));
    await st.waitFor((t) => t.includes('event: loop'), WITHIN_MS);
    await sleep(POLL_MS * 8);
    assert.equal(st.text.split('event: loop').length - 1, 1);
    st.destroy();
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

test('[sse] 既存のイベントレコードは無名イベントのまま（event: 行なし・id と data: <record>）。loop イベントと混在しても壊れない', async () => {
  const path = loopFile(state());
  await withLoop(async (s) => {
    const st = await open(s.port);
    atomicWrite(path, state({ retry: 2 }));
    await st.waitFor((t) => t.includes('event: loop'), WITHIN_MS);
    const r = await postEvent(s.port, fixture('PreToolUse.bash'));
    assert.equal(r.status, 201);
    await st.waitFor((t) => t.includes('toolu_dummy0000000000000000001'), WITHIN_MS);
    const blocks = st.text.split('\n\n').filter(Boolean);
    const recordBlock = blocks.find((b) => b.includes('toolu_dummy0000000000000000001'));
    assert.match(recordBlock, /^id: \d+\ndata: \{/);
    assert.ok(!recordBlock.includes('event:'), `レコードに event: 行がある: ${recordBlock}`);
    const loopBlocks = blocks.filter((b) => b.startsWith('event: loop'));
    assert.ok(loopBlocks.length >= 1);
    for (const b of loopBlocks) assert.equal(b, 'event: loop\ndata: {}');
    st.destroy();
  }, { loopStatePath: path, loopPollMs: POLL_MS });
});

// ---------- [close] ----------

test('[close] close() でポーリングのタイマーが残らない（作成前と close 後でタイマー数が同じ）', async () => {
  const count = () => process.getActiveResourcesInfo().filter((n) => n === 'Timeout').length;
  const base = count();
  const path = loopFile(state());
  const s = await startServer({ loopStatePath: path, loopPollMs: 20 });
  let during;
  try { during = count(); } finally { await s.close(); }
  assert.ok(during > base, 'ポーリングのタイマーが見えない（検査が成り立たない）');
  await sleep(50);
  assert.equal(count(), base, 'close() 後にタイマーが残っている');
});

// ---------- [cli] ----------

test('[cli] MONITOR_LOOP_STATE で指定したファイルを読む（子プロセスの /api/state）', async () => {
  const path = loopFile(state({ issue: '77', status: 'halted', halt_reason: 'cli-reason' }));
  const cli = spawnCli({ MONITOR_LOOP_STATE: path });
  try {
    const { port } = await cli.listening;
    const { json } = await getState(port);
    assert.equal(json.loop.status, 'halted');
    assert.equal(json.loop.issue, '77');
  } finally { await cli.stop(); }
});

test('[cli] MONITOR_LOOP_STATE が存在しないパスなら unknown/missing（既定パスの本物の状態を読まない）', async () => {
  const path = join(makeTmpDir(), 'none.json');
  const cli = spawnCli({ MONITOR_LOOP_STATE: path });
  try {
    const { port } = await cli.listening;
    const { json } = await getState(port);
    assert.deepEqual(json.loop, { status: 'unknown', reason: 'missing' });
  } finally { await cli.stop(); }
});

test('[cli] CLI のログに状態ファイルの値・パスを出さない', async () => {
  const path = loopFile(state({ halt_reason: 'CLILOOPMARKER' }));
  const cli = spawnCli({ MONITOR_LOOP_STATE: path });
  try {
    const { port } = await cli.listening;
    assert.equal((await getState(port)).json.loop?.halt_reason, 'CLILOOPMARKER', '状態が読まれていない（検査が成り立たない）');
  } finally { await cli.stop(); }
  const all = `${cli.out.stdout}\n${cli.out.stderr}`;
  assert.ok(!all.includes('CLILOOPMARKER'));
  assert.ok(!all.includes(path));
});

test('[state] 親ディレクトリがリンクなら unknown/symlink', async () => {
  const base = makeTmpDir();
  const real = join(base, 'real');
  mkdirSync(real);
  writeFileSync(join(real, 'loop-state.json'), JSON.stringify(state()));
  symlinkSync(real, join(base, 'memory'));
  await withLoop(async (s) => {
    const { json } = await getState(s.port);
    assert.deepEqual(json.loop, { status: 'unknown', reason: 'symlink' });
  }, { loopStatePath: join(base, 'memory', 'loop-state.json'), loopPollMs: POLL_MS });
});
