// ビューの純関数（Issue #21 / Red）。DOM に触れない部分だけをここで固定する。
//
// ════════════════════════════════════════════════════════════════════════════
//  Coder への契約: .claude/monitor/public/app.js が export する関数（ES module。DOM 起動は document がある時だけ）
// ════════════════════════════════════════════════════════════════════════════
//  読み込み: import('../public/app.js')。package.json が無くても Node 22.22 は export 構文を検出して ESM として読める（実測済み）。
//            document / window / fetch / EventSource をトップレベルで参照しない（参照すると node から import できず全件 FAIL）
//
//    export const MAX_TIMELINE_EVENTS = 500        時系列の DOM 保持上限
//    export const MAX_AGENT_NAME_LENGTH = 64       未知の agent_type を出す時の長さ上限
//    export const SESSION_ID_SHORT_LENGTH = 8      セッション ID の短縮長
//
//    agentDisplayName(agentType, maxLength = MAX_AGENT_NAME_LENGTH) -> string
//        'main' -> 'Tech Lead' / 'sub-agent-<role>' 10 種 -> 役割名（Planner QA Architect Coder Designer Evaluator Tester
//        Spec Reviewer Code Reviewer Security Reviewer）。名前表は Object.hasOwn 相当で引く（__proto__ / constructor / toString は原文扱い）。
//        未知の文字列は原文。ただし長さが maxLength を超えたら、先頭 maxLength-1 文字 + '…'（結果は maxLength 文字ちょうど）。
//        HTML のエスケープはしない（描画側は textContent のみ。二重エスケープになる）。
//        文字列でない値・空文字は 'unknown'
//    statusLabel(status) -> string
//        running -> 稼働中 / waiting -> 待機 / done -> 完了 / ended -> 終了 / それ以外（非文字列・プロトタイプのキー含む）-> 不明
//    shortSessionId(sessionId) -> string           先頭 SESSION_ID_SHORT_LENGTH 文字。文字列でなければ ''
//    formatTime(epochMs) -> string                 UTC の 'HH:MM:SS'。有限の数値でなければ '--:--:--'
//    appendTimeline(events, record, limit = MAX_TIMELINE_EVENTS) -> object[]
//        到着順に末尾へ足し、limit を超えたら先頭（古い方）から捨てた「新しい配列」を返す。引数の配列は書き換えない
//    formatEventRow(record) -> { time, session, agent, event, tool, detail }   全て string（undefined / null を返さない）
//        time = formatTime(received_at) / session = shortSessionId(session_id)
//        agent = agent_id が無ければメイン（'Tech Lead'）、あれば agentDisplayName(agent_type)
//        event = event の原文 / tool = tool_name（無ければ ''）/ detail = file_path、無ければ bash_command、無ければ ''
//        欠けたキーがあっても投げない
//    formatSessionRow(session) -> { session, status, statusLabel, lastSeen }
//        session = shortSessionId(session_id) / status = 原文 / statusLabel = statusLabel(status) / lastSeen = formatTime(last_received_at)
//    flattenAgentTree(tree) -> { depth, agent_id, name, status, statusLabel, tools }[]
//        /api/state の sessions[].tree（メイン + children）を行きがけ順に平らにする。メインが depth 0、子が +1。
//        name = agentDisplayName(agent_type) / tools = running_tools の tool_name の配列（実行中が無ければ []）
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（防御を1つ外した隔離コピーで、左の変異に対し右のテストが FAIL するべき）
//  手順: .claude/monitor を一時ディレクトリへコピーし、左の変異を入れて右のファイルだけを node --test で走らせる
// ════════════════════════════════════════════════════════════════════════════
//   名前表を {} リテラルの添字引きにする（Object.hasOwn を外す）   [name] プロトタイプ汚染系（__proto__ / constructor / toString）が原文のまま返る
//   切り詰めを外す / 末尾 … を外す / 境界を ±1 ずらす              [name] 64 ちょうどは原文・65 は 63 文字 + …・既定長・maxLength 指定
//   未知名を空文字や 'unknown' に倒す                              [name] Explore / general-purpose / sub-agent-knowledge が原文
//   上限を超えても捨てない / 新しい方を捨てる / 引数を書き換える    [timeline] 600 件で 500 件・最古から捨てる・入力不変
//   MAX_TIMELINE_EVENTS を 500 以外にする                          [timeline] 定数が 500
//   formatEventRow で file_path / bash_command を欠落させる         [row] file_path / bash_command / ツールなし
//   描画前に HTML エスケープして返す                               [row] XSS 文字列が原文のまま（描画は textContent。二重エスケープを防ぐ）
//   役割名を足し忘れる                                             [name] 11 役割の全件・.claude/agents との突き合わせ

import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { load, MONITOR_DIR } from './helpers.mjs';

const AGENTS_DIR = join(MONITOR_DIR, '..', 'agents');

const app = () => import('../public/app.js');

const T0 = 1_700_000_000_000; // 2023-11-14T22:13:20Z

// ---------- 読み込み ----------

test('[import] public/app.js を DOM 無しの node から import でき、純関数と定数が export されている', async () => {
  const m = await app();
  for (const name of [
    'agentDisplayName', 'statusLabel', 'shortSessionId', 'formatTime', 'appendTimeline', 'formatEventRow', 'formatSessionRow', 'flattenAgentTree',
  ]) {
    assert.equal(typeof m[name], 'function', `${name} が関数として export されていない`);
  }
  assert.equal(typeof document, 'undefined', 'テスト環境に document がある（検査が成り立たない）');
});

test('[import] 定数: MAX_TIMELINE_EVENTS=500 / MAX_AGENT_NAME_LENGTH=64 / SESSION_ID_SHORT_LENGTH=8', async () => {
  const m = await app();
  assert.equal(m.MAX_TIMELINE_EVENTS, 500);
  assert.equal(m.MAX_AGENT_NAME_LENGTH, 64);
  assert.equal(m.SESSION_ID_SHORT_LENGTH, 8);
});

// ---------- [name] 名前対応 ----------

const ROLE_TABLE = Object.freeze({
  main: 'Tech Lead',
  'sub-agent-planner': 'Planner',
  'sub-agent-qa': 'QA',
  'sub-agent-architect': 'Architect',
  'sub-agent-coder': 'Coder',
  'sub-agent-designer': 'Designer',
  'sub-agent-evaluator': 'Evaluator',
  'sub-agent-tester': 'Tester',
  'sub-agent-spec-reviewer': 'Spec Reviewer',
  'sub-agent-code-reviewer': 'Code Reviewer',
  'sub-agent-security-reviewer': 'Security Reviewer',
});

test('[name] CLAUDE.md の 11 役割（main + sub-agent-* 10 体）が役割名に対応する', async () => {
  const { agentDisplayName } = await app();
  assert.equal(Object.keys(ROLE_TABLE).length, 11);
  for (const [type, name] of Object.entries(ROLE_TABLE)) {
    assert.equal(agentDisplayName(type), name, type);
  }
});

test('[name] .claude/agents/ の sub-agent-*.md は sub-agent-knowledge を除き全て役割名に対応している（追加時の対応漏れを検知）', async () => {
  const { agentDisplayName } = await app();
  const files = readdirSync(AGENTS_DIR).filter((f) => /^sub-agent-.+\.md$/.test(f));
  assert.ok(files.length >= 10, `検査対象が少なすぎる: ${files.length}`);
  for (const f of files) {
    const type = f.replace(/\.md$/, '');
    if (type === 'sub-agent-knowledge') continue; // 11 役割に入らない。未知として原文を出す（下のテスト）
    assert.ok(Object.hasOwn(ROLE_TABLE, type), `${type} が ROLE_TABLE（このテストの 11 役割）に無い。対応表を更新するか判断せよ`);
    assert.equal(agentDisplayName(type), ROLE_TABLE[type], type);
  }
});

test('[name] 未知の agent_type（Explore / general-purpose / sub-agent-knowledge）は原文を返す', async () => {
  const { agentDisplayName } = await app();
  for (const type of ['Explore', 'general-purpose', 'sub-agent-knowledge', 'Plan', 'sub-agent-', 'sub-agent-coder2', 'Main', 'MAIN']) {
    assert.equal(agentDisplayName(type), type);
  }
});

test('[name] 大文字小文字・前後の空白が違うものは役割名に対応させない（完全一致）', async () => {
  const { agentDisplayName } = await app();
  for (const type of ['Sub-Agent-Coder', 'SUB-AGENT-CODER', ' sub-agent-coder', 'sub-agent-coder ', 'sub-agent-coder\n']) {
    assert.equal(agentDisplayName(type), type, JSON.stringify(type));
  }
});

test('[name] 非文字列・空文字は unknown', async () => {
  const { agentDisplayName } = await app();
  for (const v of [undefined, null, '', 0, 1, true, false, {}, [], ['main'], { toString: () => 'main' }, Symbol('x'), 10n]) {
    assert.equal(agentDisplayName(v), 'unknown', String(typeof v));
  }
});

test('[name] プロトタイプ汚染系（__proto__ / constructor / toString 等）は名前表から引かず原文を返す', async () => {
  const { agentDisplayName } = await app();
  for (const type of [
    '__proto__', 'constructor', 'toString', 'valueOf', 'hasOwnProperty', 'isPrototypeOf', 'propertyIsEnumerable',
    'toLocaleString', '__defineGetter__', '__lookupGetter__', 'prototype',
  ]) {
    const got = agentDisplayName(type);
    assert.equal(typeof got, 'string', `${type}: 文字列でない（関数やオブジェクトを返した）`);
    assert.equal(got, type, type);
  }
});

test('[name] 名前表の汚染がテスト間で起きない: 呼び出しの後も Object.prototype に役割名のキーが生えない', async () => {
  const { agentDisplayName } = await app();
  agentDisplayName('__proto__');
  agentDisplayName('constructor');
  assert.equal(Object.hasOwn(Object.prototype, 'main'), false);
  assert.equal(({}).polluted, undefined);
});

test('[name] 未知名の長さ制限: 既定 64 文字ちょうどは原文、65 文字は 63 文字 + … （64 文字）', async () => {
  const { agentDisplayName, MAX_AGENT_NAME_LENGTH } = await app();
  const exact = 'x'.repeat(MAX_AGENT_NAME_LENGTH);
  assert.equal(agentDisplayName(exact), exact);
  assert.equal(agentDisplayName('x'.repeat(63)), 'x'.repeat(63));
  const over = agentDisplayName('x'.repeat(65));
  assert.equal(over, `${'x'.repeat(63)}…`);
  assert.equal([...over].length, 64);
  const huge = agentDisplayName('y'.repeat(10_000));
  assert.equal(huge, `${'y'.repeat(63)}…`);
});

test('[name] maxLength 引数で上限を変えられる（切り詰め後も maxLength 文字ちょうど）', async () => {
  const { agentDisplayName } = await app();
  assert.equal(agentDisplayName('abcdefghij', 5), 'abcd…');
  assert.equal(agentDisplayName('abcde', 5), 'abcde');
  assert.equal(agentDisplayName('abcdef', 5), 'abcd…');
  assert.equal(agentDisplayName('abcdefghij', 10), 'abcdefghij');
  assert.equal(agentDisplayName('abcdefghijk', 10), 'abcdefghi…');
});

test('[name] 役割名に当たる名前は maxLength に関係なく役割名のまま（切り詰めは未知名にだけ効く）', async () => {
  const { agentDisplayName } = await app();
  assert.equal(agentDisplayName('sub-agent-security-reviewer', 5), 'Security Reviewer');
  assert.equal(agentDisplayName('main', 1), 'Tech Lead');
});

test('[name] 未知名の HTML っぽい文字列は原文のまま返す（描画は textContent。ここでエスケープしない）', async () => {
  const { agentDisplayName } = await app();
  const xss = '<img src=x onerror=alert(1)>';
  assert.equal(agentDisplayName(xss), xss);
});

// ---------- [status] 状態ラベル ----------

test('[status] running→稼働中 / waiting→待機 / done→完了 / ended→終了', async () => {
  const { statusLabel } = await app();
  assert.equal(statusLabel('running'), '稼働中');
  assert.equal(statusLabel('waiting'), '待機');
  assert.equal(statusLabel('done'), '完了');
  assert.equal(statusLabel('ended'), '終了');
});

test('[status] 不明な値（未知の文字列・非文字列・プロトタイプのキー・大文字小文字違い）は 不明', async () => {
  const { statusLabel } = await app();
  for (const v of [
    'paused', '', 'Running', 'RUNNING', ' running', 'running ', undefined, null, 0, {}, [], true,
    '__proto__', 'constructor', 'toString', 'hasOwnProperty', 'valueOf',
  ]) {
    assert.equal(statusLabel(v), '不明', JSON.stringify(v));
  }
});

// ---------- [row] 表示用の整形 ----------

test('[row] shortSessionId: 先頭 8 文字。短ければそのまま。非文字列は空', async () => {
  const { shortSessionId } = await app();
  assert.equal(shortSessionId('11111111-1111-4111-8111-111111111111'), '11111111');
  assert.equal(shortSessionId('abc'), 'abc');
  assert.equal(shortSessionId(''), '');
  for (const v of [undefined, null, 123, {}]) assert.equal(shortSessionId(v), '');
});

test('[row] formatTime: UTC の HH:MM:SS。ゼロ埋め。日をまたぐ境界。数値でなければ --:--:--', async () => {
  const { formatTime } = await app();
  assert.equal(formatTime(0), '00:00:00');
  assert.equal(formatTime(T0), '22:13:20');
  assert.equal(formatTime(86_399_999), '23:59:59');
  assert.equal(formatTime(86_400_000), '00:00:00');
  assert.equal(formatTime(5_000), '00:00:05');
  assert.equal(formatTime(3_661_000), '01:01:01');
  for (const v of [undefined, null, '1700000000000', NaN, Infinity, -Infinity, {}]) {
    assert.equal(formatTime(v), '--:--:--', String(v));
  }
});

const base = (extra) => ({ seq: 1, received_at: T0, session_id: '11111111-1111-4111-8111-111111111111', schema_version: 1, ...extra });

test('[row] formatEventRow: メイン（agent_id 無し）のツールイベントは 時刻・セッション短縮・Tech Lead・イベント名・ツール名', async () => {
  const { formatEventRow } = await app();
  const row = formatEventRow(base({ event: 'PreToolUse', tool_name: 'Read', tool_use_id: 'toolu_1', file_path: 'app.js' }));
  assert.equal(row.time, '22:13:20');
  assert.equal(row.session, '11111111');
  assert.equal(row.agent, 'Tech Lead');
  assert.equal(row.event, 'PreToolUse');
  assert.equal(row.tool, 'Read');
  assert.equal(row.detail, 'app.js');
});

test('[row] formatEventRow: サブエージェントのイベントは agent_type を役割名にする。未知の型は原文', async () => {
  const { formatEventRow } = await app();
  const coder = formatEventRow(base({ event: 'SubagentStart', agent_id: 'a1', agent_type: 'sub-agent-coder' }));
  assert.equal(coder.agent, 'Coder');
  assert.equal(coder.event, 'SubagentStart');
  const unknown = formatEventRow(base({ event: 'SubagentStart', agent_id: 'a2', agent_type: 'Explore' }));
  assert.equal(unknown.agent, 'Explore');
  const noType = formatEventRow(base({ event: 'PreToolUse', agent_id: 'a3', tool_name: 'Bash', tool_use_id: 't', bash_command: 'ls' }));
  assert.equal(noType.agent, 'unknown', 'agent_id はあるが agent_type が無い');
});

test('[row] formatEventRow: bash_command は detail に出る。file_path があればそちらが優先', async () => {
  const { formatEventRow } = await app();
  const bash = formatEventRow(base({ event: 'PostToolUse', tool_name: 'Bash', tool_use_id: 't', bash_command: 'git' }));
  assert.equal(bash.tool, 'Bash');
  assert.equal(bash.detail, 'git');
  const both = formatEventRow(base({ event: 'PreToolUse', tool_name: 'Edit', tool_use_id: 't', file_path: 'a.ts', bash_command: 'x' }));
  assert.equal(both.detail, 'a.ts');
});

test('[row] formatEventRow: ツールの無いイベントは tool と detail が空文字（undefined / "undefined" を出さない）', async () => {
  const { formatEventRow } = await app();
  for (const event of ['SessionStart', 'SessionEnd', 'UserPromptSubmit', 'Stop', 'Notification', 'PreCompact']) {
    const row = formatEventRow(base({ event }));
    assert.equal(row.tool, '', event);
    assert.equal(row.detail, '', event);
    assert.equal(row.event, event);
    for (const [k, v] of Object.entries(row)) assert.equal(typeof v, 'string', `${event}.${k}`);
  }
});

test('[row] formatEventRow: 欠けたキーだらけの入力でも投げず、全フィールドが文字列', async () => {
  const { formatEventRow } = await app();
  for (const rec of [{}, { seq: 1 }, { event: 'Stop' }, { received_at: 'x', session_id: 5, event: 7 }]) {
    const row = formatEventRow(rec);
    for (const k of ['time', 'session', 'agent', 'event', 'tool', 'detail']) {
      assert.equal(typeof row[k], 'string', `${JSON.stringify(rec)}.${k}`);
      assert.ok(!/undefined|null|NaN/.test(row[k]) || k === 'event', `${JSON.stringify(rec)}.${k} = ${row[k]}`);
    }
  }
});

test('[row] formatEventRow: 外部由来の値（file_path・bash_command・tool_name・agent_type）は加工せず原文（<>"\' を含んでも）', async () => {
  const { formatEventRow } = await app();
  const nasty = `<img src=x onerror=alert(1)>"'&`;
  const r1 = formatEventRow(base({ event: 'PreToolUse', tool_name: 'Read', tool_use_id: 't', file_path: nasty }));
  assert.equal(r1.detail, nasty);
  const r2 = formatEventRow(base({ event: 'PreToolUse', tool_name: 'Bash', tool_use_id: 't', bash_command: nasty }));
  assert.equal(r2.detail, nasty);
  const r3 = formatEventRow(base({ event: 'SubagentStart', agent_id: 'a', agent_type: nasty }));
  assert.equal(r3.agent, nasty);
  const r4 = formatEventRow(base({ event: 'PreToolUse', tool_name: nasty, tool_use_id: 't' }));
  assert.equal(r4.tool, nasty);
});

test('[row] formatEventRow: file_path が長くても切らない（サーバが 128 バイトで制限済み。表示側で欠落させない）', async () => {
  const { formatEventRow } = await app();
  const long = 'f'.repeat(128);
  assert.equal(formatEventRow(base({ event: 'PreToolUse', tool_name: 'Read', tool_use_id: 't', file_path: long })).detail, long);
});

test('[row] formatSessionRow: 短縮 ID・原文の状態・状態ラベル・最終受信時刻', async () => {
  const { formatSessionRow } = await app();
  const row = formatSessionRow({ session_id: '22222222-2222-4222-8222-222222222222', status: 'waiting', last_seq: 9, last_received_at: T0, tree: {} });
  assert.equal(row.session, '22222222');
  assert.equal(row.status, 'waiting');
  assert.equal(row.statusLabel, '待機');
  assert.equal(row.lastSeen, '22:13:20');
  assert.equal(formatSessionRow({ session_id: 's', status: 'bogus', last_received_at: 0 }).statusLabel, '不明');
});

// ---------- [timeline] リングバッファ ----------

const ev = (seq) => ({ seq, event: 'Stop' });

test('[timeline] 上限以下なら到着順に足す。新しい配列を返し、入力を書き換えない', async () => {
  const { appendTimeline } = await app();
  const before = [ev(1), ev(2)];
  const snapshot = JSON.stringify(before);
  const out = appendTimeline(before, ev(3));
  assert.deepEqual(out.map((e) => e.seq), [1, 2, 3]);
  assert.notEqual(out, before, '同じ配列を返した');
  assert.equal(JSON.stringify(before), snapshot, '引数の配列が書き換えられた');
  assert.deepEqual(appendTimeline([], ev(1)).map((e) => e.seq), [1]);
});

test('[timeline] 上限（既定 500）を超えたら古い順に捨てる。500 件ちょうどは捨てない', async () => {
  const { appendTimeline, MAX_TIMELINE_EVENTS } = await app();
  assert.equal(MAX_TIMELINE_EVENTS, 500);
  let buf = [];
  for (let i = 1; i <= 500; i += 1) buf = appendTimeline(buf, ev(i));
  assert.equal(buf.length, 500);
  assert.equal(buf[0].seq, 1, '500 件ちょうどで先頭を捨てた');
  buf = appendTimeline(buf, ev(501));
  assert.equal(buf.length, 500);
  assert.equal(buf[0].seq, 2, '最古（seq 1）が捨てられていない');
  assert.equal(buf[499].seq, 501, '最新が末尾にない');
});

test('[timeline] 600 件流しても 500 件を超えない。残るのは最新 500 件（101..600）で到着順', async () => {
  const { appendTimeline } = await app();
  let buf = [];
  for (let i = 1; i <= 600; i += 1) {
    buf = appendTimeline(buf, ev(i));
    assert.ok(buf.length <= 500, `${i} 件目で ${buf.length} 件`);
  }
  assert.deepEqual(buf.map((e) => e.seq), Array.from({ length: 500 }, (_, i) => 101 + i));
});

test('[timeline] limit 引数で上限を変えられる（古い方から捨てる）', async () => {
  const { appendTimeline } = await app();
  let buf = [];
  for (let i = 1; i <= 5; i += 1) buf = appendTimeline(buf, ev(i), 3);
  assert.deepEqual(buf.map((e) => e.seq), [3, 4, 5]);
  assert.deepEqual(appendTimeline([ev(1)], ev(2), 1).map((e) => e.seq), [2]);
});

test('[timeline] すでに上限を超えている入力（過去の不具合・上限引き下げ）を渡しても、結果は上限以内に収まる', async () => {
  const { appendTimeline } = await app();
  const big = Array.from({ length: 700 }, (_, i) => ev(i + 1));
  const out = appendTimeline(big, ev(701));
  assert.equal(out.length, 500);
  assert.equal(out[0].seq, 202);
  assert.equal(out[499].seq, 701);
  assert.equal(big.length, 700, '入力を書き換えた');
});

// ---------- [tree] エージェント木 ----------

function rec(seq, extra) {
  return { seq, received_at: T0 + seq * 1000, session_id: '11111111-1111-4111-8111-111111111111', ...extra };
}

test('[tree] flattenAgentTree: deriveState の木（メイン→サブ）を行きがけ順に平らにし、実行中ツールと状態ラベルを持つ', async () => {
  const { flattenAgentTree } = await app();
  const { deriveState } = await load('derive.mjs');
  const records = [
    rec(1, { event: 'SessionStart' }),
    rec(2, { event: 'UserPromptSubmit' }),
    rec(3, { event: 'PreToolUse', tool_name: 'Agent', tool_use_id: 'toolu_m1' }),
    rec(4, { event: 'SubagentStart', agent_id: 'a1', agent_type: 'sub-agent-coder' }),
    rec(5, { event: 'PreToolUse', agent_id: 'a1', agent_type: 'sub-agent-coder', tool_name: 'Bash', tool_use_id: 'toolu_s1' }),
    rec(6, { event: 'SubagentStart', agent_id: 'a2', agent_type: 'Explore' }),
  ];
  const [session] = deriveState(records).sessions;
  const rows = flattenAgentTree(session.tree);
  assert.deepEqual(rows.map((r) => [r.depth, r.name, r.status, r.statusLabel, r.tools]), [
    [0, 'Tech Lead', 'running', '稼働中', ['Agent']],
    [1, 'Coder', 'running', '稼働中', ['Bash']],
    [1, 'Explore', 'running', '稼働中', []],
  ]);
  assert.equal(rows[0].agent_id, null, 'メインの agent_id は null（derive の出力のまま）');
  assert.equal(rows[1].agent_id, 'a1');
});

test('[tree] flattenAgentTree: SubagentStop で子が 完了 に変わり、PostToolUse で実行中ツールが消える', async () => {
  const { flattenAgentTree } = await app();
  const { deriveState } = await load('derive.mjs');
  const records = [
    rec(1, { event: 'UserPromptSubmit' }),
    rec(2, { event: 'SubagentStart', agent_id: 'a1', agent_type: 'sub-agent-tester' }),
    rec(3, { event: 'PreToolUse', agent_id: 'a1', agent_type: 'sub-agent-tester', tool_name: 'Read', tool_use_id: 'toolu_s1' }),
    rec(4, { event: 'PostToolUse', agent_id: 'a1', agent_type: 'sub-agent-tester', tool_name: 'Read', tool_use_id: 'toolu_s1' }),
    rec(5, { event: 'SubagentStop', agent_id: 'a1', agent_type: 'sub-agent-tester' }),
    rec(6, { event: 'Stop' }),
  ];
  const rows = flattenAgentTree(deriveState(records).sessions[0].tree);
  assert.deepEqual(rows.map((r) => [r.depth, r.name, r.statusLabel, r.tools]), [
    [0, 'Tech Lead', '待機', []],
    [1, 'Tester', '完了', []],
  ]);
});

test('[tree] flattenAgentTree: 孫以降も再帰し depth を +1 ずつ増やす。running_tools が複数なら全て並べる', async () => {
  const { flattenAgentTree } = await app();
  const tree = {
    agent_id: null, agent_type: 'main', status: 'running',
    running_tools: [{ tool_use_id: 'a', tool_name: 'Read', seq: 1 }, { tool_use_id: 'b', tool_name: 'Grep', seq: 2 }],
    children: [{
      agent_id: 'c1', agent_type: 'sub-agent-planner', status: 'running', running_tools: [],
      children: [{ agent_id: 'g1', agent_type: 'sub-agent-qa', status: 'done', running_tools: [], children: [] }],
    }, {
      agent_id: 'c2', agent_type: 'sub-agent-designer', status: 'done', running_tools: [], children: [],
    }],
  };
  const rows = flattenAgentTree(tree);
  assert.deepEqual(rows.map((r) => [r.depth, r.name]), [[0, 'Tech Lead'], [1, 'Planner'], [2, 'QA'], [1, 'Designer']]);
  assert.deepEqual(rows[0].tools, ['Read', 'Grep']);
  assert.equal(rows[2].statusLabel, '完了');
});

test('[tree] flattenAgentTree: 未知の状態は 不明、未知の agent_type は原文（長さ制限付き）、XSS 文字列は原文のまま', async () => {
  const { flattenAgentTree } = await app();
  const xss = '<img src=x onerror=alert(1)>';
  const tree = {
    agent_id: null, agent_type: 'main', status: 'weird', running_tools: [],
    children: [
      { agent_id: 'x', agent_type: xss, status: 'running', running_tools: [{ tool_use_id: 't', tool_name: xss, seq: 1 }], children: [] },
      { agent_id: 'y', agent_type: 'z'.repeat(100), status: 'running', running_tools: [], children: [] },
    ],
  };
  const rows = flattenAgentTree(tree);
  assert.equal(rows[0].statusLabel, '不明');
  assert.equal(rows[1].name, xss);
  assert.deepEqual(rows[1].tools, [xss]);
  assert.equal(rows[2].name, `${'z'.repeat(63)}…`);
});
