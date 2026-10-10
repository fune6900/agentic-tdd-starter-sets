// モデル別の推定コスト（純関数）。単価は pricing.mjs から引く。単位はマイクロドル（tokens × USD/MTok）。
// 項ごとに Math.round してから足す。不明は micro_usd を持たない（0 円にしない）。

import { PRICING, UNPRICEABLE } from './pricing.mjs';

// 上から順に最初に該当した理由を返す（モデル判定の後）
const FLAG_REASONS = Object.freeze(['fast_mode', 'us_inference', 'variant_unknown', 'cache_split_unknown']);

const TERMS = Object.freeze([
  ['input_tokens', 'input'],
  ['output_tokens', 'output'],
  ['cache_creation_5m_input_tokens', 'cache_write_5m'],
  ['cache_creation_1h_input_tokens', 'cache_write_1h'],
  ['cache_read_input_tokens', 'cache_read'],
]);

const unknown = (reason) => ({ status: 'unknown', reason });

/** @param {unknown} entry models 要素 @returns {{status: 'known', micro_usd: number} | {status: 'unknown', reason: string}} */
export function estimateModelCost(entry) {
  try {
    return computeCost(entry);
  } catch {
    return unknown('model_not_in_table'); // 読み取りが投げる入力（getter 等）。例外にせず不明にする
  }
}

function computeCost(entry) {
  const model = entry?.model;
  if (typeof model === 'string' && Object.hasOwn(UNPRICEABLE, model)) return unknown(UNPRICEABLE[model]);
  if (typeof model !== 'string' || !Object.hasOwn(PRICING, model)) return unknown('model_not_in_table');
  for (const flag of FLAG_REASONS) {
    if (entry[flag] === true) return unknown(flag);
  }
  const price = PRICING[model];
  const micro = TERMS.reduce((sum, [field, key]) => sum + Math.round(entry[field] * price[key]), 0);
  return { status: 'known', micro_usd: micro };
}
