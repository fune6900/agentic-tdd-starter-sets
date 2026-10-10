// derive.mjs のテスト（Issue #19 / Red）。契約の全体像は server.test.mjs の冒頭コメントを見ろ。
//
//   deriveState(records: Record[]) -> { sessions: Session[] }       純関数（DB にも時計にも触れない）
//
//   Record  = { seq: number, received_at: number, ...検証済みペイロード }   store.list() の戻り値と同形（フラット）
//   Session = { session_id, status, last_seq, last_received_at, tree }
//             status: 'running' | 'waiting' | 'ended'        = メイドの状態（tree.status と同じ）
//             並び順: last_seq の降順（直近に動いたセッションが先頭）
//   Node    = { agent_id: string | null, agent_type: string, status, running_tools: RunningTool[], children: Node[] }
//             メイン: agent_id = null / agent_type = 'main' / status = 'running' | 'waiting' | 'ended'
//             サブ:   agent_id と agent_type はイベントの値 / status = 'running' | 'done'
//             children はメイン直下に初出順で並べる（サブエージェントの入れ子は表現しない）
//   RunningTool = { tool_use_id, tool_name, seq }   PreToolUse があり同 tool_use_id の PostToolUse が無いもの
//
//   - 順序は配列の並びではなく seq の昇順で畳む（送信側の値や配列順に依存しない）
//   - last_seq / last_received_at はそのセッションの最後（seq 最大）のレコードの値。時計を読まない
//   - 入力レコードを書き換えない

import test from 'node:test';
import assert from 'node:assert/strict';
import { load, rec, SESS, T0 } from './helpers.mjs';

const derive = async (records) => (await load('derive.mjs')).deriveState(records);

const pre = (seq, id, extra = {}, session) => rec(seq, 'PreToolUse', { tool_name: 'Read', tool_use_id: id, ...extra }, session);
const post = (seq, id, extra = {}, session) => rec(seq, 'PostToolUse', { tool_name: 'Read', tool_use_id: id, ...extra }, session);
const subStart = (seq, id, type = 'general-purpose') => rec(seq, 'SubagentStart', { agent_id: id, agent_type: type });
const subStop = (seq, id, type = 'general-purpose') => rec(seq, 'SubagentStop', { agent_id: id, agent_type: type });

const only = async (records) => {
  const { sessions } = await derive(records);
  assert.equal(sessions.length, 1, 'セッションは1つのはず');
  return sessions[0];
};
const toolIds = (node) => node.running_tools.map((t) => t.tool_use_id).sort();
const child = (session, id) => session.tree.children.find((c) => c.agent_id === id);

test('空の系列はセッション無し', async () => {
  assert.deepEqual(await derive([]), { sessions: [] });
});

test('メイン: UserPromptSubmit で稼働中。メインの agent_id は null・agent_type は main', async () => {
  const s = await only([rec(1, 'SessionStart'), rec(2, 'UserPromptSubmit')]);
  assert.equal(s.session_id, SESS);
  assert.equal(s.status, 'running');
  assert.equal(s.tree.status, 'running');
  assert.equal(s.tree.agent_id, null);
  assert.equal(s.tree.agent_type, 'main');
  assert.deepEqual(s.tree.children, []);
});

test('メイン: Stop で待機', async () => {
  const s = await only([rec(1, 'UserPromptSubmit'), rec(2, 'Stop')]);
  assert.equal(s.status, 'waiting');
  assert.equal(s.tree.status, 'waiting');
});

test('メイン: Notification で待機', async () => {
  const s = await only([rec(1, 'UserPromptSubmit'), rec(2, 'Notification')]);
  assert.equal(s.status, 'waiting');
});

test('メイン: SessionEnd で終了。同じ session_id の次の UserPromptSubmit で再び稼働中', async () => {
  const ended = await only([rec(1, 'UserPromptSubmit'), rec(2, 'Stop'), rec(3, 'SessionEnd')]);
  assert.equal(ended.status, 'ended');
  assert.equal(ended.tree.status, 'ended');
  const resumed = await only([rec(1, 'UserPromptSubmit'), rec(2, 'SessionEnd'), rec(3, 'UserPromptSubmit')]);
  assert.equal(resumed.status, 'running');
});

test('サブ: SubagentStart で稼働中、SubagentStop で完了（完了後も木に残る）。メインの状態は変えない', async () => {
  const started = await only([rec(1, 'UserPromptSubmit'), subStart(2, 'aaa1', 'sub-agent-coder')]);
  assert.equal(child(started, 'aaa1').status, 'running');
  assert.equal(child(started, 'aaa1').agent_type, 'sub-agent-coder');
  assert.equal(started.status, 'running');

  const stopped = await only([rec(1, 'UserPromptSubmit'), subStart(2, 'aaa1'), subStop(3, 'aaa1')]);
  assert.equal(stopped.tree.children.length, 1);
  assert.equal(child(stopped, 'aaa1').status, 'done');
  assert.equal(stopped.status, 'running', 'サブの完了でメインが待機にならない');
});

test('サブ: SubagentStart が無くても agent_id の初出（ツールイベント）で稼働中になる', async () => {
  const s = await only([
    rec(1, 'UserPromptSubmit'),
    pre(2, 'toolu_s1', { agent_id: 'bbb2', agent_type: 'general-purpose' }),
  ]);
  const c = child(s, 'bbb2');
  assert.ok(c, 'agent_id の初出でノードが作られる');
  assert.equal(c.status, 'running');
  assert.equal(c.agent_type, 'general-purpose');
  assert.deepEqual(toolIds(c), ['toolu_s1']);
});

test('サブ: 同じ agent_id の SubagentStart が重複しても1ノード。複数サブは初出順', async () => {
  const s = await only([
    rec(1, 'UserPromptSubmit'), subStart(2, 'ccc3'), subStart(3, 'ccc3'), subStart(4, 'ddd4'),
  ]);
  assert.deepEqual(s.tree.children.map((c) => c.agent_id), ['ccc3', 'ddd4']);
});

test('実行中ツール: Pre のみ → 実行中、同じ tool_use_id の Post で消える', async () => {
  const running = await only([rec(1, 'UserPromptSubmit'), pre(2, 'toolu_1')]);
  assert.deepEqual(toolIds(running.tree), ['toolu_1']);
  assert.equal(running.tree.running_tools[0].tool_name, 'Read');

  const done = await only([rec(1, 'UserPromptSubmit'), pre(2, 'toolu_1'), post(3, 'toolu_1')]);
  assert.deepEqual(done.tree.running_tools, []);
});

test('実行中ツール: 別の tool_use_id の Post では消えない。Pre の無い Post は無視される', async () => {
  const s = await only([rec(1, 'UserPromptSubmit'), pre(2, 'toolu_1'), pre(3, 'toolu_2'), post(4, 'toolu_2'), post(5, 'toolu_ghost')]);
  assert.deepEqual(toolIds(s.tree), ['toolu_1']);
});

test('実行中ツール: メインとサブは別々に持つ（Agent ツールはメイン側で実行中のまま）', async () => {
  const s = await only([
    rec(1, 'UserPromptSubmit'),
    pre(2, 'toolu_agent', { tool_name: 'Agent', subagent_type: 'general-purpose' }),
    subStart(3, 'eee5'),
    pre(4, 'toolu_sub', { agent_id: 'eee5', agent_type: 'general-purpose' }),
  ]);
  assert.deepEqual(toolIds(s.tree), ['toolu_agent']);
  assert.deepEqual(toolIds(child(s, 'eee5')), ['toolu_sub']);

  const after = await only([
    rec(1, 'UserPromptSubmit'),
    pre(2, 'toolu_agent', { tool_name: 'Agent', subagent_type: 'general-purpose' }),
    subStart(3, 'eee5'),
    pre(4, 'toolu_sub', { agent_id: 'eee5', agent_type: 'general-purpose' }),
    post(5, 'toolu_sub', { agent_id: 'eee5', agent_type: 'general-purpose' }),
    subStop(6, 'eee5'),
    post(7, 'toolu_agent', { tool_name: 'Agent' }),
  ]);
  assert.deepEqual(toolIds(after.tree), []);
  assert.deepEqual(toolIds(child(after, 'eee5')), []);
});

test('順序は seq で決まる: 配列を並べ替えても同じ結果になる', async () => {
  const ordered = [
    rec(1, 'SessionStart'), rec(2, 'UserPromptSubmit'), subStart(3, 'fff6'),
    pre(4, 'toolu_a', { agent_id: 'fff6', agent_type: 'general-purpose' }),
    post(5, 'toolu_a', { agent_id: 'fff6', agent_type: 'general-purpose' }),
    subStop(6, 'fff6'), rec(7, 'Stop'),
  ];
  const expected = await derive(ordered);
  const shuffled = [ordered[4], ordered[1], ordered[6], ordered[0], ordered[5], ordered[3], ordered[2]];
  assert.deepEqual(await derive(shuffled), expected);
  assert.deepEqual(await derive([...ordered].reverse()), expected);
  assert.equal(expected.sessions[0].status, 'waiting');
});

test('時刻は順序に使わない: received_at が逆転していても seq の順で畳む', async () => {
  const a = { ...rec(1, 'UserPromptSubmit'), received_at: T0 + 9000 };
  const b = { ...rec(2, 'Stop'), received_at: T0 + 1000 };
  const s = await only([a, b]);
  assert.equal(s.status, 'waiting');
  assert.equal(s.last_seq, 2);
  assert.equal(s.last_received_at, T0 + 1000, 'last_received_at は最終レコードの値（max ではない）');
});

test('複数セッションは独立して導出され、last_seq の降順に並ぶ', async () => {
  const { sessions } = await derive([
    rec(1, 'UserPromptSubmit', {}, 'sess-old'),
    rec(2, 'UserPromptSubmit', {}, 'sess-new'),
    rec(3, 'Stop', {}, 'sess-old'),
    pre(4, 'toolu_n', {}, 'sess-new'),
  ]);
  assert.deepEqual(sessions.map((s) => s.session_id), ['sess-new', 'sess-old']);
  assert.equal(sessions[0].status, 'running');
  assert.deepEqual(toolIds(sessions[0].tree), ['toolu_n']);
  assert.equal(sessions[1].status, 'waiting');
  assert.deepEqual(sessions[1].tree.running_tools, []);
  assert.equal(sessions[0].last_seq, 4);
  assert.equal(sessions[1].last_seq, 3);
});

test('別セッションの tool_use_id が一致しても互いのツールを消さない', async () => {
  const { sessions } = await derive([
    rec(1, 'UserPromptSubmit', {}, 's1'), pre(2, 'toolu_same', {}, 's1'),
    rec(3, 'UserPromptSubmit', {}, 's2'), pre(4, 'toolu_same', {}, 's2'), post(5, 'toolu_same', {}, 's2'),
  ]);
  const s1 = sessions.find((s) => s.session_id === 's1');
  const s2 = sessions.find((s) => s.session_id === 's2');
  assert.deepEqual(toolIds(s1.tree), ['toolu_same']);
  assert.deepEqual(toolIds(s2.tree), []);
});

test('入力レコードを書き換えない（deep freeze）', async () => {
  const records = [rec(1, 'UserPromptSubmit'), subStart(2, 'ggg7'), pre(3, 'toolu_f', { agent_id: 'ggg7', agent_type: 'general-purpose' })];
  for (const r of records) Object.freeze(r);
  Object.freeze(records);
  const s = await only(records);
  assert.deepEqual(toolIds(child(s, 'ggg7')), ['toolu_f']);
});

test('PostToolUse の duration_ms は状態導出に影響しない', async () => {
  const s = await only([rec(1, 'UserPromptSubmit'), pre(2, 'toolu_d'), post(3, 'toolu_d', { duration_ms: 3_600_000 }), rec(4, 'Stop')]);
  assert.equal(s.status, 'waiting');
  assert.deepEqual(s.tree.running_tools, []);
});
