// 保持期間の削除（prune）まわりの防御（Issue #19 / PR #29 の独立レビューで「外しても全 PASS」と指摘された 2 点）。契約は server.test.mjs の冒頭コメント。
//
//  [prune-cache]  prune で行が消えたら /api/state の導出キャッシュを捨てる（server.mjs の `stateCache = null`）。
//                 last_seq は MAX(seq) で、削除では進まない。キャッシュキーの比較では検知できず、捨てないと古い導出結果が返り続ける。
//                 全行が消えると MAX(seq) が 0 に戻って last_seq が変わりキャッシュが無効になる。だから「一部だけ消えて MAX(seq) が同じ」を使う。
//                 追記経路の prune は直前の追記で seq が進むので観測できない。観測できるのは「追記なしの定期 prune」だけ。
//                 mock.timers で setInterval だけを偽装し、1 時間ぶん tick して決定的に起動する（実時間は待たない）。
//  [prune-append] 追記 PRUNE_EVERY_APPENDS 件ごとの prune トリガ。maxRows を小さくして境界（N-1 件では消えない・N 件目で消える）を見る。
//
//  [prune-startup] createServer 起動時の初回 prune。既存 DB（期限切れ行・maxRows 超過）を用意し、起動直後に追記も tick も無しで行が消えていること。
//                 setInterval は mock.timers で偽装し tick しない（tick 由来で消えると起動時経路を検査したことにならない）。
//
//  PRUNE_EVERY_APPENDS / PRUNE_INTERVAL_MS は server.mjs から import する。既定値（1000 件 / 1 時間）はテストで固定する。

import test, { after, mock } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { join as pjoin } from 'node:path';
import { cleanupTmp, fixture, getState, load, makeTmpDir, postEvent, SID, startServer, withServer } from './helpers.mjs';

after(cleanupTmp);

const { PRUNE_EVERY_APPENDS, PRUNE_INTERVAL_MS } = await load('server.mjs');
const MAX_ROWS = 10;

test('[prune 既定値] export された prune 定数が期待値（1000 件 / 1 時間）である', () => {
  assert.equal(PRUNE_EVERY_APPENDS, 1000);
  assert.equal(PRUNE_INTERVAL_MS, 60 * 60 * 1000);
});

test('[prune-cache] 一部だけ消えて last_seq（MAX(seq)）が同じままでも、消えた行由来のセッションは返らない', async () => {
  mock.timers.enable({ apis: ['setInterval'] });
  try {
    let clock = 1_000_000;
    const OLD = SID;
    const NEW = '22222222-2222-4222-8222-222222222222';
    await withServer(async (s) => {
      assert.equal((await postEvent(s.port, { ...fixture('SessionStart'), session_id: OLD })).status, 201);
      clock += 5000;
      assert.equal((await postEvent(s.port, { ...fixture('SessionStart'), session_id: NEW })).status, 201);
      const before = await getState(s.port);
      assert.deepEqual(before.json.sessions.map((x) => x.session_id).sort(), [OLD, NEW].sort(), '自己診断: 2 セッションが見える');

      clock += 100; // OLD は期限切れ（5100ms 経過 > 1000ms）、NEW は期限内（100ms）
      mock.timers.tick(PRUNE_INTERVAL_MS);
      assert.equal(s.store.count(), 1, '自己診断: 古い 1 行だけ消えた');
      const afterState = await getState(s.port);
      assert.equal(afterState.json.last_seq, before.json.last_seq, '自己診断: 削除では last_seq が進まない（キー比較では検知できない状況）');
      assert.deepEqual(afterState.json.sessions.map((x) => x.session_id), [NEW], '消えた行由来のセッションが返っている（古いキャッシュ）');
    }, { now: () => clock, retentionMs: 1000 });
  } finally {
    mock.timers.reset();
  }
});

// keep-alive で 1000 件を短時間に流す（request() は毎回接続を張り直すので遅い）
function keepAlivePoster(port) {
  const agent = new http.Agent({ keepAlive: true, maxSockets: 1 });
  const post = (obj) => new Promise((resolve, reject) => {
    const body = JSON.stringify(obj);
    const r = http.request({
      host: '127.0.0.1', port, method: 'POST', path: '/api/events', agent,
      headers: { 'Content-Type': 'application/json', 'Content-Length': String(Buffer.byteLength(body)) },
    }, (res) => {
      res.resume();
      res.on('end', () => resolve(res.statusCode));
      res.on('error', reject);
    });
    r.on('error', reject);
    r.end(body);
  });
  return { post, close: () => agent.destroy() };
}

const sessionStart = () => ({ ...fixture('SessionStart'), session_id: randomUUID() });

test('[prune-append] 追記が PRUNE_EVERY_APPENDS 件に達した時点で prune が走り、行数が maxRows に収まる。1 件手前ではまだ消えない', async () => {
  await withServer(async (s) => {
    const poster = keepAlivePoster(s.port);
    try {
      for (let i = 1; i < PRUNE_EVERY_APPENDS; i += 1) {
        assert.equal(await poster.post(sessionStart()), 201, `POST ${i}`);
      }
      assert.equal(s.store.count(), PRUNE_EVERY_APPENDS - 1, `${PRUNE_EVERY_APPENDS - 1} 件目までは削除されない（自己診断: 件数が maxRows を超えて溜まる）`);
      assert.ok(PRUNE_EVERY_APPENDS - 1 > MAX_ROWS, '自己診断: maxRows を超えた状態で境界を見ている');

      assert.equal(await poster.post(sessionStart()), 201);
      assert.equal(s.store.count(), MAX_ROWS, `${PRUNE_EVERY_APPENDS} 件目で prune が走らず、行が maxRows に収まっていない`);
      const st = await getState(s.port);
      assert.equal(st.json.sessions.length, MAX_ROWS, '/api/state も上限内（古い導出が残っていない）');
      assert.equal(st.json.last_seq, PRUNE_EVERY_APPENDS, '削除されても seq は進み続ける');
    } finally {
      poster.close();
    }
  }, { maxRows: MAX_ROWS, retentionMs: 365 * 24 * 60 * 60 * 1000 });
});

test('[prune-append] カウンタは prune のたびにリセットされる（次の PRUNE_EVERY_APPENDS 件目でもう一度 prune が走る）', async () => {
  await withServer(async (s) => {
    const poster = keepAlivePoster(s.port);
    try {
      for (let i = 1; i <= PRUNE_EVERY_APPENDS; i += 1) {
        assert.equal(await poster.post(sessionStart()), 201, `1 周目 POST ${i}`);
      }
      assert.equal(s.store.count(), MAX_ROWS);
      for (let i = 1; i < PRUNE_EVERY_APPENDS; i += 1) {
        assert.equal(await poster.post(sessionStart()), 201, `2 周目 POST ${i}`);
      }
      assert.equal(s.store.count(), MAX_ROWS + PRUNE_EVERY_APPENDS - 1, '2 周目の手前では溜まる');
      assert.equal(await poster.post(sessionStart()), 201);
      assert.equal(s.store.count(), MAX_ROWS, '2 周目でも prune が走る');
    } finally {
      poster.close();
    }
  }, { maxRows: MAX_ROWS, retentionMs: 365 * 24 * 60 * 60 * 1000 });
});

/** 既存 DB を直接作る（サーバ起動前）。times の各値を received_at にして append して閉じ、行数を返す */
async function seedDb(dbPath, times) {
  const { openStore } = await load('store.mjs');
  let clock = 0;
  const store = openStore({ dbPath, now: () => clock });
  for (const t of times) {
    clock = t;
    store.append(sessionStart());
  }
  const n = store.count();
  store.close();
  return n;
}

test('[prune-startup] 起動した直後（追記も tick も無し）に、期限切れ行が既存 DB から消える。期限内の行は残る', async () => {
  mock.timers.enable({ apis: ['setInterval'] });
  try {
    const dbPath = pjoin(makeTmpDir(), 'monitor.db');
    assert.equal(await seedDb(dbPath, [1000, 2000, 1_000_000]), 3, '自己診断: 既存 DB に 3 行ある');
    const s = await startServer({ dbPath, now: () => 1_000_100, retentionMs: 5000 });
    try {
      // setInterval は偽装したまま進めていない。追記もしていない
      assert.equal(s.store.count(), 1, '起動時 prune が走らず、期限切れ行が残っている');
      const st = await getState(s.port);
      assert.equal(st.json.sessions.length, 1, '/api/state にも期限切れ行由来のセッションが残っている');
      assert.equal(st.json.last_seq, 3, '削除されても seq は戻らない');
    } finally {
      await s.close();
    }
  } finally {
    mock.timers.reset();
  }
});

test('[prune-startup] 起動した直後に、maxRows 超過分が既存 DB から削られる（新しい側が残る）', async () => {
  mock.timers.enable({ apis: ['setInterval'] });
  try {
    const dbPath = pjoin(makeTmpDir(), 'monitor.db');
    assert.equal(await seedDb(dbPath, [100, 101, 102, 103, 104]), 5, '自己診断: 既存 DB に 5 行ある');
    const s = await startServer({ dbPath, now: () => 110, retentionMs: 365 * 24 * 60 * 60 * 1000, maxRows: 2 });
    try {
      assert.equal(s.store.count(), 2, '起動時 prune が走らず、maxRows 超過分が残っている');
      assert.deepEqual(s.store.list().map((r) => r.seq), [4, 5], '古い側から削られる');
    } finally {
      await s.close();
    }
  } finally {
    mock.timers.reset();
  }
});
