// validate.mjs のテスト（Issue #19 / Red）。契約の全体像は server.test.mjs の冒頭コメントを見ろ。
//
// 入力仕様は .claude/monitor/docs/event-schema.md だけ。推測しない（lessons #6）。
// 倒す向きは **fail closed**: 判定不能・仕様外は全て拒否（フック側 #18 は fail open で逆向き）。
//
//   validateEvent(obj: unknown) -> {ok: true, event} | {ok: false, reason: string}
//   - 純関数。例外を投げない（どんな入力でも ok:false を返す）。入力を書き換えない
//   - reason は固定文言のみ。入力値（秘密かもしれない）を載せない
//   - 許可キーは「全イベント共通 + そのイベントの必須 + 任意」だけ。他は全て拒否
//     （例: Stop に tool_name、PreToolUse に duration_ms、bash_command は tool_name が Bash の時だけ）
//   - 識別子系は許可文字の「文字列全体」完全一致（複数行不可。lessons #10）。最大はバイト長
//   - 数値は値が整数で範囲内なら可（JSON の 1.0 は JS では 1。値の整数性で判定）

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { cleanupTmp, emittedFixtures, load, SID } from './helpers.mjs';

after(cleanupTmp);

const validate = async (obj) => (await load('validate.mjs')).validateEvent(obj);
const base = (event, extra = {}) => ({ schema_version: 1, event, session_id: SID, ...extra });
const pre = (extra = {}) => base('PreToolUse', { tool_name: 'Read', tool_use_id: 'toolu_x1', ...extra });
const post = (extra = {}) => base('PostToolUse', { tool_name: 'Read', tool_use_id: 'toolu_x1', ...extra });
const sub = (event, extra = {}) => base(event, { agent_id: 'a1b2', agent_type: 'general-purpose', ...extra });

async function expectOk(obj, label) {
  const r = await validate(obj);
  assert.equal(r.ok, true, `${label ?? JSON.stringify(obj)} は受理されるはず。reason=${r.reason}`);
  return r;
}
async function expectNg(obj, label) {
  const r = await validate(obj);
  assert.equal(r.ok, false, `${label ?? JSON.stringify(obj)} は拒否されるはず`);
  assert.equal(typeof r.reason, 'string');
  assert.ok(r.reason.length > 0);
}

// ---------- 契約: 全 emitted fixture ----------

test('全 emitted fixture を受理し、event は入力と等しい', async () => {
  const fx = emittedFixtures();
  assert.ok(fx.length >= 20, `fixture が少なすぎる: ${fx.length}`);
  for (const f of fx) {
    const r = await expectOk(f.obj, f.name);
    assert.deepEqual(r.event, f.obj, f.name);
  }
});

test('入力を書き換えない（deep freeze しても例外にならない）', async () => {
  const f = emittedFixtures().find((x) => x.name === 'SubagentStop.with-usage').obj;
  const frozen = structuredClone(f);
  Object.freeze(frozen);
  Object.freeze(frozen.usage);
  await expectOk(frozen);
});

// ---------- 型・トップレベル ----------

test('オブジェクト以外（null / 配列 / 文字列 / 数値 / 真偽値 / undefined）は拒否', async () => {
  for (const v of [null, [], [base('Stop')], 'Stop', 42, true, undefined]) await expectNg(v, String(v));
});

test('schema_version は整数 1 のみ', async () => {
  for (const sv of [2, 0, '1', 1.5, null, true, [1]]) await expectNg({ ...base('Stop'), schema_version: sv }, `sv=${String(sv)}`);
  const { schema_version: _drop, ...noSv } = base('Stop');
  await expectNg(noSv, 'schema_version 欠落');
});

test('スキーマ外のキーは拒否する（落として受理ではなく拒否。fail closed）', async () => {
  for (const k of ['cwd', 'prompt', 'transcript_path', 'tool_input', 'tool_response', 'ts', 'timestamp', 'extra', 'prompt_id', 'permission_mode']) {
    await expectNg({ ...base('Stop'), [k]: 'x' }, k);
  }
});

test('__proto__ / constructor という own キーも未知キーとして拒否する', async () => {
  const withProto = JSON.parse(`{"schema_version":1,"event":"Stop","session_id":"${SID}","__proto__":{"x":1}}`);
  assert.ok(Object.hasOwn(withProto, '__proto__'));
  await expectNg(withProto, '__proto__');
  await expectNg({ ...base('Stop'), constructor: 'x' }, 'constructor');
});

test('任意キーに null を入れたら拒否（省略は可、null は不可）', async () => {
  for (const k of ['agent_id', 'agent_type', 'file_path', 'duration_ms', 'bash_command']) {
    await expectNg(post({ [k]: null }), k);
  }
});

// ---------- event 列挙 ----------

test('10 種のイベントを最小形で受理する', async () => {
  const minimal = [
    base('SessionStart'), base('SessionEnd'), base('UserPromptSubmit'), pre(), post(),
    sub('SubagentStart'), sub('SubagentStop'), base('Stop'), base('Notification'), base('PreCompact'),
  ];
  for (const m of minimal) await expectOk(m, m.event);
});

test('列挙外・大文字小文字違い・型違い・33 バイトの event は拒否', async () => {
  for (const e of ['Foo', 'stop', 'STOP', 'Stop ', 'Stop\n', '', null, 1, ['Stop'], 'S'.repeat(33), 'Stop'.padEnd(32, 'x')]) {
    await expectNg({ ...base('Stop'), event: e }, `event=${String(e)}`);
  }
});

// ---------- イベント別の必須・許可キー ----------

const REQUIRED = {
  SessionStart: [], SessionEnd: [], UserPromptSubmit: [], Stop: [], Notification: [], PreCompact: [],
  PreToolUse: ['tool_name', 'tool_use_id'], PostToolUse: ['tool_name', 'tool_use_id'],
  SubagentStart: ['agent_id', 'agent_type'], SubagentStop: ['agent_id', 'agent_type'],
};
const OPTIONAL = {
  SessionStart: ['source'], SessionEnd: ['reason'], UserPromptSubmit: [], Notification: [], PreCompact: ['trigger'],
  PreToolUse: ['agent_id', 'agent_type', 'subagent_type', 'bash_command', 'file_path'],
  PostToolUse: ['agent_id', 'agent_type', 'bash_command', 'file_path', 'duration_ms'],
  SubagentStart: [], SubagentStop: ['stop_hook_active', 'model', 'usage'], Stop: ['stop_hook_active', 'model', 'usage'],
};
const ALL_KEYS = [
  'agent_id', 'agent_type', 'source', 'reason', 'trigger', 'tool_name', 'tool_use_id', 'subagent_type',
  'bash_command', 'file_path', 'duration_ms', 'stop_hook_active', 'model', 'usage',
];
const SAMPLE = {
  agent_id: 'a1b2', agent_type: 'general-purpose', source: 'startup', reason: 'other', trigger: 'manual',
  tool_name: 'Read', tool_use_id: 'toolu_x1', subagent_type: 'general-purpose', bash_command: 'ls',
  file_path: 'hello.txt', duration_ms: 5, stop_hook_active: false, model: 'claude-x-1', usage: { input_tokens: 1 },
};
const eventWith = (event, keys) => {
  const o = base(event);
  for (const k of keys) o[k] = SAMPLE[k];
  // 相互条件: bash_command は Bash の時だけ、subagent_type は Agent の時だけ
  if (keys.includes('bash_command')) o.tool_name = 'Bash';
  if (keys.includes('subagent_type')) o.tool_name = 'Agent';
  return o;
};

test('必須キーが1つでも欠けたら拒否（イベント別）', async () => {
  for (const [event, req] of Object.entries(REQUIRED)) {
    for (const missing of req) {
      const o = eventWith(event, req);
      delete o[missing];
      await expectNg(o, `${event} から ${missing} を欠落`);
    }
  }
});

test('そのイベントで許可された任意キーは全て受理する', async () => {
  for (const event of Object.keys(REQUIRED)) {
    for (const k of OPTIONAL[event]) {
      await expectOk(eventWith(event, [...REQUIRED[event], k]), `${event} + ${k}`);
    }
  }
});

test('そのイベントに許可されていないキーは（値が正しくても）拒否する', async () => {
  for (const event of Object.keys(REQUIRED)) {
    const allowed = new Set([...REQUIRED[event], ...OPTIONAL[event]]);
    for (const k of ALL_KEYS.filter((x) => !allowed.has(x))) {
      const o = eventWith(event, REQUIRED[event]);
      o[k] = SAMPLE[k];
      await expectNg(o, `${event} に ${k}`);
    }
  }
});

test('bash_command は tool_name が Bash の時だけ、subagent_type は Agent の時だけ許可', async () => {
  await expectNg(pre({ tool_name: 'Read', bash_command: 'ls' }), 'Read + bash_command');
  await expectNg(post({ tool_name: 'Write', bash_command: '?' }), 'Write + bash_command');
  await expectNg(pre({ tool_name: 'Read', subagent_type: 'general-purpose' }), 'Read + subagent_type');
  await expectOk(pre({ tool_name: 'Bash', bash_command: 'ls' }));
  await expectOk(pre({ tool_name: 'Agent', subagent_type: 'general-purpose' }));
});

// ---------- 識別子系: 許可文字・最大 64 バイト・複数行不可・型 ----------

const IDENT = [
  // [キー名, 許可文字の代表, 許可外の代表（1文字）, 組み立て]
  ['session_id', 'a', ['_', ' ', '.', '/', 'é'], (v) => base('Stop', { session_id: v })],
  ['agent_id', 'a', ['-', '_', ' ', '.'], (v) => pre({ agent_id: v })],
  ['agent_type', 'a', [' ', '.', '/', '日'], (v) => pre({ agent_id: 'a1', agent_type: v })],
  ['tool_name', 'a', [' ', '.', '/', ':'], (v) => pre({ tool_name: v })],
  ['tool_use_id', 'a', ['-', ' ', '.', '/'], (v) => pre({ tool_use_id: v })],
  ['subagent_type', 'a', [' ', '.', '/'], (v) => pre({ tool_name: 'Agent', subagent_type: v })],
  ['model', 'a', [' ', '/', ':', '日'], (v) => base('Stop', { model: v })],
];

for (const [key, ch, badChars, build] of IDENT) {
  test(`${key}: ちょうど 64 バイトは受理、65 バイトは拒否`, async () => {
    await expectOk(build(ch.repeat(64)), `${key} 64`);
    await expectNg(build(ch.repeat(65)), `${key} 65`);
  });

  test(`${key}: 空文字・許可外文字・複数行（末尾改行を含む）は拒否`, async () => {
    await expectNg(build(''), `${key} 空`);
    for (const bad of badChars) await expectNg(build(`ab${bad}cd`), `${key} に ${JSON.stringify(bad)}`);
    // grep 的な行単位判定ならすり抜ける形（lessons #10）
    await expectNg(build('abc\nabc'), `${key} 複数行`);
    await expectNg(build('abc\n'), `${key} 末尾改行`);
    await expectNg(build('\nabc'), `${key} 先頭改行`);
    await expectNg(build('abc\r'), `${key} CR`);
    await expectNg(build('abc\0'), `${key} NUL`);
  });

  test(`${key}: 文字列以外（数値・真偽値・配列・オブジェクト）は拒否`, async () => {
    for (const v of [1, true, ['a'], { a: 1 }]) await expectNg(build(v), `${key}=${JSON.stringify(v)}`);
  });
}

test('識別子ごとの許可文字の差（session_id はハイフン可・agent_id は不可・tool_use_id はアンダースコア可）', async () => {
  await expectOk(base('Stop', { session_id: 'a-b-c' }));
  await expectNg(pre({ agent_id: 'a-b' }));
  await expectOk(pre({ tool_use_id: 'toolu_a_b' }));
  await expectNg(base('Stop', { session_id: 'a_b' }));
  await expectOk(pre({ tool_name: 'mcp-x_y' }));
  await expectOk(base('Stop', { model: 'claude-haiku-4-5.1_x' }));
});

// ---------- 列挙値 ----------

test('source / reason / trigger は列挙値の完全一致だけ', async () => {
  for (const s of ['startup', 'resume', 'clear', 'compact', 'fork']) await expectOk(base('SessionStart', { source: s }));
  for (const s of ['Startup', 'unknown', '', 'startup\n', null, 1]) await expectNg(base('SessionStart', { source: s }), `source=${String(s)}`);
  for (const r of ['other', 'unknown']) await expectOk(base('SessionEnd', { reason: r }));
  for (const r of ['logout', 'Other', 'other\n', '', null, 1]) await expectNg(base('SessionEnd', { reason: r }), `reason=${String(r)}`);
  for (const t of ['manual', 'auto']) await expectOk(base('PreCompact', { trigger: t }));
  for (const t of ['Manual', 'unknown', '', 'auto\n', null]) await expectNg(base('PreCompact', { trigger: t }), `trigger=${String(t)}`);
});

// ---------- bash_command ----------

test('bash_command: `?` と [A-Za-z0-9._-]{1,32} のみ。32 バイトちょうどは受理、33 は拒否', async () => {
  for (const c of ['?', 'ls', 'git', 'node.exe', 'a.b_c-d', 'a'.repeat(32)]) await expectOk(pre({ tool_name: 'Bash', bash_command: c }), c);
  await expectNg(pre({ tool_name: 'Bash', bash_command: 'a'.repeat(33) }), '33');
});

test('bash_command: 空・スラッシュ・空白・シェル記号・複数行・`??`・非文字列は拒否', async () => {
  for (const c of ['', '/bin/ls', 'a/b', 'ls -la', 'a b', '$HOME', 'FOO=bar', '"x"', '~', 'ls\n', '\nls', '??', '?\n', '日本語', 'ls;rm']) {
    await expectNg(pre({ tool_name: 'Bash', bash_command: c }), JSON.stringify(c));
  }
  for (const c of [1, true, null, ['ls']]) await expectNg(pre({ tool_name: 'Bash', bash_command: c }), String(c));
});

// ---------- file_path ----------

test('file_path: ちょうど 128 バイトは受理、129 バイトは拒否（バイト長で数える）', async () => {
  await expectOk(pre({ file_path: 'a'.repeat(128) }));
  await expectNg(pre({ file_path: 'a'.repeat(129) }));
  await expectOk(pre({ file_path: 'あ'.repeat(42) }), '42 文字 = 126 バイト');
  await expectNg(pre({ file_path: 'あ'.repeat(43) }), '43 文字 = 129 バイト（文字数なら通ってしまう）');
});

test('file_path: 空・ディレクトリ区切り・制御文字・双方向制御文字・非文字列は拒否', async () => {
  for (const p of ['', 'dir/hello.txt', '/etc/passwd', 'a\nb', 'a\tb', 'a\0b', 'a\x7fb', 'a\u0085b', 'a‮b', 'a⁦b']) {
    await expectNg(pre({ file_path: p }), JSON.stringify(p));
  }
  for (const p of [1, true, ['a'], { a: 1 }]) await expectNg(pre({ file_path: p }), String(p));
});

test('file_path: SQL 断片・日本語・記号を含むベース名は原文のまま受理する', async () => {
  const sqlish = "'); DROP TABLE events;--";
  const r = await expectOk(pre({ file_path: sqlish }));
  assert.equal(r.event.file_path, sqlish);
  await expectOk(pre({ file_path: '設計 メモ(1).md' }));
});

// ---------- duration_ms ----------

test('duration_ms: 0 と 3600000 は受理、-1 と 3600001 は拒否', async () => {
  await expectOk(post({ duration_ms: 0 }));
  await expectOk(post({ duration_ms: 3_600_000 }));
  await expectNg(post({ duration_ms: -1 }));
  await expectNg(post({ duration_ms: 3_600_001 }));
});

test('duration_ms: 小数・文字列・真偽値・配列・null は拒否。JSON の 1.0 表記は値が整数なので受理', async () => {
  for (const d of [1.5, 0.1, '1', true, [1], null, {}]) await expectNg(post({ duration_ms: d }), String(d));
  const parsed = JSON.parse(`{"schema_version":1,"event":"PostToolUse","session_id":"${SID}","tool_name":"Read","tool_use_id":"t1","duration_ms":1.0}`);
  await expectOk(parsed, 'duration_ms: 1.0');
  await expectOk(JSON.parse(`{"schema_version":1,"event":"PostToolUse","session_id":"${SID}","tool_name":"Read","tool_use_id":"t1","duration_ms":1e3}`), '1e3 は 1000');
});

// ---------- stop_hook_active / usage ----------

test('stop_hook_active は真偽値のみ', async () => {
  await expectOk(base('Stop', { stop_hook_active: true }));
  await expectOk(base('Stop', { stop_hook_active: false }));
  for (const v of ['true', 0, 1, null, []]) await expectNg(base('Stop', { stop_hook_active: v }), String(v));
});

test('usage: 既知の 5 キーのみ・非負整数・上限 10,000,000', async () => {
  const keys = ['input_tokens', 'output_tokens', 'cache_creation_input_tokens', 'cache_read_input_tokens', 'thinking_tokens'];
  for (const k of keys) {
    await expectOk(base('Stop', { usage: { [k]: 0 } }), `${k}=0`);
    await expectOk(base('Stop', { usage: { [k]: 10_000_000 } }), `${k}=1e7`);
    await expectNg(base('Stop', { usage: { [k]: 10_000_001 } }), `${k}=1e7+1`);
    await expectNg(base('Stop', { usage: { [k]: -1 } }), `${k}=-1`);
    await expectNg(base('Stop', { usage: { [k]: 1.5 } }), `${k}=1.5`);
    await expectNg(base('Stop', { usage: { [k]: '1' } }), `${k}="1"`);
  }
  await expectNg(base('Stop', { usage: { input_tokens: 1, evil: 1 } }), '未知キー');
  for (const u of [null, [], 'x', 1]) await expectNg(base('Stop', { usage: u }), JSON.stringify(u));
});

// ---------- 拒否理由に入力値を載せない（lessons #11: 行き先の1つ） ----------

test('reason は固定文言で、入力値（秘密かもしれない）を含まない', async () => {
  const marker = 'SECRETMARKER_q7x2';
  const attempts = [
    { ...base('Stop'), session_id: `bad ${marker}` },
    { ...base('Stop'), [marker]: marker },
    { ...base('Stop'), event: marker },
    pre({ file_path: `${marker}/x` }),
    pre({ tool_name: 'Bash', bash_command: `ls ${marker}` }),
  ];
  for (const a of attempts) {
    const r = await validate(a);
    assert.equal(r.ok, false);
    assert.ok(!r.reason.includes(marker), `reason に入力値が混入: ${r.reason}`);
  }
});

test('どんな入力でも例外を投げない', async () => {
  const weird = [Symbol.iterator && {}, Object.create(null), new Date(), () => 1, 10n, { schema_version: 1n }, Object.assign(Object.create({ event: 'Stop' }), {})];
  for (const w of weird) {
    const r = await validate(w);
    assert.equal(r.ok, false);
  }
});
