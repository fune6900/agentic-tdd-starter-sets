// ループ状態（loop-state.json）の読み取り。依存ゼロ・同期・例外を投げない。
// 倒す向きは fail closed の「表示版」: 読めない・判定できない状態は { status: 'unknown', reason } だけを返し、
// running / completed として返さない（lessons #10）。リンクは辿らない。返すのは許可リストのフィールドだけ。
//
// 止まらない範囲（TOCTOU）: lstat と open の間に同じ権限の別プロセスがリンクへ差し替えれば、
// O_NOFOLLOW（最終要素のみ）と open 後の fstat（通常ファイル確認）で狭めるが、親ディレクトリの差し替えは止めない。

import { closeSync, constants, fstatSync, lstatSync, openSync, readSync } from 'node:fs';
import { dirname } from 'node:path';
import { CONTROL_CHARS_PATTERN } from './control-chars.mjs';

export const MAX_LOOP_STATE_BYTES = 65_536;

const MAX_HALT_REASON_LENGTH = 200;
const MAX_BRANCH_LENGTH = 200;
const MAX_ID_LENGTH = 64;
const STATUSES = new Set(['running', 'halted', 'completed']);
const GATE_NAMES = ['G1', 'G2', 'G3', 'G4', 'G5'];
const GATE_RESULTS = new Set(['pass', 'fail']);
const LIMIT_KEYS = ['max_retry', 'max_minutes', 'max_same_gate_fail'];
const STARTED_AT_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

const REASON_BY_ERRNO = { ENOENT: 'missing', ELOOP: 'symlink' };
const unknown = (reason) => ({ status: 'unknown', reason });

class Unreadable extends Error {
  constructor(reason) {
    super(reason);
    this.reason = reason;
  }
}

const isPlainObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const isCount = (value) => Number.isSafeInteger(value) && value >= 0;
const has = (object, key) => Object.hasOwn(object, key);

/** 制御文字を先に除去してから文字数で切る */
function cleanString(value, maxLength) {
  return [...value.replace(CONTROL_CHARS_PATTERN, '')].slice(0, maxLength).join('');
}

const optionalString = (value, maxLength) => (typeof value === 'string' ? cleanString(value, maxLength) : null);

function lstatOrThrow(path) {
  try {
    return lstatSync(path);
  } catch (err) {
    throw new Unreadable(REASON_BY_ERRNO[err?.code] ?? 'read_error');
  }
}

/** 検査: 親ディレクトリとファイル自体がリンクでなく、通常ファイルで、上限以内 */
function inspect(path) {
  if (lstatOrThrow(dirname(path)).isSymbolicLink()) throw new Unreadable('symlink');
  const stat = lstatOrThrow(path);
  if (stat.isSymbolicLink()) throw new Unreadable('symlink');
  if (!stat.isFile()) throw new Unreadable('not_file');
  if (stat.size > MAX_LOOP_STATE_BYTES) throw new Unreadable('too_large');
}

/** 上限 +1 バイトまで読む。超えたら too_large */
function readBounded(path) {
  let fd;
  try {
    // O_NONBLOCK: 検査後に FIFO へ差し替えられても open で固まらない
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (err) {
    throw new Unreadable(REASON_BY_ERRNO[err?.code] ?? 'read_error');
  }
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile()) throw new Unreadable('not_file');
    if (stat.size > MAX_LOOP_STATE_BYTES) throw new Unreadable('too_large');
    const buffer = Buffer.alloc(MAX_LOOP_STATE_BYTES + 1);
    let total = 0;
    while (total < buffer.length) {
      const n = readSync(fd, buffer, total, buffer.length - total, null);
      if (n === 0) break;
      total += n;
    }
    if (total > MAX_LOOP_STATE_BYTES) throw new Unreadable('too_large');
    return buffer.subarray(0, total);
  } catch (err) {
    throw err instanceof Unreadable ? err : new Unreadable('read_error');
  } finally {
    closeSync(fd);
  }
}

function parse(buffer) {
  if (buffer.length === 0) throw new Unreadable('empty');
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer));
  } catch {
    throw new Unreadable('invalid_json');
  }
}

function pickGates(rawGates) {
  const gates = {};
  if (!isPlainObject(rawGates)) return gates;
  for (const name of GATE_NAMES) {
    if (!has(rawGates, name)) continue;
    const gate = rawGates[name];
    if (isPlainObject(gate) && has(gate, 'result') && GATE_RESULTS.has(gate.result)) gates[name] = { result: gate.result };
  }
  return gates;
}

/** 必須の検証と許可リストの抽出。通らなければ invalid_shape */
function pick(raw) {
  if (!isPlainObject(raw)) throw new Unreadable('invalid_shape');
  const required = has(raw, 'status') && STATUSES.has(raw.status)
    && has(raw, 'issue') && typeof raw.issue === 'string'
    && has(raw, 'retry') && isCount(raw.retry)
    && has(raw, 'limits') && isPlainObject(raw.limits) && LIMIT_KEYS.every((k) => has(raw.limits, k) && isCount(raw.limits[k]))
    && has(raw, 'started_at') && typeof raw.started_at === 'string' && STARTED_AT_PATTERN.test(raw.started_at);
  if (!required) throw new Unreadable('invalid_shape');
  const optional = (key, max) => (has(raw, key) ? optionalString(raw[key], max) : null);
  return {
    status: raw.status,
    issue: cleanString(raw.issue, MAX_ID_LENGTH),
    branch: optional('branch', MAX_BRANCH_LENGTH),
    epic: optional('epic', MAX_ID_LENGTH),
    retry: raw.retry,
    limits: Object.fromEntries(LIMIT_KEYS.map((k) => [k, raw.limits[k]])),
    gates: pickGates(has(raw, 'gates') ? raw.gates : undefined),
    halt_reason: optional('halt_reason', MAX_HALT_REASON_LENGTH),
    started_at: raw.started_at,
  };
}

/**
 * @param {string} path
 * @returns {object} 読めたら許可リストのフィールド、読めなければ { status: 'unknown', reason }
 */
export function readLoopState(path) {
  try {
    inspect(path);
    return pick(parse(readBounded(path)));
  } catch (err) {
    return unknown(err instanceof Unreadable ? err.reason : 'read_error');
  }
}
