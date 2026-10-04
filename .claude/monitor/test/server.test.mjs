// 受信サーバ（Issue #19 / Red）の契約テスト・状態反映・順序・listen
//
// ════════════════════════════════════════════════════════════════════════════
//  Coder への契約（このテスト群が前提にする API。変える時は QA に戻せ）
// ════════════════════════════════════════════════════════════════════════════
//  実行: node --test .claude/monitor/test/*.test.mjs
//        （ディレクトリ指定 `node --test .claude/monitor/test/` は Node 22.22 では
//          ディレクトリをファイルとして require しようとして失敗する。実測。glob で渡す）
//  依存: node: 組み込みのみ（node:http / node:sqlite 等）。.mjs は ESM。package.json は不要
//
//  server/validate.mjs   validateEvent(obj) -> {ok:true, event} | {ok:false, reason}     → validate.test.mjs
//  server/derive.mjs     deriveState(records) -> {sessions:[...]}                         → derive.test.mjs
//  server/store.mjs      openStore({dbPath, now, retentionMs, maxRows}), DEFAULT_*         → store.test.mjs
//  server/server.mjs     以下
//
//    export const MAX_BODY_BYTES = 65536, MAX_SSE_CLIENTS = 16, DEFAULT_PORT = 4319
//    export function resolveBind(env) -> string        env.MONITOR_BIND が非空ならそれ、無ければ '127.0.0.1'
//                                                        （MONITOR_BIND 以外の変数（HOST / BIND_ADDRESS 等）は見ない）
//    export async function createServer({ port, bind, dbPath, dataDir, now, retentionMs, maxRows, derive }) -> Handle
//        port 0 で空きポート。bind 省略時は resolveBind(process.env)。now / retentionMs / maxRows は store に素通し
//        dataDir   既定のデータディレクトリの注入口。dbPath 未指定なら DB は <dataDir>/monitor.db。省略時は
//                  <monitor>/data（gitignore 済み）。テストは一時ディレクトリを渡して既定パス相当を再現する
//        derive    /api/state の導出関数の注入口（(records) => {sessions}）。省略時は derive.mjs の deriveState
//        （G5 差し戻し retry 1 で追加。テスト: server-fetch-site.test.mjs / server-dbpath.test.mjs）
//        Handle = { port: 実際のポート, bind, server: http.Server, store: Store, close(): Promise<void> }
//        close() は SSE 接続も切って resolve する。store が既に close 済みでも reject しない
//    import しただけでは listen しない（CLI 起動は import.meta で判定）
//    CLI: `node server.mjs`  env: LOOP_MONITOR_PORT（既定 4319。CLI のみ 0 を許可）/ MONITOR_BIND / MONITOR_DB（DB パス）
//        起動拒否（リンク検査に落ちた等）は非0終了・stdout 空・stderr は固定文言 `monitor server failed to start` のみ（パスを載せない）
//        起動したら stdout に 1 行 `listening on <bind>:<port>` を出す。SIGTERM / SIGINT で終了する
//
//  HTTP（全ルート・全メソッドで Host → Origin → Sec-Fetch-Site の順に検査し、通らなければ 403。ルート判定より先）
//    POST /api/events   Content-Type が application/json（`; charset=utf-8` 等のパラメータ付きは可）
//                        以外は 415。ボディ 64KB（65536 バイト）超は 413（読み取りを打ち切る）。不正 JSON は 400。
//                        validateEvent を通らなければ 400。成功は 201（2xx）。DB の行数は拒否時に増えない
//    GET  /api/state    200 JSON {sessions: deriveState(store.list()).sessions, last_seq: number}
//    GET  /api/stream   SSE。ヘッダは接続直後にフラッシュ。Content-Type: text/event-stream / Cache-Control: no-cache
//                        新着は `id: <seq>\ndata: <Record の JSON>\n\n`。同時接続が MAX_SSE_CLIENTS を超えたら 503
//    その他のパス 404 / 許可外メソッド 405（OPTIONS も 405。CORS プリフライトに応えない）
//    Access-Control-* ヘッダはどのレスポンスにも付けない
//  エラー本文は `{data:null, error:{message, code}}`。message は固定の汎用文言。例外メッセージ・スタック・
//    パス・SQL・入力値を含めない。5xx は 500 / `INTERNAL_ERROR`
//  Host:   `127.0.0.1:<実ポート>` と `localhost:<実ポート>` の完全一致のみ許可（大文字・ポート違い・ポート無し・欠落・空は拒否）
//  Origin: ヘッダが存在するなら `http://` + Host ヘッダ値 と完全一致のみ許可（`null`・空・末尾スラッシュ付きは拒否）
//  Sec-Fetch-Site: ヘッダが存在し、値が `same-origin` でも `none` でもなければ 403。ヘッダ無し（curl・フック・同一端末のプロセス）は通す。
//          値は完全一致（`Same-Origin`・`same-origin, cross-site` などの複数値・空・未知値は拒否。`same-site` も拒否 =
//          別ポートの localhost ページも同一サイト扱いになるため）。ヘッダが重複して届いた場合も拒否（Node は ", " で連結する）。
//          403 は SSE の枠を消費しない。Access-Control-* は付けない。（Origin を付けない no-cors の <img> GET 対策。G5 #1）
//  /api/state キャッシュ: 導出結果は last_seq が進んだ時だけ作り直す。同じ last_seq の間は derive を再実行しない
//          （空 DB = last_seq 0 も同じ）。拒否された POST（seq が進まない）では捨てない。seq が進めば必ず最新を返す。
//          推奨: last_seq の確認に全行の store.list() を毎回しない（連打の CPU の本体はそこにもある）。テストは導出回数のみ観測
//  DB パス（G5 #2。lessons #10 / #11: リンクは追わない・行き先を全部数える）:
//          dbPath 未指定（既定パス）でも MONITOR_DB / dbPath の明示指定でも、同じ検査をかける（fail closed に倒す。決定済み）。
//          次のどれかが lstat でシンボリックリンク（ダングリングを含む）なら起動を拒否する: DB ファイル・-wal・-shm・-journal・
//          データディレクトリ（明示指定では DB の直接の親）・その直接の親。realpath(dir) が realpath(dirname(dir)) + basename に
//          一致しなければ拒否。拒否は検査 → 作成の順（mkdir / open より前）で、リンク先に何も作らない・開かない。
//          拒否は createServer が reject（listen 前）。エラー文言にパスを載せない
//          ディレクトリは新規作成時 0700（再帰作成した親も）。DB ファイルは 0600（明示指定でも。-wal / -shm も group / other 不可）
//  ログ:   イベント本文・ヘッダ値・DB パスを stdout / stderr に出さない（出すなら固定文言のみ）
//
//  security.md の新節（見出し・語。tests/scripts/monitor-server.test.sh が検査する）
//    ## 監視の限界（受信側）            ← 既存の「## 監視の限界（送信側）」節の直後に置く
//      ### 受け付ける入力  ### 止める仕組み  ### 既知の限界
//    止める仕組みに: fail closed / Host / Origin / Content-Type / 64KB / Access-Control-Allow-Origin / 127.0.0.1 /
//                    MONITOR_BIND / プレースホルダ / ログ
//    既知の限界に:   認証 / 同一端末 / 書き込み / 読み出し / セキュリティ境界ではない /
//                    テスト名 `known_limit_local_process_can_write`（server-security.test.mjs）
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（防御を1つ外した隔離コピーで、左の変異に対し右のテストが FAIL するべき）
// ════════════════════════════════════════════════════════════════════════════
//   Host 検査を外す            server-reject.test.mjs   [Host] の全ケース（evil / ポート違い / 大文字 / 空 / 欠落 / 127.0.0.1.evil）
//   Origin 検査を外す          server-reject.test.mjs   [Origin] クロスオリジン POST・GET・SSE・OPTIONS
//   Sec-Fetch-Site 検査を外す  server-fetch-site.test.mjs [FetchSite] cross-site / same-site / 完全一致 / 重複ヘッダ / PoC・SSE 枠 / 403 本文
//   導出キャッシュを外す       server-fetch-site.test.mjs [cache] 連打で導出が増える・拒否 POST で再導出・空 DB
//   キャッシュを陳腐化させる   server-fetch-site.test.mjs [cache] 新着 POST 後の last_seq・状態（seq を見ずに固定する実装）
//   lstat / realpath 検査を外す server-dbpath.test.mjs  [link] dataDir・親・DB・-wal/-shm/-journal・ダングリング・明示 dbPath・CLI
//   mode 指定を外す            server-dbpath.test.mjs   [mode] dataDir 0700・再帰作成 0700・DB 0600（明示指定も）
//   Content-Type 検査を外す    server-reject.test.mjs   [CT] text/plain・form・multipart・欠落・`text/plain;x=application/json`
//   ボディ上限を外す           server-reject.test.mjs   [413] 65537 バイト・Content-Length 宣言・chunked 無限送信の早期切断
//   未知キー拒否を外す         validate.test.mjs 未知キー・__proto__ / server-reject.test.mjs [schema] 未知キー
//   プレースホルダを外す       static.test.mjs（prepare に SQL 連結・埋め込み）/ server.test.mjs [SQL] 原文保存
//   prune 後の導出キャッシュ破棄を外す  server-prune.test.mjs [prune-cache] 定期 prune で一部だけ消え last_seq 不変でも消えた行由来のセッションが返らない（mock.timers で setInterval のみ偽装）
//   追記 N 件ごとの prune トリガを潰す  server-prune.test.mjs [prune-append] N-1 件では溜まり N 件目で maxRows に収まる・2 周目も走る（keep-alive で約 0.7 秒 / 1000 件）
//   起動時の初回 prune を消す          server-prune.test.mjs [prune-startup] 既存 DB の期限切れ行・maxRows 超過分が、追記も tick も無しの起動直後に消える（mock.timers は tick しない）
//
// 入力仕様は event-schema.md / hook-events.md / fixtures/emitted/*.json のみ。推測しない（lessons #6）。
// DB はテストごとに一時ディレクトリ（実ホームに書かない。lessons #17）。

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  cleanupTmp, emittedFixtures, fixture, getState, load, makeTmpDir, openStream, parseSse, postEvent, request,
  SERVER_DIR, SID, spawnCli, startServer,
} from './helpers.mjs';

after(cleanupTmp);

// ---------- 契約: #18 の emitted fixture ----------

test('[contract] 全 emitted fixture を POST すると 2xx で受理され、行数と /api/state に反映される', async () => {
  const s = await startServer();
  try {
    const fx = emittedFixtures();
    for (const f of fx) {
      const r = await postEvent(s.port, null, { raw: f.text });
      assert.ok(r.status >= 200 && r.status < 300, `${f.name}: ${r.status} ${r.body}`);
    }
    assert.equal(s.store.count(), fx.length);
    const st = await getState(s.port);
    assert.equal(st.status, 200);
    assert.equal(st.json.sessions.length, 1);
    assert.equal(st.json.sessions[0].session_id, SID);
    assert.equal(st.json.last_seq, s.store.list().at(-1).seq);
  } finally { await s.close(); }
});

test('[contract] #18 の実送信ヘッダ（Content-Type: application/json のみ）で受理される', async () => {
  const s = await startServer();
  try {
    const r = await request(s.port, {
      method: 'POST', path: '/api/events', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(fixture('SessionStart')),
    });
    assert.ok(r.status >= 200 && r.status < 300, String(r.status));
  } finally { await s.close(); }
});

test('[contract] fixture 系列がエージェント木・実行中ツールとして /api/state に出る', async () => {
  const s = await startServer();
  try {
    const seq = ['SessionStart', 'UserPromptSubmit', 'PreToolUse.task', 'SubagentStart', 'PreToolUse.subagent-read'];
    for (const name of seq) assert.equal((await postEvent(s.port, fixture(name))).status, 201, name);

    let tree = (await getState(s.port)).json.sessions[0].tree;
    assert.equal(tree.status, 'running');
    assert.deepEqual(tree.running_tools.map((t) => t.tool_use_id), ['toolu_dummy0000000000000000003']);
    assert.equal(tree.children.length, 1);
    assert.equal(tree.children[0].agent_id, 'aaaaaaaaaaaaaaaaa');
    assert.equal(tree.children[0].agent_type, 'general-purpose');
    assert.equal(tree.children[0].status, 'running');
    assert.deepEqual(tree.children[0].running_tools.map((t) => t.tool_use_id), ['toolu_dummy0000000000000000005']);

    for (const name of ['PostToolUse.subagent-read', 'SubagentStop', 'PostToolUse.task', 'Stop']) {
      assert.equal((await postEvent(s.port, fixture(name))).status, 201, name);
    }
    const session = (await getState(s.port)).json.sessions[0];
    tree = session.tree;
    assert.equal(session.status, 'waiting');
    assert.equal(tree.children[0].status, 'done');
    assert.deepEqual(tree.running_tools, []);
    assert.deepEqual(tree.children[0].running_tools, []);

    assert.equal((await postEvent(s.port, fixture('SessionEnd'))).status, 201);
    assert.equal((await getState(s.port)).json.sessions[0].status, 'ended');
  } finally { await s.close(); }
});

test('[contract] 再起動（同じ dbPath）しても /api/state は同じ。状態は DB から導出される', async () => {
  const s = await startServer();
  let before;
  try {
    for (const name of ['SessionStart', 'UserPromptSubmit', 'SubagentStart', 'PreToolUse.subagent-bash']) await postEvent(s.port, fixture(name));
    before = (await getState(s.port)).json;
  } finally { await s.close(); }
  const again = await startServer({ dbPath: s.dbPath });
  try {
    assert.deepEqual((await getState(again.port)).json, before);
    assert.equal(again.store.count(), 4);
  } finally { await again.close(); }
});

// ---------- SQL インジェクション ----------

test('[SQL] `\'); DROP TABLE events;--` を含むイベントが原文のまま保存・SSE 返却され、テーブルが残る', async () => {
  const s = await startServer();
  try {
    const sqlish = "'); DROP TABLE events;--";
    const stream = await openStream(s.port);
    const r = await postEvent(s.port, { schema_version: 1, event: 'PreToolUse', session_id: SID, tool_name: 'Read', tool_use_id: 'toolu_sql', file_path: sqlish });
    assert.equal(r.status, 201);
    await stream.waitFor((t) => t.includes('toolu_sql'));
    const delivered = parseSse(stream.text).find((x) => x.tool_use_id === 'toolu_sql');
    assert.equal(delivered.file_path, sqlish, 'SSE の返却が原文のまま');
    stream.destroy();

    assert.equal(s.store.list().find((x) => x.tool_use_id === 'toolu_sql').file_path, sqlish, '保存が原文のまま');
    assert.equal((await postEvent(s.port, fixture('Stop'))).status, 201, 'テーブルが残っていて以降も書ける');
    assert.equal(s.store.count(), 2);
    assert.equal((await getState(s.port)).status, 200);
  } finally { await s.close(); }
});

// ---------- 時刻・順序 ----------

test('[order] received_at はサーバの時計、seq は連番。時計が逆行しても状態は seq の順で導出される', async () => {
  const clock = { t: 1_800_000_000_000 };
  const s = await startServer({ now: () => clock.t });
  try {
    clock.t = 1_800_000_009_000;
    assert.equal((await postEvent(s.port, fixture('UserPromptSubmit'))).status, 201);
    clock.t = 1_800_000_001_000; // 逆行
    assert.equal((await postEvent(s.port, fixture('Stop'))).status, 201);
    const [a, b] = s.store.list();
    assert.equal(a.received_at, 1_800_000_009_000);
    assert.equal(b.received_at, 1_800_000_001_000);
    assert.equal(b.seq, a.seq + 1);
    const session = (await getState(s.port)).json.sessions[0];
    assert.equal(session.status, 'waiting', '時刻の新しい方ではなく、後から届いた方（seq 大）が勝つ');
    assert.equal(session.last_seq, b.seq);
    assert.equal(session.last_received_at, 1_800_000_001_000);
  } finally { await s.close(); }
});

test('[order] 送信側の値（duration_ms）が逆順でも保存順（seq）は受信順のまま', async () => {
  const s = await startServer();
  try {
    for (const [id, d] of [['t1', 3_000_000], ['t2', 2_000], ['t3', 1]]) {
      const r = await postEvent(s.port, { schema_version: 1, event: 'PostToolUse', session_id: SID, tool_name: 'Read', tool_use_id: id, duration_ms: d });
      assert.equal(r.status, 201);
    }
    assert.deepEqual(s.store.list().map((x) => x.tool_use_id), ['t1', 't2', 't3']);
    assert.deepEqual(s.store.list().map((x) => x.duration_ms), [3_000_000, 2_000, 1], '送信側の値は保存される（順序には使わない）');
  } finally { await s.close(); }
});

// ---------- listen ----------

test('[listen] bind 省略時は 127.0.0.1 で listen する', async () => {
  const { createServer } = await load('server.mjs');
  const dir = makeTmpDir();
  const saved = process.env.MONITOR_BIND;
  delete process.env.MONITOR_BIND;
  let h;
  try {
    h = await createServer({ port: 0, dbPath: join(dir, 'monitor.db') });
    assert.equal(h.bind, '127.0.0.1');
    assert.equal(h.server.address().address, '127.0.0.1');
  } finally {
    if (saved !== undefined) process.env.MONITOR_BIND = saved;
    await h?.close();
  }
});

test('[listen] resolveBind は MONITOR_BIND でのみ変わる（HOST / BIND_ADDRESS / HOSTNAME は無視、空は既定へ倒す）', async () => {
  const { resolveBind } = await load('server.mjs');
  assert.equal(resolveBind({}), '127.0.0.1');
  assert.equal(resolveBind({ MONITOR_BIND: '0.0.0.0' }), '0.0.0.0');
  assert.equal(resolveBind({ MONITOR_BIND: '' }), '127.0.0.1');
  assert.equal(resolveBind({ HOST: '0.0.0.0', BIND: '0.0.0.0', BIND_ADDRESS: '0.0.0.0', HOSTNAME: '0.0.0.0', LOOP_MONITOR_BIND: '0.0.0.0' }), '127.0.0.1');
});

test('[listen] 既定ポートは 4319、上限は 64KB / SSE 16（承認済み既定値）', async () => {
  const m = await load('server.mjs');
  assert.equal(m.DEFAULT_PORT, 4319);
  assert.equal(m.MAX_BODY_BYTES, 65536);
  assert.equal(m.MAX_SSE_CLIENTS, 16);
});

test('[listen] CLI は既定で 127.0.0.1 に listen し、HOST 等の変数では変わらない。実 HTTP で応答する', async () => {
  const cli = spawnCli({ HOST: '0.0.0.0', BIND_ADDRESS: '0.0.0.0', HOSTNAME: '0.0.0.0' });
  try {
    const { bind, port } = await cli.listening;
    assert.equal(bind, '127.0.0.1');
    assert.equal((await postEvent(port, fixture('SessionStart'))).status, 201);
    assert.equal((await getState(port)).status, 200);
  } finally { await cli.stop(); }
});

test('[listen] CLI は MONITOR_BIND でのみ listen アドレスを変える', async () => {
  const cli = spawnCli({ MONITOR_BIND: '0.0.0.0' });
  try {
    const { bind } = await cli.listening;
    assert.equal(bind, '0.0.0.0');
  } finally { await cli.stop(); }
});

test('[listen] import しただけでは listen しない（CLI 判定）。少し待ってもプロセスが保持されない', async () => {
  const dir = makeTmpDir();
  const child = spawn(process.execPath, ['--input-type=module', '-e', `await import(${JSON.stringify(fileURLToPath(new URL('../server/server.mjs', import.meta.url)))}); console.log('imported');`], {
    env: { PATH: process.env.PATH, NODE_NO_WARNINGS: '1', MONITOR_DB: join(dir, 'monitor.db'), LOOP_MONITOR_PORT: '0' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '';
  child.stdout.on('data', (c) => { stdout += c; });
  const code = await new Promise((resolve) => {
    child.on('exit', resolve);
    setTimeout(() => { child.kill('SIGKILL'); resolve('still-running'); }, 5000);
  });
  assert.equal(code, 0, `import だけで常駐した/失敗した: ${code}`);
  assert.ok(stdout.includes('imported'));
  assert.ok(!/listening on/.test(stdout));
});
