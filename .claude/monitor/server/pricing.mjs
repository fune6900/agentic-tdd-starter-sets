// 単価表（純粋なデータ）。検証・計算は cost.mjs。
// 数値の正: .claude/memory/epics/ai-monitor.md「マスターの決定（2026-10-10・#23 の単価表）」。
// 値の変更・モデルの追加はマスターの決定が要る。更新したら PRICING_FETCHED_AT も更新する。

export const PRICING_SOURCE_URL = 'https://platform.claude.com/docs/en/about-claude/pricing';
export const PRICING_FETCHED_AT = '2026-10-10';
export const PRICING_UNIT = 'USD per MTok';

// キー = transcript の message.model と完全一致するモデル ID（前方一致・日付の正規化はしない）
export const PRICING = Object.freeze({
  'claude-fable-5-1': Object.freeze({ input: 10, cache_write_5m: 12.5, cache_write_1h: 20, cache_read: 0.25, output: 50 }),
  'claude-opus-5-5': Object.freeze({ input: 4, cache_write_5m: 5, cache_write_1h: 8, cache_read: 0.2, output: 20 }),
  'claude-sonnet-5-5': Object.freeze({ input: 2, cache_write_5m: 2.5, cache_write_1h: 4, cache_read: 0.1, output: 10 }),
  'claude-haiku-4-5-20251001': Object.freeze({ input: 1, cache_write_5m: 1.25, cache_write_1h: 2, cache_read: 0.1, output: 5 }),
});

// 表に載せないと決めたモデル（理由を区別して「不明」にする）
export const UNPRICEABLE = Object.freeze({ 'claude-haiku-5-5': 'tiered_pricing' });
