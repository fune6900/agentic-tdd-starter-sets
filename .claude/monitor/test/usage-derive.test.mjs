// UsageSnapshot の保存と導出（置き換え保存）のテスト（Issue #23）。
// 仕様の唯一の正は docs/event-schema.md「UsageSnapshot の受信・保存・導出」。
//
//   deriveState(records) -> { sessions }。UsageSnapshot は events に追記され、導出で seq 最大の 1 件だけが有効。
//   ノード（メイン・サブ）に usage、セッションに usage_total が載る。
//
// 変異テスト対応表（この変異を入れると、右のテストが落ちる）:
//   - 「seq 最大を採る」を外し、全件を合算する                      -> '同じスナップショットを 2 回送っても合計は倍にならない'
//   - 「seq 最大を採る」を外し、配列順で最後を採る                   -> '配列順ではなく seq が大きいものが勝つ'
//   - 「seq 最大を採る」を外し、最初のものを採る                     -> 'seq が大きいものが勝つ'
//   - unknown が ok を置き換えない（ok を残す）                      -> 'unknown が ok を置き換える'
//   - 逆に ok が unknown を置き換えない                              -> 'ok が後に来たら unknown を置き換える'
//   - main と sub のキーを分けない（agent_id を無視）                -> 'main と sub は別々に保持'
//   - UsageSnapshot が last_seq / last_received_at を進める          -> 'ツリーの状態・last_seq・last_received_at を変えない'
//   - UsageSnapshot が status / running_tools を変える               -> 同上
//   - UsageSnapshot がノードやセッションを作る（subNode を通す）     -> 'ノードもセッションも作らない'
//   - ノードが無いのに表示に出す                                     -> 'ノードが無ければ表示に出ない'
//   - usage の形（status / reason / models）を変える                 -> 'usage の形'
//   - usage_total の estimate / tokens / unknown_snapshots の取り違え -> 'usage_total の形'
//   - cache_creation を 5m だけにする                                -> 'usage_total の形'
//   - 既存イベントの表示が変わる                                     -> '既存の導出は UsageSnapshot が混ざっても変わらない'

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { cleanupTmp, fixture, getState, load, postEvent, rec, SESS as S, SID, T0, usageEntry as entry, withServer } from './helpers.mjs';

after(cleanupTmp);

const derive = async (records) => (await load('derive.mjs')).deriveState(records);

const subStart = (seq, id) => rec(seq, 'SubagentStart', { agent_id: id, agent_type: 'general-purpose' });
const okU = (seq, models = [entry()], agent, session = S) =>
  rec(seq, 'UsageSnapshot', { usage_status: 'ok', models, ...(agent ? { agent_id: agent } : {}) }, session, 2);
const unkU = (seq, reason = 'too_large', agent, session = S) =>
  rec(seq, 'UsageSnapshot', { usage_status: 'unknown', unknown_reason: reason, ...(agent ? { agent_id: agent } : {}) }, session, 2);

const only = async (records) => {
  const { sessions } = await derive(records);
  assert.equal(sessions.length, 1);
  return sessions[0];
};
const child = (s, id) => s.tree.children.find((c) => c.agent_id === id);
const base = () => [rec(1, 'SessionStart'), rec(2, 'UserPromptSubmit')];
const outTokens = (node) => node.usage.models.reduce((a, m) => a + m.output_tokens, 0);

// ---------- 置き換え保存 ----------

test('スナップショットが無ければ usage は null、usage_total は 0 件の形', async () => {
  const s = await only(base());
  assert.equal(s.tree.usage, null);
  assert.equal(s.usage_total.estimate, true);
  assert.deepEqual(s.usage_total.tokens, { input: 0, output: 0, cache_creation: 0, cache_read: 0 });
  assert.equal(s.usage_total.unknown_snapshots, 0);
});

test('メインの ok スナップショットがツリーの根の usage に載る（usage の形）', async () => {
  const s = await only([...base(), okU(3)]);
  assert.equal(s.tree.usage.status, 'ok');
  assert.equal(s.tree.usage.models.length, 1);
  const m = s.tree.usage.models[0];
  for (const k of ['model', 'message_count', 'input_tokens', 'output_tokens', 'cache_creation_5m_input_tokens', 'cache_creation_1h_input_tokens', 'cache_read_input_tokens', 'cost']) {
    assert.ok(k in m, `models[0].${k} が無い`);
  }
  assert.equal(m.model, 'claude-haiku-4-5-20251001');
  assert.equal(m.input_tokens, 10);
  assert.ok(['known', 'unknown'].includes(m.cost.status));
});

test('同じスナップショットを 2 回送っても合計は倍にならない', async () => {
  const once = await only([...base(), okU(3)]);
  const twice = await only([...base(), okU(3), okU(4)]);
  assert.deepEqual(twice.usage_total.tokens, once.usage_total.tokens);
  assert.equal(twice.tree.usage.models[0].output_tokens, 20);
  assert.deepEqual(once.usage_total.tokens, { input: 10, output: 20, cache_creation: 70, cache_read: 50 });
});

test('同じ (session, agent) では seq が大きいものが勝つ', async () => {
  const s = await only([...base(), okU(3, [entry({ output_tokens: 100 })]), okU(5, [entry({ output_tokens: 200 })]), okU(4, [entry({ output_tokens: 150 })])]);
  assert.equal(outTokens(s.tree), 200);
});

test('配列順ではなく seq が大きいものが勝つ（古い seq が配列の後ろにあっても）', async () => {
  const s = await only([okU(9, [entry({ output_tokens: 900 })]), ...base(), okU(3, [entry({ output_tokens: 300 })])]);
  assert.equal(outTokens(s.tree), 900);
});

test('トークン数の大小では順序を補正しない（後の seq が小さい値でも勝つ）', async () => {
  const s = await only([...base(), okU(3, [entry({ output_tokens: 999 })]), okU(4, [entry({ output_tokens: 1 })])]);
  assert.equal(outTokens(s.tree), 1);
});

test('unknown が ok を置き換える（古い数値を残さない・合計にも入らない）', async () => {
  const s = await only([...base(), okU(3), unkU(4, 'symlink')]);
  assert.deepEqual(s.tree.usage, { status: 'unknown', reason: 'symlink' });
  assert.deepEqual(s.usage_total.tokens, { input: 0, output: 0, cache_creation: 0, cache_read: 0 });
  assert.equal(s.usage_total.unknown_snapshots, 1);
});

test('ok が後に来たら unknown を置き換える', async () => {
  const s = await only([...base(), unkU(3), okU(4)]);
  assert.equal(s.tree.usage.status, 'ok');
  assert.equal(s.usage_total.unknown_snapshots, 0);
});

test('main と sub は別々に保持される（互いを置き換えない）', async () => {
  const s = await only([...base(), subStart(3, 'aaa1'), okU(4, [entry({ output_tokens: 100 })]), okU(5, [entry({ output_tokens: 7 })], 'aaa1')]);
  assert.equal(outTokens(s.tree), 100);
  assert.equal(outTokens(child(s, 'aaa1')), 7);
  assert.equal(s.usage_total.tokens.output, 107, 'メイン + サブの単純合算');
  assert.equal(s.usage_total.tokens.input, 20);
  assert.equal(s.usage_total.tokens.cache_creation, 140);
  assert.equal(s.usage_total.tokens.cache_read, 100);
});

test('サブ同士も別々。sub の unknown はメインを壊さない', async () => {
  const s = await only([...base(), subStart(3, 'aaa1'), subStart(4, 'bbb2'), okU(5), okU(6, [entry()], 'aaa1'), unkU(7, 'read_failed', 'bbb2')]);
  assert.equal(s.tree.usage.status, 'ok');
  assert.equal(child(s, 'aaa1').usage.status, 'ok');
  assert.deepEqual(child(s, 'bbb2').usage, { status: 'unknown', reason: 'read_failed' });
  assert.equal(s.usage_total.unknown_snapshots, 1);
  assert.equal(s.usage_total.tokens.output, 40);
});

test('別セッションのスナップショットは混ざらない', async () => {
  const { sessions } = await derive([
    ...base(), rec(3, 'SessionStart', {}, 'sessB'), okU(4, [entry({ output_tokens: 11 })], undefined, 'sessB'), okU(5, [entry({ output_tokens: 22 })]),
  ]);
  const a = sessions.find((x) => x.session_id === S);
  const b = sessions.find((x) => x.session_id === 'sessB');
  assert.equal(outTokens(a.tree), 22);
  assert.equal(outTokens(b.tree), 11);
});

test('モデルが複数あれば usage_total は全モデルを合算する。ok で models が空なら 0', async () => {
  const s = await only([...base(), okU(3, [entry({ model: 'a' }), entry({ model: 'b', output_tokens: 5 })])]);
  assert.equal(s.usage_total.tokens.output, 25);
  const empty = await only([...base(), okU(3, [])]);
  assert.deepEqual(empty.tree.usage, { status: 'ok', models: [] });
  assert.deepEqual(empty.usage_total.tokens, { input: 0, output: 0, cache_creation: 0, cache_read: 0 });
});

test('usage_total の形: estimate は常に true、cost は known_micro_usd / known_count / unknown_count', async () => {
  const s = await only([...base(), okU(3), unkU(4, 'too_large', undefined)]);
  const t = s.usage_total;
  assert.equal(t.estimate, true);
  assert.deepEqual(Object.keys(t.tokens).sort(), ['cache_creation', 'cache_read', 'input', 'output']);
  assert.deepEqual(Object.keys(t.cost).sort(), ['known_count', 'known_micro_usd', 'unknown_count']);
  assert.equal(t.cost.known_count + t.cost.unknown_count >= 1, true);
  assert.equal(Number.isInteger(t.cost.known_micro_usd), true);
});

// ---------- UsageSnapshot が他を変えない ----------

const strip = (s) => JSON.parse(JSON.stringify(s, (k, v) => (k === 'usage' || k === 'usage_total' ? undefined : v)));

test('ツリーの状態・running_tools・last_seq・last_received_at を変えない', async () => {
  const events = [
    rec(1, 'SessionStart'), rec(2, 'UserPromptSubmit'), subStart(3, 'aaa1'),
    rec(4, 'PreToolUse', { tool_name: 'Read', tool_use_id: 't1' }),
  ];
  const without = await only(events);
  const withU = await only([...events, okU(5), okU(6, [entry()], 'aaa1'), unkU(7)]);
  assert.equal(withU.last_seq, 4);
  assert.equal(withU.last_received_at, T0 + 4000);
  assert.deepEqual(strip(withU), strip(without));
});

test('既存の導出は UsageSnapshot が混ざっても変わらない（Stop の後に届いても待機のまま）', async () => {
  const events = [rec(1, 'UserPromptSubmit'), subStart(2, 'aaa1'), rec(3, 'SubagentStop', { agent_id: 'aaa1', agent_type: 'general-purpose' }), rec(4, 'Stop')];
  const before = await only(events);
  const after = await only([...events, okU(5), okU(6, [entry()], 'aaa1')]);
  assert.equal(after.status, 'waiting');
  assert.equal(child(after, 'aaa1').status, 'done');
  assert.deepEqual(strip(after), strip(before));
});

test('ノードもセッションも作らない（UsageSnapshot だけの系列はセッション無し）', async () => {
  assert.deepEqual(await derive([okU(1)]), { sessions: [] });
  assert.deepEqual(await derive([unkU(1, 'no_path', 'zzz9')]), { sessions: [] });
});

test('メインはあるがサブのノードが無い agent_id のスナップショットは表示に出ず、ノードも作られない', async () => {
  const s = await only([...base(), okU(3, [entry()], 'ghost1')]);
  assert.deepEqual(s.tree.children, []);
  assert.equal(s.tree.usage, null);
  assert.equal(s.usage_total.tokens.output, 0);
});

test('後からノードが現れれば、再導出でスナップショットが出る', async () => {
  const early = [...base(), okU(3, [entry({ output_tokens: 77 })], 'late1')];
  assert.equal((await only(early)).tree.children.length, 0);
  const later = await only([...early, subStart(4, 'late1')]);
  assert.equal(outTokens(child(later, 'late1')), 77);
  assert.equal(later.usage_total.tokens.output, 77);
});

test('入力レコードを書き換えない・配列順に依存しない', async () => {
  const records = [...base(), subStart(3, 'aaa1'), okU(4), okU(5, [entry()], 'aaa1')];
  const snapshot = structuredClone(records);
  const a = await derive(records);
  assert.deepEqual(records, snapshot);
  const b = await derive([...records].reverse());
  assert.deepEqual(b, a);
});

// ---------- 実サーバ: /api/state に載る形 ----------

test('/api/state のノードとセッションに usage / usage_total が載る（保存は events への追記）', async () => {
  await withServer(async (s) => {
    for (const e of [
      { schema_version: 1, event: 'SessionStart', session_id: SID },
      { schema_version: 1, event: 'SubagentStart', session_id: SID, agent_id: 'aaaaaaaaaaaaaaaaa', agent_type: 'general-purpose' },
      fixture('UsageSnapshot.main-ok'), fixture('UsageSnapshot.main-ok'), fixture('UsageSnapshot.sub-ok'),
    ]) assert.equal((await postEvent(s.port, e)).status, 201);
    assert.equal(s.store.count(), 5, 'UsageSnapshot も他のイベントと同じく追記される');
    const st = (await getState(s.port)).json;
    const sess = st.sessions[0];
    assert.equal(st.last_seq, 5, '全体の last_seq は保存済みの最大 seq');
    assert.equal(sess.last_seq, 2, 'セッションの last_seq は UsageSnapshot では進まない');
    assert.equal(sess.tree.usage.status, 'ok');
    assert.equal(sess.tree.usage.models[0].output_tokens, 995, '2 回送っても倍にならない');
    assert.equal(sess.tree.children[0].usage.status, 'ok');
    assert.equal(sess.usage_total.estimate, true);
    assert.equal(sess.usage_total.tokens.output, 995 + fixture('UsageSnapshot.sub-ok').models.reduce((a, m) => a + m.output_tokens, 0));
  });
});
