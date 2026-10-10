// 制御文字の文字クラス（依存ゼロ）。schema.mjs（拒否用）と loop-state.mjs（除去用）が共有する唯一の定義。
// C0 / DEL / C1 と、双方向制御文字（ALM, LRM RLM, LRE から RLO, LRI から PDI）。生の文字は書かず、エスケープで持つ。
export const CONTROL_CHARS_CLASS_BODY = String.raw`\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069`;

/** 除去用（g フラグ付き。replace 専用で test には使わない: lastIndex が残る） */
export const CONTROL_CHARS_PATTERN = new RegExp(`[${CONTROL_CHARS_CLASS_BODY}]`, 'gu');
