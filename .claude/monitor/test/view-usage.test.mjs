// ビューのトークン数・推定コスト表示（Issue #23）。DOM に触れない純関数だけを固定する。
//
// 表示の文言（「推定 $X」「推定 $X 以上（不明を含む）」「不明」「$0」）の仕様は docs/event-schema.md。
// 関数名・戻り値の形は下の契約が正（public/app.js の export と一致させる）。
//
// ════════════════════════════════════════════════════════════════════════════
//  契約（public/app.js が export する。document / fetch / EventSource をトップレベルで参照しない）
// ════════════════════════════════════════════════════════════════════════════
//  formatUsageTotal(usageTotal) -> { state, costText, tokensText, className }
//    入力: セッションの usage_total（{ estimate, tokens:{input,output,cache_creation,cache_read}, unknown_snapshots,
//          cost:{ known_micro_usd, known_count, unknown_count } }）
//    state / costText / className:
//      unknown_count == 0                     -> 'known'        '推定 $X'                       'usage-known'      （両方 0 なら '推定 $0'）
//      known_count > 0 かつ unknown_count > 0 -> 'lower_bound'  '推定 $X 以上（不明を含む）'      'usage-lower-bound'
//      known_count == 0 かつ unknown_count > 0 -> 'unknown'      '不明'（$ も 0 も出さない）       'usage-unknown'
//    $X = known_micro_usd / 1e6 を小数 4 桁で。整数部は 3 桁区切り（例 12345 -> '$0.0123'、123456789012 -> '$123,456.7890'）。0 は '$0'
//    tokensText: '入力 N / 出力 N / キャッシュ書込 N / キャッシュ読取 N'（N は 3 桁区切り）。unknown_snapshots > 0 の時だけ '不明' を含む注記が付く
//    不正な入力（null・配列・型違い・負数・小数・NaN・Infinity・MAX_SAFE_INTEGER 超）は例外を投げず state 'unknown' / costText '不明' / tokensText ''
//  formatUsage(usage) -> { state, costText, tokensText, className }   ノード（メイン・サブ）の usage
//    null / undefined          -> state 'none'、costText ''、tokensText ''、className 'usage-none'
//    { status:'unknown', reason } -> state 'unknown'、costText '不明'、tokensText ''。reason の原文は出力に載せない
//    { status:'ok', models }   -> models の known だけを足して formatUsageTotal と同じ 3 通り。models: [] は '推定 $0'。tokens は全 models の合計
//    それ以外（不正）            -> state 'unknown'。例外を投げない（getter が投げる Proxy でも）
//  className は固定の許可リストからだけ選ぶ（入力から組み立てない）。「推定」は known / lower_bound の costText に必ず付く
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（public/ の隔離コピーに左の変異を入れ、このファイルを node --test で走らせると右が FAIL するべき）
// ════════════════════════════════════════════════════════════════════════════
//   不明を '$0' / '推定 $0' で出す（known_count == 0 && unknown_count > 0）   [state] 不明と 0 円
//   known>0 && unknown>0 を '推定 $X'（以上なし）にする                       [state] 下限
//   '推定' を外す / lower_bound だけ外す                                      [label]
//   unknown_count == 0 && known_count == 0 を '不明' にする                   [state] 使用量ゼロは $0
//   マイクロドル → ドルの除数を間違える / 小数桁を変える / 区切りを外す          [format]
//   トークン数の桁区切りを外す / 5m と 1h を足し忘れる                         [tokens]
//   unknown_snapshots の注記を出さない / 常に出す                              [tokens]
//   formatUsage が models の unknown cost を 0 円として足す                    [node] 不明を含む
//   formatUsage が reason の原文を載せる                                      [node] 原文を出さない
//   不正な入力で例外 / '$NaN' / '推定 $undefined' を出す                       [invalid]
//   className を入力から組み立てる                                            [class] 許可リスト
//   app.js が両関数を描画に使わない                                           [source]
//   innerHTML 等を使う                                                        view-source.test.mjs の [sink]（新しいコードにもそのまま効く。追加の検査は不要）

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { MONITOR_DIR } from './helpers.mjs';

const app = () => import('../public/app.js');
const total = async (t) => (await app()).formatUsageTotal(t);
const node = async (u) => (await app()).formatUsage(u);

const CLASSES = ['usage-known', 'usage-lower-bound', 'usage-unknown', 'usage-none'];
const tokens = (over = {}) => ({ input: 1234567, output: 89, cache_creation: 1000, cache_read: 999, ...over });
/** 全項目が正しい usage_total。1 点だけ変えて使う（lessons #22） */
const UT = (cost = {}, over = {}) => ({
  estimate: true, tokens: tokens(), unknown_snapshots: 0,
  cost: { known_micro_usd: 12345, known_count: 1, unknown_count: 0, ...cost }, ...over,
});
const model = (cost, over = {}) => ({
  model: 'claude-sonnet-5-5', message_count: 1, input_tokens: 1000, output_tokens: 20,
  cache_creation_5m_input_tokens: 300, cache_creation_1h_input_tokens: 400, cache_read_input_tokens: 5000,
  cost, ...over,
});
const known = (micro_usd) => ({ status: 'known', micro_usd });
const unknownCost = { status: 'unknown', reason: 'fast_mode' };

// ---------- [state] ----------

test('[state] 不明なし -> 「推定 $X」', async () => {
  const r = await total(UT());
  assert.equal(r.state, 'known');
  assert.equal(r.costText, '推定 $0.0123');
  assert.equal(r.className, 'usage-known');
});

test('[state] わかる分と不明が混在 -> 「推定 $X 以上（不明を含む）」（合計ではなく下限と読める）', async () => {
  const r = await total(UT({ known_count: 2, unknown_count: 1 }));
  assert.equal(r.state, 'lower_bound');
  assert.equal(r.costText, '推定 $0.0123 以上（不明を含む）');
  assert.equal(r.className, 'usage-lower-bound');
});

test('[state] 全部が不明 -> 「不明」。$0 も 0 も出さない（0 円と不明を混同しない）', async () => {
  const r = await total(UT({ known_micro_usd: 0, known_count: 0, unknown_count: 2 }));
  assert.equal(r.state, 'unknown');
  assert.equal(r.costText, '不明');
  assert.doesNotMatch(r.costText, /\$|0/);
  assert.equal(r.className, 'usage-unknown');
});

test('[state] 使用量ゼロ（known_count == 0 かつ unknown_count == 0）は「推定 $0」で、不明ではない', async () => {
  const r = await total(UT({ known_micro_usd: 0, known_count: 0, unknown_count: 0 }, { tokens: tokens({ input: 0, output: 0, cache_creation: 0, cache_read: 0 }) }));
  assert.equal(r.state, 'known');
  assert.equal(r.costText, '推定 $0');
  assert.notEqual(r.costText, '不明');
});

test('[state] 0 円と不明は別の文言（known 0 円 / 不明 / 下限）', async () => {
  const zero = await total(UT({ known_micro_usd: 0, known_count: 1, unknown_count: 0 }));
  const unk = await total(UT({ known_micro_usd: 0, known_count: 0, unknown_count: 1 }));
  const lower = await total(UT({ known_micro_usd: 0, known_count: 1, unknown_count: 1 }));
  assert.equal(zero.costText, '推定 $0');
  assert.equal(unk.costText, '不明');
  assert.equal(lower.costText, '推定 $0 以上（不明を含む）');
  assert.equal(new Set([zero.costText, unk.costText, lower.costText]).size, 3);
});

// ---------- [label] / [format] ----------

test('[label] 金額が出る表示には必ず「推定」が付く（known / 下限 / 0 円 / 巨額）', async () => {
  for (const cost of [{}, { known_count: 2, unknown_count: 1 }, { known_micro_usd: 0 }, { known_micro_usd: 999_999_999_999 }]) {
    const r = await total(UT(cost));
    assert.match(r.costText, /^推定 \$/, JSON.stringify(cost));
  }
});

test('[format] マイクロドル -> ドル（小数 4 桁・整数部は 3 桁区切り）', async () => {
  const cases = [[12345, '$0.0123'], [1_500_000, '$1.5000'], [20_000_000, '$20.0000'], [123_456_789_012, '$123,456.7890'], [1_000_000_000, '$1,000.0000']];
  for (const [micro, text] of cases) assert.equal((await total(UT({ known_micro_usd: micro }))).costText, `推定 ${text}`, String(micro));
});

test('[format] 下限の金額も同じ書式', async () => {
  const r = await total(UT({ known_micro_usd: 1_500_000, known_count: 1, unknown_count: 3 }));
  assert.equal(r.costText, '推定 $1.5000 以上（不明を含む）');
});

// ---------- [tokens] ----------

test('[tokens] 4 種を 3 桁区切りで出す', async () => {
  const r = await total(UT());
  assert.equal(r.tokensText, '入力 1,234,567 / 出力 89 / キャッシュ書込 1,000 / キャッシュ読取 999');
});

test('[tokens] 桁区切りの境界（999 は無し・1000 は有り・10^12 まで）', async () => {
  const r = await total(UT({}, { tokens: tokens({ input: 999, output: 1000, cache_creation: 1_000_000, cache_read: 1_000_000_000_000 }) }));
  assert.equal(r.tokensText, '入力 999 / 出力 1,000 / キャッシュ書込 1,000,000 / キャッシュ読取 1,000,000,000,000');
});

test('[tokens] unknown_snapshots が 0 なら「不明」の注記は無く、1 以上なら付く（数値は残す）', async () => {
  assert.doesNotMatch((await total(UT())).tokensText, /不明/);
  for (const n of [1, 3]) {
    const r = await total(UT({}, { unknown_snapshots: n }));
    assert.match(r.tokensText, /不明/, `unknown_snapshots=${n}`);
    assert.match(r.tokensText, /1,234,567/);
  }
});

// ---------- [node] ----------

test('[node] usage が無い（null / undefined）なら何も出さない', async () => {
  for (const u of [null, undefined]) {
    assert.deepEqual(await node(u), { state: 'none', costText: '', tokensText: '', className: 'usage-none' });
  }
});

test('[node] status unknown は「不明」で、reason の原文を載せない（0 円にもしない）', async () => {
  for (const reason of ['too_large', '<img src=x onerror=alert(1)>', '__proto__', 'x'.repeat(500)]) {
    const r = await node({ status: 'unknown', reason });
    assert.equal(r.state, 'unknown');
    assert.equal(r.costText, '不明');
    assert.equal(r.tokensText, '');
    assert.equal(r.className, 'usage-unknown');
    assert.equal(JSON.stringify(r).includes(reason), false, 'reason の原文を出力に載せない');
  }
});

test('[node] ok: models の known を足し、tokens は 5m + 1h を合わせたキャッシュ書込を含めて合算する', async () => {
  const r = await node({ status: 'ok', models: [model(known(10_000)), model(known(2_345), { model: 'claude-opus-5-5' })] });
  assert.equal(r.state, 'known');
  assert.equal(r.costText, '推定 $0.0123');
  assert.equal(r.tokensText, '入力 2,000 / 出力 40 / キャッシュ書込 1,400 / キャッシュ読取 10,000');
});

test('[node] ok: 不明なモデルを 0 円として足さず、下限にする', async () => {
  const r = await node({ status: 'ok', models: [model(known(12_345)), model(unknownCost, { model: 'unknown' })] });
  assert.equal(r.state, 'lower_bound');
  assert.equal(r.costText, '推定 $0.0123 以上（不明を含む）');
  assert.equal(r.className, 'usage-lower-bound');
});

test('[node] ok: 全モデルが不明なら「不明」。models が空なら使用量ゼロの「推定 $0」', async () => {
  const allUnknown = await node({ status: 'ok', models: [model(unknownCost), model({ status: 'unknown', reason: 'tiered_pricing' }, { model: 'claude-haiku-5-5' })] });
  assert.equal(allUnknown.state, 'unknown');
  assert.equal(allUnknown.costText, '不明');
  const empty = await node({ status: 'ok', models: [] });
  assert.equal(empty.state, 'known');
  assert.equal(empty.costText, '推定 $0');
  assert.match(empty.tokensText, /^入力 0 \/ 出力 0 \/ キャッシュ書込 0 \/ キャッシュ読取 0/);
});

// ---------- [invalid] ----------

const hostile = () => new Proxy({}, { get() { throw new Error('boom'); }, has() { throw new Error('boom'); }, ownKeys() { throw new Error('boom'); } });

test('[invalid] formatUsageTotal: 不正な入力でも例外を出さず「不明」。$NaN / undefined を出さない', async () => {
  const bad = [
    null, undefined, [], 'x', 42, true, {}, hostile(), Object.create(null),
    UT({ known_micro_usd: -1 }), UT({ known_micro_usd: 1.5 }), UT({ known_micro_usd: '12345' }), UT({ known_micro_usd: NaN }),
    UT({ known_micro_usd: Infinity }), UT({ known_micro_usd: Number.MAX_SAFE_INTEGER + 2 }), UT({ known_micro_usd: null }),
    UT({ known_count: -1 }), UT({ known_count: '1' }), UT({ unknown_count: 0.5 }), UT({ unknown_count: NaN }), UT({ unknown_count: undefined }),
    UT({}, { cost: null }), UT({}, { cost: [] }), UT({}, { cost: 'x' }),
    JSON.parse('{"__proto__":{"cost":{"known_micro_usd":1,"known_count":1,"unknown_count":0}}}'),
  ];
  for (const t of bad) {
    const r = await total(t);
    assert.equal(r.state, 'unknown', `入力 #${bad.indexOf(t)}`);
    assert.equal(r.costText, '不明');
    assert.equal(r.tokensText, '');
    assert.ok(CLASSES.includes(r.className));
    assert.doesNotMatch(JSON.stringify(r), /NaN|undefined|Infinity|null/);
  }
});

test('[invalid] formatUsageTotal: tokens が壊れていても例外を出さず、文字列を返す', async () => {
  for (const tk of [null, undefined, [], 'x', {}, { input: -1 }, { input: 'a', output: NaN }, hostile()]) {
    const r = await total(UT({}, { tokens: tk }));
    assert.equal(typeof r.tokensText, 'string');
    assert.doesNotMatch(r.tokensText, /NaN|undefined|Infinity|null/);
    assert.ok(CLASSES.includes(r.className));
  }
});

test('[invalid] formatUsage: 不正な入力でも例外を出さず「不明」', async () => {
  const bad = [
    [], 'x', 42, true, {}, hostile(), { status: 'ok' }, { status: 'ok', models: null }, { status: 'ok', models: 'x' }, { status: 'ok', models: [null] },
    { status: 'ok', models: [model(known(-5))] }, { status: 'ok', models: [model(known(NaN))] }, { status: 'ok', models: [model({ status: 'known' })] },
    { status: 'ok', models: [model({ status: 'weird', micro_usd: 5 })] }, { status: 'ok', models: [hostile()] },
    { status: 'OK', models: [] }, { status: '__proto__' }, { status: 'constructor' }, { status: 'toString' }, { status: 'unknown_' },
  ];
  for (const u of bad) {
    const r = await node(u);
    assert.equal(r.state, 'unknown', `入力 #${bad.indexOf(u)}`);
    assert.equal(r.costText, '不明');
    assert.ok(CLASSES.includes(r.className));
    assert.doesNotMatch(JSON.stringify(r), /NaN|undefined|Infinity/);
  }
});

// ---------- [class] ----------

test('[class] className は固定の許可リストからだけ出る（敵対的な入力でも）', async () => {
  const outs = [
    await total(UT()), await total(UT({ known_count: 1, unknown_count: 1 })), await total(UT({ known_count: 0, unknown_count: 1 })),
    await total(null), await node(null), await node({ status: 'unknown', reason: '"><script>' }), await node({ status: '"><x' }),
    await node({ status: 'ok', models: [] }), await node({ status: 'ok', models: [model(unknownCost)] }),
  ];
  for (const r of outs) assert.ok(CLASSES.includes(r.className), r.className);
});

// ---------- [source] ----------

test('[source] app.js が formatUsage / formatUsageTotal を export し、描画でも呼ぶ（定義だけで終わらない）', async () => {
  const mod = await app();
  assert.equal(typeof mod.formatUsage, 'function');
  assert.equal(typeof mod.formatUsageTotal, 'function');
  const src = readFileSync(join(MONITOR_DIR, 'public', 'app.js'), 'utf8');
  assert.ok((src.match(/\bformatUsageTotal\s*\(/g) ?? []).length >= 2, 'formatUsageTotal の定義 + 呼び出し');
  assert.ok((src.match(/\bformatUsage\s*\(/g) ?? []).length >= 2, 'formatUsage の定義 + 呼び出し');
  assert.match(src, /textContent|createTextNode/, 'DOM への出力は textContent 系（シンクの検査は view-source.test.mjs）');
});
