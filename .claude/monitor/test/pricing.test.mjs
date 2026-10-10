// 単価表とモデル別コスト計算（Issue #23）。server/pricing.mjs（データ）と server/cost.mjs の estimateModelCost。
//
// 仕様の正: docs/event-schema.md「推定コストの算出規則」。単価の数値の正: epics/ai-monitor.md「マスターの決定（2026-10-10・#23 の単価表）」。
// 期待値の単価はエピックの文面から読み取って突き合わせる（このファイルに単価を二重に書かない）。手計算の期待値はエピックの表からの算術。
//
// 実装の契約:
//   pricing.mjs : PRICING_SOURCE_URL / PRICING_FETCHED_AT / PRICING_UNIT / PRICING / UNPRICEABLE を named export（仕様の疑似コードどおり）
//   cost.mjs    : estimateModelCost(entry) -> { status: 'known', micro_usd } | { status: 'unknown', reason }（キーはこの 2 つだけ）
//                 entry は models 要素の形。モデル ID は完全一致。理由は仕様の優先順で 1 つだけ。例外を投げない
//   cost.mjs には単価・モデル ID を書かない（pricing.mjs から引く）
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（左の変異を入れると右が FAIL するべき）
// ════════════════════════════════════════════════════════════════════════════
//   単価の数値を 1 つ変える / 項目（5m と 1h、input と read）を取り違える    [table] エピックとの突き合わせ・[calc] 項目別
//   出典 URL・取得日を消す / 形式を変える                                      [meta]
//   表にモデルを足す / claude-haiku-4-5 のような日付なしを足す                  [table] キー集合の完全一致
//   PRICING / UNPRICEABLE を freeze しない                                     [table] 凍結
//   不明モデルを 0 円・既定単価で計算する                                       [unknown] model_not_in_table
//   モデル ID を前方一致・日付の付け外し・trim・大文字小文字無視で引く            [exact]
//   PRICING[model] / model in PRICING で引く（__proto__ 等が表に当たる）       [proto]・[source] hasOwn
//   claude-haiku-5-5 を不明にしない / 理由が model_not_in_table になる          [unknown] tiered_pricing
//   優先順を入れ替える（fast と us、tiered と not_in_table 等）                  [priority]
//   fast_mode / us_inference / variant_unknown / cache_split_unknown を無視      [unknown] フラグごと
//   フラグが立っても known を返す                                              [unknown]
//   項ごとの丸めをやめて合計で丸める / 丸めない / floor・ceil                    [round]
//   null・配列・文字列を渡すと例外                                              [invalid]
//   1 項目だけ壊す入力が他の項目も壊れていて別の理由で通る                       [unknown] すべて baseline からの 1 点変更（lessons #22）
//   known の結果に reason が混ざる / unknown に micro_usd が混ざる               [shape]
//   cost.mjs に単価・モデル ID をハードコードする                                 [source]
//   入力 entry を書き換える                                                     [shape] 不変
//   known_micro_usd に不明を足す / 0 円扱い / unknown_count に数えない           derive 側（受信・導出の QA が担当。ここでは estimateModelCost が 0 を返さないことまで）[unknown]

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { MONITOR_DIR, SERVER_DIR } from './helpers.mjs';

const pricing = () => import('../server/pricing.mjs');
const cost = () => import('../server/cost.mjs');
const est = async (entry) => (await cost()).estimateModelCost(entry);

const EPIC_PATH = join(MONITOR_DIR, '..', 'memory', 'epics', 'ai-monitor.md');

/** エピックの決定から { model: {input, cache_write_5m, cache_write_1h, cache_read, output} } を読む */
function epicTable() {
  const text = readFileSync(EPIC_PATH, 'utf8');
  const at = text.indexOf('マスターの決定（2026-10-10・#23 の単価表');
  assert.ok(at >= 0, 'エピックに #23 の単価表の決定が無い');
  const section = text.slice(at, text.indexOf('\n## ', at + 5) === -1 ? undefined : text.indexOf('\n## ', at + 5));
  const out = {};
  const re = /`(claude-[A-Za-z0-9.-]+)`\s*([\d.]+) \/ ([\d.]+) \/ ([\d.]+) \/ ([\d.]+) \/ ([\d.]+)/g;
  for (const m of section.matchAll(re)) {
    const [, model, input, w5, w1, read, output] = m;
    out[model] = { input: Number(input), cache_write_5m: Number(w5), cache_write_1h: Number(w1), cache_read: Number(read), output: Number(output) };
  }
  return out;
}

const MODELS = ['claude-fable-5-1', 'claude-opus-5-5', 'claude-sonnet-5-5', 'claude-haiku-4-5-20251001'];
const PRICE_KEYS = ['cache_read', 'cache_write_1h', 'cache_write_5m', 'input', 'output'];

/** すべて正しい（known になる）基準の entry。1 点だけ変えて使う */
const base = (over = {}) => ({
  model: 'claude-sonnet-5-5', message_count: 1,
  input_tokens: 1000, output_tokens: 2000,
  cache_creation_5m_input_tokens: 3000, cache_creation_1h_input_tokens: 4000, cache_read_input_tokens: 5000,
  fast_mode: false, us_inference: false, variant_unknown: false, cache_split_unknown: false,
  ...over,
});
const zeros = { input_tokens: 0, output_tokens: 0, cache_creation_5m_input_tokens: 0, cache_creation_1h_input_tokens: 0, cache_read_input_tokens: 0 };

// ---------- [meta] / [table] ----------

test('[meta] 出典 URL・取得日・単位を持つ', async () => {
  const p = await pricing();
  assert.equal(p.PRICING_SOURCE_URL, 'https://platform.claude.com/docs/en/about-claude/pricing');
  assert.equal(p.PRICING_FETCHED_AT, '2026-10-10');
  assert.match(p.PRICING_FETCHED_AT, /^\d{4}-\d{2}-\d{2}$/);
  assert.equal(p.PRICING_UNIT, 'USD per MTok');
});

test('[table] エピックの決定から 4 モデルを読めている（突き合わせ自体の自己診断）', () => {
  const t = epicTable();
  assert.deepEqual(Object.keys(t).sort(), [...MODELS].sort());
  assert.deepEqual(t['claude-fable-5-1'], { input: 10, cache_write_5m: 12.5, cache_write_1h: 20, cache_read: 0.25, output: 50 });
});

test('[table] キー集合は 4 モデルの完全一致（日付なし・haiku-5-5・余分なモデルを含まない）', async () => {
  const { PRICING } = await pricing();
  assert.deepEqual(Object.keys(PRICING).sort(), [...MODELS].sort());
  for (const k of ['claude-haiku-4-5', 'claude-haiku-5-5', 'unknown']) assert.equal(Object.hasOwn(PRICING, k), false, k);
});

test('[table] 4 モデルの 5 種の単価がエピックの決定と完全に一致する', async () => {
  const { PRICING } = await pricing();
  const expected = epicTable();
  for (const m of MODELS) {
    assert.deepEqual(Object.keys(PRICING[m]).sort(), PRICE_KEYS, `${m} のキー`);
    assert.deepEqual({ ...PRICING[m] }, expected[m], m);
  }
});

test('[table] PRICING・各モデル・UNPRICEABLE は凍結されている', async () => {
  const { PRICING, UNPRICEABLE } = await pricing();
  assert.ok(Object.isFrozen(PRICING));
  for (const m of MODELS) assert.ok(Object.isFrozen(PRICING[m]), m);
  assert.ok(Object.isFrozen(UNPRICEABLE));
});

test('[table] UNPRICEABLE は claude-haiku-5-5 → tiered_pricing だけで、PRICING と重ならない', async () => {
  const { PRICING, UNPRICEABLE } = await pricing();
  assert.deepEqual({ ...UNPRICEABLE }, { 'claude-haiku-5-5': 'tiered_pricing' });
  for (const k of Object.keys(UNPRICEABLE)) assert.equal(Object.hasOwn(PRICING, k), false);
});

// ---------- [calc] ----------

test('[calc] 4 モデルで手計算と一致する（各 1000/2000/3000/4000/5000 トークン）', async () => {
  const want = { 'claude-fable-5-1': 228750, 'claude-opus-5-5': 92000, 'claude-sonnet-5-5': 46000, 'claude-haiku-4-5-20251001': 23250 };
  for (const m of MODELS) assert.deepEqual(await est(base({ model: m })), { status: 'known', micro_usd: want[m] }, m);
});

test('[calc] 5 項目は 1 つずつ別の単価で効く（取り違えを検出する）', async () => {
  const fields = {
    input_tokens: 'input', output_tokens: 'output', cache_creation_5m_input_tokens: 'cache_write_5m',
    cache_creation_1h_input_tokens: 'cache_write_1h', cache_read_input_tokens: 'cache_read',
  };
  const table = epicTable();
  for (const m of MODELS) {
    for (const [field, priceKey] of Object.entries(fields)) {
      const r = await est(base({ model: m, ...zeros, [field]: 1_000_000 }));
      assert.deepEqual(r, { status: 'known', micro_usd: Math.round(table[m][priceKey] * 1_000_000) }, `${m} ${field}`);
    }
  }
});

test('[calc] 使用量ゼロの既知モデルは 0 円が事実（known / 0）', async () => {
  assert.deepEqual(await est(base({ ...zeros })), { status: 'known', micro_usd: 0 });
  assert.deepEqual(await est(base({ ...zeros, message_count: 0 })), { status: 'known', micro_usd: 0 });
});

test('[calc] 上限 10^12 トークンでも整数のまま厳密（sonnet 全項目 10^12）', async () => {
  const big = 1_000_000_000_000;
  const r = await est(base({ input_tokens: big, output_tokens: big, cache_creation_5m_input_tokens: big, cache_creation_1h_input_tokens: big, cache_read_input_tokens: big }));
  assert.deepEqual(r, { status: 'known', micro_usd: 18_600_000_000_000 });
  assert.ok(Number.isSafeInteger(r.micro_usd));
});

// ---------- [round] ----------

test('[round] 項ごとに Math.round してから足す（fable: 5m 1tok=12.5→13 と read 2tok=0.5→1 で 14。合計丸めなら 13）', async () => {
  const r = await est(base({ model: 'claude-fable-5-1', ...zeros, cache_creation_5m_input_tokens: 1, cache_read_input_tokens: 2 }));
  assert.deepEqual(r, { status: 'known', micro_usd: 14 });
});

test('[round] 項ごとの切り捨て側も効く（haiku: 5m 1tok=1.25→1 と read 4tok=0.4→0 で 1。合計丸めなら 2）', async () => {
  const r = await est(base({ model: 'claude-haiku-4-5-20251001', ...zeros, cache_creation_5m_input_tokens: 1, cache_read_input_tokens: 4 }));
  assert.deepEqual(r, { status: 'known', micro_usd: 1 });
});

test('[round] 0.5 は切り上げ・0.25 / 0.4 は切り捨て（floor / ceil / 丸めなしを区別する）', async () => {
  const f = (over) => est(base({ model: 'claude-fable-5-1', ...zeros, ...over }));
  assert.equal((await f({ cache_creation_5m_input_tokens: 1 })).micro_usd, 13);
  assert.equal((await f({ cache_read_input_tokens: 1 })).micro_usd, 0);
  assert.equal((await f({ cache_read_input_tokens: 3 })).micro_usd, 1);
  const r = await est(base({ model: 'claude-haiku-4-5-20251001', ...zeros, cache_read_input_tokens: 4 }));
  assert.equal(r.micro_usd, 0);
  assert.ok(Number.isInteger(r.micro_usd));
});

// ---------- [unknown] ----------

const unk = (reason) => ({ status: 'unknown', reason });

test('[unknown] 基準の entry は known（以降の 1 点変更の土台の自己診断）', async () => {
  assert.equal((await est(base())).status, 'known');
});

test('[unknown] 表に無いモデルは model_not_in_table（0 円にしない）', async () => {
  for (const model of ['unknown', 'claude-3-opus', 'gpt-4', 'claude-opus-5-6']) {
    const r = await est(base({ model }));
    assert.deepEqual(r, unk('model_not_in_table'), model);
    assert.equal(Object.hasOwn(r, 'micro_usd'), false, '不明に金額を載せない');
  }
});

test('[unknown] claude-haiku-5-5 は tiered_pricing（model_not_in_table ではない）', async () => {
  assert.deepEqual(await est(base({ model: 'claude-haiku-5-5' })), unk('tiered_pricing'));
});

test('[unknown] フラグが 1 つ立つと、そのフラグ固有の理由で不明（他は基準のまま）', async () => {
  assert.deepEqual(await est(base({ fast_mode: true })), unk('fast_mode'));
  assert.deepEqual(await est(base({ us_inference: true })), unk('us_inference'));
  assert.deepEqual(await est(base({ variant_unknown: true })), unk('variant_unknown'));
  assert.deepEqual(await est(base({ cache_split_unknown: true })), unk('cache_split_unknown'));
});

test('[unknown] フラグが立てば全 4 モデルで不明（使用量ゼロでも 0 円にならない）', async () => {
  for (const m of MODELS) {
    assert.deepEqual(await est(base({ model: m, fast_mode: true })), unk('fast_mode'), m);
    assert.deepEqual(await est(base({ model: m, ...zeros, cache_split_unknown: true })), unk('cache_split_unknown'), m);
  }
});

// ---------- [priority] ----------

test('[priority] 複数に当てはまる時は仕様の優先順で 1 つだけ返す', async () => {
  const all = { fast_mode: true, us_inference: true, variant_unknown: true, cache_split_unknown: true };
  assert.deepEqual(await est(base({ model: 'claude-haiku-5-5', ...all })), unk('tiered_pricing'));
  assert.deepEqual(await est(base({ model: 'unknown', ...all })), unk('model_not_in_table'));
  assert.deepEqual(await est(base({ ...all })), unk('fast_mode'));
  assert.deepEqual(await est(base({ us_inference: true, variant_unknown: true, cache_split_unknown: true })), unk('us_inference'));
  assert.deepEqual(await est(base({ variant_unknown: true, cache_split_unknown: true })), unk('variant_unknown'));
  assert.deepEqual(await est(base({ cache_split_unknown: true })), unk('cache_split_unknown'));
});

// ---------- [exact] ----------

test('[exact] モデル ID は完全一致。前方一致・日付の付け外し・空白・大文字では引かない', async () => {
  const cases = [
    'claude-haiku-4-5', 'claude-haiku-4-5-20251002', 'claude-haiku-4-5-20251001-x', ' claude-haiku-4-5-20251001',
    'claude-haiku-4-5-20251001 ', 'claude-haiku-4-5-20251001\n', 'CLAUDE-HAIKU-4-5-20251001',
    'claude-sonnet-5-5-20260101', 'claude-sonnet-5', 'claude-opus-5-5\n', 'claude-fable-5-1-preview', 'claude-fable-5',
  ];
  for (const model of cases) assert.deepEqual(await est(base({ model })), unk('model_not_in_table'), JSON.stringify(model));
  for (const model of ['claude-haiku-5-5-20260101', 'claude-haiku-5-5 ', 'claude-haiku-5']) {
    assert.deepEqual(await est(base({ model })), unk('model_not_in_table'), `haiku-5-5 も完全一致: ${JSON.stringify(model)}`);
  }
});

// ---------- [proto] / [invalid] ----------

test('[proto] Object.prototype 上の名前は表にも UNPRICEABLE にも当たらず model_not_in_table', async () => {
  const names = ['__proto__', 'constructor', 'prototype', 'toString', 'valueOf', 'hasOwnProperty', 'isPrototypeOf', '__defineGetter__'];
  for (const model of names) assert.deepEqual(await est(base({ model })), unk('model_not_in_table'), model);
});

test('[invalid] 壊れた入力でも例外を出さず不明にする（金額を返さない）', async () => {
  const bad = [null, undefined, [], [base()], 'claude-opus-5-5', 42, true, {}, Object.create(null), () => 1];
  for (const entry of bad) {
    const r = await est(entry);
    assert.deepEqual(r, unk('model_not_in_table'), `入力 #${bad.indexOf(entry)}（${typeof entry}）`);
  }
});

test('[invalid] model が文字列でない（数値・null・配列・オブジェクト・欠落）なら不明（他は正しい入力）', async () => {
  for (const model of [123, null, undefined, ['claude-opus-5-5'], { toString: () => 'claude-opus-5-5' }, Symbol.for('x')]) {
    const r = await est(base({ model }));
    assert.deepEqual(r, unk('model_not_in_table'), String(typeof model));
  }
  const { model: _drop, ...noModel } = base();
  assert.deepEqual(await est(noModel), unk('model_not_in_table'));
});

// ---------- [shape] ----------

test('[shape] known は { status, micro_usd } だけ、unknown は { status, reason } だけ。入力は書き換えない', async () => {
  const e = base();
  const snapshot = JSON.stringify(e);
  const k = await est(e);
  assert.deepEqual(Object.keys(k).sort(), ['micro_usd', 'status']);
  const u = await est(base({ fast_mode: true }));
  assert.deepEqual(Object.keys(u).sort(), ['reason', 'status']);
  assert.equal(JSON.stringify(e), snapshot);
  assert.deepEqual(await est(e), k, '同じ入力は同じ結果');
});

// ---------- [source] ----------

test('[source] cost.mjs は pricing.mjs から引き、単価・モデル ID を持たず、hasOwn 系で引く', () => {
  const src = readFileSync(join(SERVER_DIR, 'cost.mjs'), 'utf8');
  assert.match(src, /from\s+['"]\.\/pricing\.mjs['"]/);
  assert.doesNotMatch(src, /claude-[a-z0-9]/i, 'モデル ID のハードコード');
  assert.match(src, /Object\.hasOwn|hasOwnProperty\.call/);
  assert.doesNotMatch(src, /\bconsole\.log\b/);
});
