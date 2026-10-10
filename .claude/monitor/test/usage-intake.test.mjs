// UsageSnapshot の受信検証（Issue #23）。仕様の唯一の正は docs/event-schema.md の「UsageSnapshot」の節。
//
// 変異テスト対応表（この変異を入れると、右のテストが落ちる）:
//   - schema_version をイベント別でなく単一値(1)に戻す           -> 'UsageSnapshot は schema_version 2 のみ' / fixture 受理
//   - schema_version を全イベント 2 にする                       -> '他の 10 イベントに schema_version 2 は拒否'
//   - EVENTS に UsageSnapshot を足さない                         -> 正しい形の受理テスト全部
//   - ok の時に models を必須にしない                            -> 'ok なのに models が無い'
//   - ok の時に unknown_reason を不可にしない                    -> 'ok なのに unknown_reason がある'
//   - unknown の時に models を不可にしない                       -> 'unknown なのに models がある'
//   - unknown の時に unknown_reason を必須にしない               -> 'unknown なのに unknown_reason が無い'
//   - unknown_reason の列挙を外す / 9 種目を通す                 -> '列挙外の unknown_reason'
//   - models の maxItems を 8 から広げる                         -> 'models は 0〜8 件'
//   - model の重複拒否を外す                                     -> 'model の重複'
//   - model の許可文字の全体一致を行単位判定にする               -> 'model の許可外文字・複数行'
//   - 数値の上限を 10^12 から変える / 整数判定を外す             -> '数値の境界' / '数値の型違い'
//   - message_count の上限(1,000,000)を外す                      -> 'message_count の境界'
//   - 真偽値キーが数値を通す                                     -> '真偽値のキーに数値'
//   - 要素のキー必須を外す / 要素に未知キーを通す                -> '要素のキーの欠落' / '要素の未知キー'
//   - Stop / SubagentStop の旧予約キー model / usage を残す      -> validate.test.mjs '旧予約キー'
//   - reason に入力値を載せる                                    -> '拒否理由は固定文言'
//
// 1 項目だけ壊すテストは、他を全部正しくした入力から作る（教訓 #22）。

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { cleanupTmp, fixture, getState, load, postEvent, SID, usageEntry as entry, withServer } from './helpers.mjs';

after(cleanupTmp);

const validate = async (obj) => (await load('validate.mjs')).validateEvent(obj);
const MAX_TOKENS = 1_000_000_000_000; // 10^12
const MAX_MESSAGES = 1_000_000;

const okSnap = (models = [entry()], extra = {}) => ({
  schema_version: 2, event: 'UsageSnapshot', session_id: SID, usage_status: 'ok', models, ...extra,
});
const unkSnap = (reason = 'too_large', extra = {}) => ({
  schema_version: 2, event: 'UsageSnapshot', session_id: SID, usage_status: 'unknown', unknown_reason: reason, ...extra,
});
const NUM_KEYS = ['input_tokens', 'output_tokens', 'cache_creation_5m_input_tokens', 'cache_creation_1h_input_tokens', 'cache_read_input_tokens'];
const BOOL_KEYS = ['fast_mode', 'us_inference', 'variant_unknown', 'cache_split_unknown'];
const ENTRY_KEYS = ['model', 'message_count', ...NUM_KEYS, ...BOOL_KEYS];
const REASONS = ['no_path', 'symlink', 'not_regular_file', 'too_large', 'read_failed', 'parse_failed', 'invalid_usage', 'too_many_models', 'out_of_range'];

async function ok(obj, label) {
  const r = await validate(obj);
  assert.equal(r.ok, true, `${label ?? JSON.stringify(obj)} は受理されるはず。reason=${r.reason}`);
  return r;
}
async function ng(obj, label) {
  const r = await validate(obj);
  assert.equal(r.ok, false, `${label ?? JSON.stringify(obj)} は拒否されるはず`);
  assert.ok(typeof r.reason === 'string' && r.reason.length > 0);
}

// ---------- 正しい形 ----------

test('正しい形（ok / unknown、main / sub）を受理し、event は入力と等しい', async () => {
  for (const name of ['UsageSnapshot.main-ok', 'UsageSnapshot.sub-ok', 'UsageSnapshot.unknown']) {
    const obj = fixture(name);
    const r = await ok(obj, name);
    assert.deepEqual(r.event, obj, name);
  }
  assert.equal(fixture('UsageSnapshot.sub-ok').agent_id !== undefined, true, 'sub fixture は agent_id を持つ');
  assert.equal('agent_id' in fixture('UsageSnapshot.main-ok'), false, 'main は agent_id を持たない');
});

test('ok で models が空配列でも受理する（assistant の usage 行が 0 件）', async () => {
  await ok(okSnap([]));
});

test('unknown_reason は仕様の全理由を受理する（unknown は models を持たない）', async () => {
  for (const r of REASONS) await ok(unkSnap(r), r);
});

test('agent_id は任意で付けられる（main は無し・sub は有り）', async () => {
  await ok(okSnap([entry()], { agent_id: 'aaaaaaaaaaaaaaaaa' }));
  await ok(unkSnap('symlink', { agent_id: 'aaaaaaaaaaaaaaaaa' }));
  await ng(okSnap([entry()], { agent_id: 'a-b' }), 'agent_id の許可外文字');
  await ng(okSnap([entry()], { agent_id: 'a'.repeat(65) }), 'agent_id 65 バイト');
});

// ---------- schema_version はイベント別 ----------

test('UsageSnapshot は schema_version 2 のみ（1 や他の値は拒否）', async () => {
  for (const sv of [1, 0, 3, '2', 2.5, null, true, [2]]) await ng({ ...okSnap(), schema_version: sv }, `sv=${String(sv)}`);
  const { schema_version: _d, ...noSv } = okSnap();
  await ng(noSv, 'schema_version 欠落');
  await ok(okSnap(), 'sv=2');
});

test('他の 10 イベントに schema_version 2 は拒否、1 は受理（イベント別の表）', async () => {
  const mk = (event, extra = {}) => ({ schema_version: 1, event, session_id: SID, ...extra });
  const evs = [
    mk('SessionStart'), mk('SessionEnd'), mk('UserPromptSubmit'), mk('Stop'), mk('Notification'), mk('PreCompact'),
    mk('PreToolUse', { tool_name: 'Read', tool_use_id: 't1' }), mk('PostToolUse', { tool_name: 'Read', tool_use_id: 't1' }),
    mk('SubagentStart', { agent_id: 'a1', agent_type: 'x' }), mk('SubagentStop', { agent_id: 'a1', agent_type: 'x' }),
  ];
  for (const e of evs) {
    await ok(e, `${e.event} sv=1`);
    await ng({ ...e, schema_version: 2 }, `${e.event} sv=2`);
  }
});

// ---------- 排他条件 ----------

test('必須キーの欠落（usage_status / event / session_id）は拒否', async () => {
  for (const k of ['usage_status', 'session_id', 'event']) {
    const o = okSnap();
    delete o[k];
    await ng(o, `${k} 欠落`);
  }
});

test('ok なのに models が無い、は拒否', async () => {
  const o = okSnap();
  delete o.models;
  await ng(o);
});

test('ok なのに unknown_reason がある、は拒否（models は正しいまま）', async () => {
  await ng(okSnap([entry()], { unknown_reason: 'too_large' }));
  await ng(okSnap([], { unknown_reason: 'too_large' }));
});

test('unknown なのに models がある、は拒否（unknown_reason は正しいまま）', async () => {
  await ng(unkSnap('too_large', { models: [entry()] }));
  await ng(unkSnap('too_large', { models: [] }));
});

test('unknown なのに unknown_reason が無い、は拒否', async () => {
  const o = unkSnap();
  delete o.unknown_reason;
  await ng(o);
});

test('usage_status が列挙外・型違いは拒否', async () => {
  for (const v of ['OK', 'Unknown', 'error', '', 'ok\n', null, 1, true, ['ok']]) await ng(okSnap([entry()], { usage_status: v }), String(v));
});

test('列挙外の unknown_reason は拒否（大文字小文字・改行・型違いを含む）', async () => {
  for (const v of ['Too_Large', 'other', '', 'too_large\n', ' too_large', null, 1, true, ['too_large'], 'x'.repeat(65)]) {
    await ng(unkSnap(v), JSON.stringify(v));
  }
});

test('未知キーは拒否（トップレベル）', async () => {
  for (const k of ['agent_type', 'model', 'usage', 'tool_name', 'extra', 'transcript_path', 'cost']) {
    await ng(okSnap([entry()], { [k]: 'x' }), `ok + ${k}`);
    await ng(unkSnap('too_large', { [k]: 'x' }), `unknown + ${k}`);
  }
});

// ---------- models の配列 ----------

test('models は 0〜8 件。9 件は拒否、配列以外は拒否', async () => {
  const many = (n) => Array.from({ length: n }, (_, i) => entry({ model: `m${i}` }));
  await ok(okSnap(many(8)), '8 件');
  await ng(okSnap(many(9)), '9 件');
  for (const v of [null, 'x', 1, {}, true]) await ng(okSnap(v), JSON.stringify(v));
  for (const v of [null, 'x', 1, [], [entry()]]) await ng(okSnap([v]), `要素=${JSON.stringify(v)}`);
});

test('model の重複は拒否（異なる model なら受理）', async () => {
  await ng(okSnap([entry({ model: 'dup' }), entry({ model: 'dup' })]));
  await ng(okSnap([entry({ model: 'unknown' }), entry({ model: 'unknown' })]));
  await ok(okSnap([entry({ model: 'a' }), entry({ model: 'b' })]));
});

// ---------- 要素のキー・model ----------

test('要素のキーの欠落は拒否（全 11 キー必須）', async () => {
  assert.equal(ENTRY_KEYS.length, 11);
  for (const k of ENTRY_KEYS) {
    const e = entry();
    delete e[k];
    await ng(okSnap([e]), `${k} 欠落`);
  }
});

test('要素の未知キーは拒否（thinking_tokens など送らないと決めたものを含む）', async () => {
  for (const k of ['thinking_tokens', 'message_id', 'service_tier', 'cost', 'cache_creation_input_tokens', 'extra']) {
    await ng(okSnap([entry({ [k]: 1 })]), k);
  }
});

test('model: 64 バイトまで受理、65 は拒否。許可文字は [A-Za-z0-9._-]', async () => {
  await ok(okSnap([entry({ model: 'a'.repeat(64) })]));
  await ng(okSnap([entry({ model: 'a'.repeat(65) })]));
  await ok(okSnap([entry({ model: 'claude-x_1.2' })]));
  await ok(okSnap([entry({ model: 'unknown' })]));
});

test('model の許可外文字・空・複数行・型違いは拒否', async () => {
  for (const v of ['', 'a b', 'a/b', 'a:b', '日本', 'abc\n', '\nabc', 'a\nb', 'abc\r', 'abc\0', '<synthetic>', 1, null, true, ['a'], { a: 1 }]) {
    await ng(okSnap([entry({ model: v })]), JSON.stringify(v));
  }
});

// ---------- 数値・真偽値 ----------

test('数値の境界: 0 と 10^12 は受理、10^12+1 と -1 は拒否', async () => {
  for (const k of NUM_KEYS) {
    await ok(okSnap([entry({ [k]: 0 })]), `${k}=0`);
    await ok(okSnap([entry({ [k]: MAX_TOKENS })]), `${k}=1e12`);
    await ng(okSnap([entry({ [k]: MAX_TOKENS + 1 })]), `${k}=1e12+1`);
    await ng(okSnap([entry({ [k]: -1 })]), `${k}=-1`);
  }
});

test('数値の型違い: 小数・文字列・真偽値・null・配列・オブジェクト・NaN 相当は拒否。JSON の 1.0 は値が整数なので受理', async () => {
  for (const k of [...NUM_KEYS, 'message_count']) {
    for (const v of [1.5, 0.1, '1', true, null, [1], {}, '']) await ng(okSnap([entry({ [k]: v })]), `${k}=${JSON.stringify(v)}`);
  }
  const text = JSON.stringify(okSnap([entry({ input_tokens: 8 })])).replace('"input_tokens":8', '"input_tokens":8.0');
  assert.match(text, /"input_tokens":8\.0/);
  await ok(JSON.parse(text), 'input_tokens: 8.0');
});

test('message_count の境界: 0 と 1,000,000 は受理、1,000,001 と -1 は拒否', async () => {
  await ok(okSnap([entry({ message_count: 0 })]));
  await ok(okSnap([entry({ message_count: MAX_MESSAGES })]));
  await ng(okSnap([entry({ message_count: MAX_MESSAGES + 1 })]));
  await ng(okSnap([entry({ message_count: -1 })]));
});

test('真偽値のキーに数値・文字列・null が入っていたら拒否（true / false は受理）', async () => {
  for (const k of BOOL_KEYS) {
    await ok(okSnap([entry({ [k]: true })]), `${k}=true`);
    await ok(okSnap([entry({ [k]: false })]), `${k}=false`);
    for (const v of [0, 1, 'true', 'false', null, [], {}]) await ng(okSnap([entry({ [k]: v })]), `${k}=${JSON.stringify(v)}`);
  }
});

// ---------- 固定文言・非破壊 ----------

test('拒否理由は固定文言で、入力値（モデル ID など）を載せない', async () => {
  const marker = 'SECRETMARKER_u9k4';
  const attempts = [
    okSnap([entry({ model: `bad ${marker}` })]),
    okSnap([entry({ [marker]: 1 })]),
    unkSnap(marker),
    okSnap([entry({ input_tokens: marker })]),
    { ...okSnap(), [marker]: marker },
  ];
  for (const a of attempts) {
    const r = await validate(a);
    assert.equal(r.ok, false);
    assert.ok(!r.reason.includes(marker), `reason に入力値が混入: ${r.reason}`);
  }
});

test('受理しても入力を書き換えない・どんな入力でも例外を投げない', async () => {
  const frozen = structuredClone(okSnap([entry()]));
  Object.freeze(frozen);
  Object.freeze(frozen.models);
  Object.freeze(frozen.models[0]);
  await ok(frozen);
  for (const w of [okSnap([Object.create(null)]), okSnap([entry({ input_tokens: 10n })]), okSnap([() => 1])]) {
    const r = await validate(w);
    assert.equal(r.ok, false);
  }
});

// ---------- 実サーバへの POST ----------

test('実サーバ: 正しい UsageSnapshot（ok / unknown / main / sub）は 201 で保存される', async () => {
  await withServer(async (s) => {
    for (const name of ['UsageSnapshot.main-ok', 'UsageSnapshot.sub-ok', 'UsageSnapshot.unknown']) {
      const r = await postEvent(s.port, fixture(name));
      assert.equal(r.status, 201, `${name}: ${r.status} ${r.body}`);
    }
    assert.equal(s.store.count(), 3);
  });
});

test('実サーバ: 拒否される UsageSnapshot は 400・固定の本文・行数不変（本文に入力値を載せない）', async () => {
  await withServer(async (s) => {
    const marker = 'SECRETMARKER_w3z8';
    const bad = {
      schema_version_1: { ...okSnap(), schema_version: 1 },
      ok_models無し: (() => { const o = okSnap(); delete o.models; return o; })(),
      ok_reason有り: okSnap([entry()], { unknown_reason: 'too_large' }),
      unknown_models有り: unkSnap('too_large', { models: [entry()] }),
      reason列挙外: unkSnap(marker),
      model重複: okSnap([entry({ model: 'dup' }), entry({ model: 'dup' })]),
      数値範囲外: okSnap([entry({ output_tokens: MAX_TOKENS + 1 })]),
      旧予約キー: { schema_version: 1, event: 'Stop', session_id: SID, model: marker },
    };
    let firstBody;
    for (const [name, obj] of Object.entries(bad)) {
      const r = await postEvent(s.port, obj);
      assert.equal(r.status, 400, `${name}: ${r.status} ${r.body}`);
      assert.ok(!r.body.includes(marker), `${name}: 本文に入力値が混入`);
      firstBody ??= r.body;
      assert.equal(r.body, firstBody, `${name}: 本文は固定文言のはず`);
    }
    assert.equal(s.store.count(), 0);
    assert.deepEqual((await getState(s.port)).json.sessions, []);
  });
});
