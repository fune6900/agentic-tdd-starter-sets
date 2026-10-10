// 受信側（POST /api/events）の検証スキーマ。データのみ。検証ロジックは validate.mjs（Coder）が持つ。
//
// 唯一の正: .claude/monitor/docs/event-schema.md（schema_version はイベント別。UsageSnapshot は 2、他は 1）。ここに無いキー・値は拒否する（fail closed）。
//
// 正規表現の規約:
//   - 全て `^...$` で全体一致。`m` フラグは付けない。`m` 無しの JS の `$` は文字列の最後にしか一致しない
//     （PCRE / Python と違い、末尾の改行の手前には一致しない）ので "abc\n" は拒否される。
//   - 利用側は `new RegExp(pattern)` を使い、フラグを足さない（`m` 禁止）。`u` は file_path のみ付ける。
//   - 長さは maxBytes（UTF-8 のバイト長。文字数ではない）で別途判定する。パターン側に長さは入れない。
//   - 判定順の推奨: 型 → バイト長 → パターン。

import { CONTROL_CHARS_CLASS_BODY } from './control-chars.mjs';

/**
 * @typedef {{ kind: 'string', maxBytes: number, pattern: string, flags?: 'u' }} StringSpec
 * @typedef {{ kind: 'enum', values: readonly string[] }} EnumSpec
 * @typedef {{ kind: 'integer', min: number, max: number }} IntegerSpec
 * @typedef {{ kind: 'boolean' }} BooleanSpec
 * @typedef {{ kind: 'object', keys: Readonly<Record<string, FieldSpec>> }} ObjectSpec 全キー必須・未知キー不可
 * @typedef {{ kind: 'array', maxItems: number, item: ObjectSpec, uniqueKey: string }} ArraySpec uniqueKey は要素間で重複不可のキー
 * @typedef {StringSpec | EnumSpec | IntegerSpec | BooleanSpec | ObjectSpec | ArraySpec} FieldSpec
 *
 * @typedef {'SessionStart'|'SessionEnd'|'UserPromptSubmit'|'PreToolUse'|'PostToolUse'|'SubagentStart'|'SubagentStop'|'Stop'|'Notification'|'PreCompact'|'UsageSnapshot'} EventName
 * @typedef {{ required: readonly string[], optional: readonly string[] }} EventSpec
 * @typedef {{ key: string, whenKey: string, equals: string, presence?: 'required' | 'forbidden' }} Condition
 */

/** イベント別の schema_version。イベントごとに一致する値だけを受理する。 */
const DEFAULT_SCHEMA_VERSION = 1;
export const SCHEMA_VERSIONS = Object.freeze({ UsageSnapshot: 2 });
/** @param {string} event */
export const schemaVersionFor = (event) => (Object.hasOwn(SCHEMA_VERSIONS, event) ? SCHEMA_VERSIONS[event] : DEFAULT_SCHEMA_VERSION);

/** 全イベント共通で必須のキー（event ごとの required に加えて必要）。 */
export const COMMON_REQUIRED = Object.freeze(['schema_version', 'event', 'session_id']);

/** event 列挙（完全一致）。最大 32 バイト。 */
export const EVENT_NAMES = Object.freeze([
  'SessionStart', 'SessionEnd', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse',
  'SubagentStart', 'SubagentStop', 'Stop', 'Notification', 'PreCompact', 'UsageSnapshot',
]);
export const EVENT_MAX_BYTES = 32;

/** 上限値。 */
export const MAX_DURATION_MS = 3_600_000;
export const MAX_USAGE_TOKENS = 1_000_000_000_000; // 10^12（2^53 未満。8 モデル合算しても厳密）
export const MAX_MESSAGE_COUNT = 1_000_000;
export const MAX_MODELS = 8;

/** @param {number} max @returns {IntegerSpec} */
const intSpec = (max) => Object.freeze({ kind: 'integer', min: 0, max });
const BOOL = Object.freeze({ kind: 'boolean' });

/** UsageSnapshot.models の要素。全キー必須。 */
const MODEL_ENTRY = Object.freeze({
  kind: 'object',
  keys: Object.freeze({
    model: Object.freeze({ kind: 'string', maxBytes: 64, pattern: '^[A-Za-z0-9._-]+$' }),
    message_count: intSpec(MAX_MESSAGE_COUNT),
    input_tokens: intSpec(MAX_USAGE_TOKENS),
    output_tokens: intSpec(MAX_USAGE_TOKENS),
    cache_creation_5m_input_tokens: intSpec(MAX_USAGE_TOKENS),
    cache_creation_1h_input_tokens: intSpec(MAX_USAGE_TOKENS),
    cache_read_input_tokens: intSpec(MAX_USAGE_TOKENS),
    fast_mode: BOOL,
    us_inference: BOOL,
    variant_unknown: BOOL,
    cache_split_unknown: BOOL,
  }),
});

export const UNKNOWN_REASONS = Object.freeze([
  'no_path', 'symlink', 'not_regular_file', 'too_large', 'read_failed',
  'parse_failed', 'invalid_usage', 'too_many_models', 'out_of_range',
]);

/** @param {number} maxBytes @param {string} pattern @returns {StringSpec} */
const ident = (maxBytes, pattern) => Object.freeze({ kind: 'string', maxBytes, pattern });

/**
 * キーごとの型・制約（schema_version / event を除く）。
 * 識別子系は許可文字の全体一致 + 最大バイト長。1つでも外れたら拒否（切り詰めない・値を直さない）。
 * @type {Readonly<Record<string, FieldSpec>>}
 */
export const FIELDS = Object.freeze({
  session_id: ident(64, '^[A-Za-z0-9-]+$'),
  agent_id: ident(64, '^[A-Za-z0-9]+$'),
  agent_type: ident(64, '^[A-Za-z0-9_-]+$'),
  tool_name: ident(64, '^[A-Za-z0-9_-]+$'),
  tool_use_id: ident(64, '^[A-Za-z0-9_]+$'),
  subagent_type: ident(64, '^[A-Za-z0-9_-]+$'),
  // `?`（固定の置換値）または先頭トークンのベース名 1〜32 バイト。`/` は出力に現れないので許可しない。
  bash_command: ident(32, '^(?:\\?|[A-Za-z0-9._-]+)$'),
  // ベース名のみ。送信側で除去済みのはずの文字（`/`・C0・DEL・C1・双方向制御）が残っていたら拒否する。
  // 除外: 制御文字・双方向制御文字（control-chars.mjs）, `/`。空は不可。最大 128 バイト。
  file_path: Object.freeze({
    kind: 'string', maxBytes: 128, flags: 'u',
    pattern: `^[^${CONTROL_CHARS_CLASS_BODY}/]+$`,
  }),
  source: Object.freeze({ kind: 'enum', values: Object.freeze(['startup', 'resume', 'clear', 'compact', 'fork']) }),
  // 送信側は other / unknown の2種しか送らない。
  reason: Object.freeze({ kind: 'enum', values: Object.freeze(['other', 'unknown']) }),
  trigger: Object.freeze({ kind: 'enum', values: Object.freeze(['manual', 'auto']) }),
  duration_ms: Object.freeze({ kind: 'integer', min: 0, max: MAX_DURATION_MS }),
  stop_hook_active: Object.freeze({ kind: 'boolean' }),
  usage_status: Object.freeze({ kind: 'enum', values: Object.freeze(['ok', 'unknown']) }),
  unknown_reason: Object.freeze({ kind: 'enum', values: UNKNOWN_REASONS }),
  models: Object.freeze({ kind: 'array', maxItems: MAX_MODELS, item: MODEL_ENTRY, uniqueKey: 'model' }),
});

/**
 * イベント別の必須・任意キー（COMMON_REQUIRED を除く）。ここに無いキーはそのイベントでは拒否。
 * @type {Readonly<Record<EventName, EventSpec>>}
 */
export const EVENTS = Object.freeze({
  SessionStart: { required: [], optional: ['source'] },
  SessionEnd: { required: [], optional: ['reason'] },
  UserPromptSubmit: { required: [], optional: [] },
  PreToolUse: {
    required: ['tool_name', 'tool_use_id'],
    optional: ['agent_id', 'agent_type', 'subagent_type', 'bash_command', 'file_path'],
  },
  PostToolUse: {
    required: ['tool_name', 'tool_use_id'],
    optional: ['agent_id', 'agent_type', 'bash_command', 'file_path', 'duration_ms'],
  },
  SubagentStart: { required: ['agent_id', 'agent_type'], optional: [] },
  SubagentStop: { required: ['agent_id', 'agent_type'], optional: ['stop_hook_active'] },
  Stop: { required: [], optional: ['stop_hook_active'] },
  Notification: { required: [], optional: [] },
  PreCompact: { required: [], optional: ['trigger'] },
  UsageSnapshot: { required: ['usage_status'], optional: ['agent_id', 'unknown_reason', 'models'] },
});

/**
 * 条件付きキー。`presence` 省略 = `key` が存在するなら `whenKey` の値が `equals` と完全一致していなければならない。
 * `presence: 'required'` = `whenKey` が `equals` なら `key` が必須。`'forbidden'` = `whenKey` が `equals` なら `key` は不可。
 * @type {readonly Condition[]}
 */
export const CONDITIONS = Object.freeze([
  Object.freeze({ key: 'bash_command', whenKey: 'tool_name', equals: 'Bash' }),
  Object.freeze({ key: 'subagent_type', whenKey: 'tool_name', equals: 'Agent' }),
  Object.freeze({ key: 'models', whenKey: 'usage_status', equals: 'ok', presence: 'required' }),
  Object.freeze({ key: 'unknown_reason', whenKey: 'usage_status', equals: 'ok', presence: 'forbidden' }),
  Object.freeze({ key: 'unknown_reason', whenKey: 'usage_status', equals: 'unknown', presence: 'required' }),
  Object.freeze({ key: 'models', whenKey: 'usage_status', equals: 'unknown', presence: 'forbidden' }),
]);

/** 受理しうる全キー（未知キー判定の基準。event ごとの許可は EVENTS）。 */
export const ALL_KEYS = Object.freeze(['schema_version', 'event', ...Object.keys(FIELDS)]);
