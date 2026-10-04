// store.mjs のテスト（Issue #19 / Red）。契約の全体像は server.test.mjs の冒頭コメントを見ろ。
//
//   openStore({ dbPath, now?, retentionMs?, maxRows? }) -> Store      （同期。node:sqlite の DatabaseSync を使う）
//     now          () => ms。既定 Date.now。受信時刻 received_at はこれで付ける（テストで注入する）
//     retentionMs  既定 DEFAULT_RETENTION_MS（7 日）。received_at がこれより古い行を prune() が消す
//     maxRows      既定 DEFAULT_MAX_ROWS（100000）。超えた分を seq の古い順に prune() が消す
//   Store.append(event) -> { seq, received_at }        seq は 1 ずつ増える連番（削除後も再利用しない）
//   Store.list({ afterSeq = 0, limit? }) -> Record[]    seq 昇順。Record = { seq, received_at, ...ペイロード }（フラット）
//   Store.count() -> number                             events テーブルの行数
//   Store.prune() -> number                             削除した行数（ちょうど retentionMs 経過は残す。超えたら消す）
//   Store.close()
//   export const DEFAULT_RETENTION_MS = 604800000, DEFAULT_MAX_ROWS = 100000
//   - テーブル名は `events`
//   - 時刻と連番は受信側が付ける。ペイロードに送信側の時刻系の値があっても順序には使わない
//   - SQL は全てプレースホルダ付きのプリペアドステートメント

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { cleanupTmp, load, makeTmpDir, SID } from './helpers.mjs';

after(cleanupTmp);

const T0 = 1_800_000_000_000;
const DAY = 86_400_000;
const ev = (event, extra = {}) => ({ schema_version: 1, event, session_id: SID, ...extra });

async function open(opts = {}) {
  const { openStore } = await load('store.mjs');
  const dir = makeTmpDir();
  const dbPath = opts.dbPath ?? join(dir, 'monitor.db');
  const clock = { t: T0 };
  const store = openStore({ dbPath, now: () => clock.t, ...opts });
  return { store, clock, dbPath };
}

test('既定値は 7 日 / 100000 行', async () => {
  const m = await load('store.mjs');
  assert.equal(m.DEFAULT_RETENTION_MS, 7 * DAY);
  assert.equal(m.DEFAULT_MAX_ROWS, 100_000);
});

test('append は受信時刻（注入した時計）と連番を付ける。連番は 1 ずつ増える', async () => {
  const { store, clock } = await open();
  clock.t = T0 + 5;
  const a = store.append(ev('UserPromptSubmit'));
  clock.t = T0 + 9;
  const b = store.append(ev('Stop'));
  const c = store.append(ev('Notification'));
  assert.equal(a.received_at, T0 + 5);
  assert.equal(b.received_at, T0 + 9);
  assert.equal(b.seq, a.seq + 1);
  assert.equal(c.seq, b.seq + 1);
  assert.equal(store.count(), 3);
  store.close();
});

test('list は seq 昇順でフラットなレコードを返し、ペイロードを原文のまま保つ', async () => {
  const { store, clock } = await open();
  clock.t = T0 + 1;
  const payload = ev('PostToolUse', { tool_name: 'Read', tool_use_id: 'toolu_1', file_path: 'a.txt', duration_ms: 12 });
  const { seq } = store.append(payload);
  const [r] = store.list();
  assert.deepEqual(r, { seq, received_at: T0 + 1, ...payload });
  store.close();
});

test('list({afterSeq, limit}) は指定より後ろだけを昇順で返す', async () => {
  const { store } = await open();
  const seqs = [];
  for (let i = 0; i < 5; i += 1) seqs.push(store.append(ev('Notification')).seq);
  assert.deepEqual(store.list({ afterSeq: seqs[1] }).map((r) => r.seq), seqs.slice(2));
  assert.deepEqual(store.list({ afterSeq: seqs[1], limit: 2 }).map((r) => r.seq), seqs.slice(2, 4));
  assert.deepEqual(store.list({ afterSeq: seqs[4] }), []);
  store.close();
});

test('順序は挿入（seq）で決まる。時計が逆行しても、duration_ms が逆順でも並びは変わらない', async () => {
  const { store, clock } = await open();
  clock.t = T0 + 3000;
  const a = store.append(ev('PostToolUse', { tool_name: 'Read', tool_use_id: 't1', duration_ms: 1 }));
  clock.t = T0 + 2000;
  const b = store.append(ev('PostToolUse', { tool_name: 'Read', tool_use_id: 't2', duration_ms: 3_000_000 }));
  clock.t = T0 + 1000;
  const c = store.append(ev('PostToolUse', { tool_name: 'Read', tool_use_id: 't3', duration_ms: 2 }));
  assert.ok(a.seq < b.seq && b.seq < c.seq);
  assert.deepEqual(store.list().map((r) => r.tool_use_id), ['t1', 't2', 't3']);
  store.close();
});

test('再オープンしても行が残り、seq は続きから（既存の最大より大きい）', async () => {
  const { store, dbPath } = await open();
  const last = [store.append(ev('Stop')), store.append(ev('Stop'))].at(-1);
  store.close();
  const { openStore } = await load('store.mjs');
  const again = openStore({ dbPath });
  assert.equal(again.count(), 2);
  assert.ok(again.append(ev('Stop')).seq > last.seq);
  again.close();
});

test('SQL 断片を含む値が原文のまま保存・返却され、events テーブルが残る', async () => {
  const { store, dbPath } = await open();
  const sqlish = "'); DROP TABLE events;--";
  store.append(ev('PreToolUse', { tool_name: 'Read', tool_use_id: 'toolu_sql', file_path: sqlish }));
  store.append(ev('Stop'));
  assert.equal(store.count(), 2, 'テーブルが落ちていない');
  assert.equal(store.list()[0].file_path, sqlish);
  store.close();
  const { DatabaseSync } = await import('node:sqlite');
  const raw = new DatabaseSync(dbPath);
  const row = raw.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?").get('events');
  assert.equal(row?.name, 'events');
  assert.equal(raw.prepare('SELECT COUNT(*) AS n FROM events').get().n, 2);
  raw.close();
});

// ---------- 保持期間 ----------

test('7 日より古い行を prune が消す。ちょうど 7 日は残し、1ms 超えたら消す', async () => {
  const { store, clock } = await open();
  store.append(ev('Stop'));
  clock.t = T0 + 7 * DAY;
  assert.equal(store.prune(), 0, 'ちょうど 7 日は保持');
  assert.equal(store.count(), 1);
  clock.t = T0 + 7 * DAY + 1;
  assert.equal(store.prune(), 1);
  assert.equal(store.count(), 0);
  store.close();
});

test('古い行だけが消え、新しい行は残る（保持期間は受信時刻で判定する）', async () => {
  const { store, clock } = await open({ retentionMs: 1000 });
  clock.t = T0;
  store.append(ev('UserPromptSubmit', {}));
  store.append(ev('Notification'));
  clock.t = T0 + 5000;
  const fresh = store.append(ev('Stop'));
  assert.equal(store.prune(), 2);
  assert.deepEqual(store.list().map((r) => r.seq), [fresh.seq]);
  store.close();
});

test('maxRows を超えた分は古い順（seq の小さい順）に消える', async () => {
  const { store } = await open({ maxRows: 5 });
  const seqs = [];
  for (let i = 0; i < 8; i += 1) seqs.push(store.append(ev('Notification')).seq);
  store.prune();
  assert.equal(store.count(), 5);
  assert.deepEqual(store.list().map((r) => r.seq), seqs.slice(3));
  assert.equal(store.prune(), 0, '上限ちょうどなら何も消さない');
  store.close();
});

test('seq は prune で全行が消えても再利用されない', async () => {
  const { store, clock } = await open({ retentionMs: 1000 });
  const old = store.append(ev('Stop'));
  clock.t = T0 + 5000;
  store.prune();
  assert.equal(store.count(), 0);
  assert.ok(store.append(ev('Stop')).seq > old.seq);
  store.close();
});

test('close 後の操作は例外になる（サーバはこれを 5xx として扱う）', async () => {
  const { store } = await open();
  store.close();
  assert.throws(() => store.append(ev('Stop')));
  assert.throws(() => store.count());
});
