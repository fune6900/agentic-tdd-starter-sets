// 受信イベントの検証（純関数）。倒す向きは fail closed: 判定不能・仕様外は全て拒否する。
// 仕様は schema.mjs（データ）が持つ。ここは「それをどう当てるか」だけ。
// reason は固定文言。入力値（秘密かもしれない）は載せない。

import {
  COMMON_REQUIRED, CONDITIONS, EVENT_MAX_BYTES, EVENT_NAMES, EVENTS, FIELDS, SCHEMA_VERSION,
} from './schema.mjs';

const REASON = Object.freeze({
  shape: 'invalid event',
  version: 'unsupported schema_version',
  event: 'unknown event',
  keys: 'unexpected or missing keys',
  value: 'invalid field value',
  condition: 'invalid field combination',
});

class Reject extends Error {}
const reject = (reason) => { throw new Reject(reason); };

// 正規表現はスキーマの文字列をそのまま使う（フラグを足さない）。1回だけコンパイルする。
const REGEX_CACHE = new Map();
const regexFor = (spec) => {
  const key = `${spec.flags ?? ''}/${spec.pattern}`;
  let re = REGEX_CACHE.get(key);
  if (!re) {
    re = new RegExp(spec.pattern, spec.flags);
    REGEX_CACHE.set(key, re);
  }
  return re;
};

// JSON.parse / structuredClone 由来のプレーンオブジェクトだけを通す（配列・Date・null プロトタイプは拒否）
const isPlainObject = (v) => typeof v === 'object' && v !== null && Object.getPrototypeOf(v) === Object.prototype;

const isInteger = (v, spec) => typeof v === 'number' && Number.isInteger(v) && v >= spec.min && v <= spec.max;

/** 値を spec に当てて、検証済みの値（コピー）を返す。外れたら Reject。 */
function checkField(spec, value) {
  switch (spec.kind) {
    case 'string':
      if (typeof value !== 'string' || Buffer.byteLength(value, 'utf8') > spec.maxBytes || !regexFor(spec).test(value)) reject(REASON.value);
      return value;
    case 'enum':
      if (typeof value !== 'string' || !spec.values.includes(value)) reject(REASON.value);
      return value;
    case 'integer':
      if (!isInteger(value, spec)) reject(REASON.value);
      return value;
    case 'boolean':
      if (typeof value !== 'boolean') reject(REASON.value);
      return value;
    case 'object': {
      if (!isPlainObject(value)) reject(REASON.value);
      const keys = Object.keys(value);
      if (keys.length === 0 && !spec.allowEmpty) reject(REASON.value);
      const out = {};
      for (const k of keys) {
        if (!Object.hasOwn(spec.keys, k)) reject(REASON.value);
        out[k] = checkField(spec.keys[k], value[k]);
      }
      return out;
    }
    default:
      return reject(REASON.value); // 未知の kind は fail closed
  }
}

function check(obj) {
  if (!isPlainObject(obj)) reject(REASON.shape);
  if (obj.schema_version !== SCHEMA_VERSION) reject(REASON.version);
  const { event } = obj;
  if (typeof event !== 'string' || Buffer.byteLength(event, 'utf8') > EVENT_MAX_BYTES || !EVENT_NAMES.includes(event)) reject(REASON.event);

  const spec = EVENTS[event];
  const allowed = new Set([...COMMON_REQUIRED, ...spec.required, ...spec.optional]);
  const keys = Object.keys(obj);
  if (keys.some((k) => !allowed.has(k))) reject(REASON.keys);
  for (const k of [...COMMON_REQUIRED, ...spec.required]) {
    if (!Object.hasOwn(obj, k)) reject(REASON.keys);
  }

  const out = { schema_version: SCHEMA_VERSION, event };
  for (const k of keys) {
    if (k === 'schema_version' || k === 'event') continue;
    out[k] = checkField(FIELDS[k], obj[k]);
  }
  for (const c of CONDITIONS) {
    if (Object.hasOwn(out, c.key) && out[c.whenKey] !== c.equals) reject(REASON.condition);
  }
  return out;
}

/** @param {unknown} obj @returns {{ok: true, event: object} | {ok: false, reason: string}} */
export function validateEvent(obj) {
  try {
    return { ok: true, event: check(obj) };
  } catch (err) {
    return { ok: false, reason: err instanceof Reject ? err.message : REASON.shape };
  }
}
