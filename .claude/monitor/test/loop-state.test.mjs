// ループ状態の読み取りモジュール（Issue #22 / Red）。server/loop-state.mjs の契約テスト。
//
// ════════════════════════════════════════════════════════════════════════════
//  Coder への契約
// ════════════════════════════════════════════════════════════════════════════
//  export const MAX_LOOP_STATE_BYTES = 65536
//  export function readLoopState(path) -> object     同期。必ずオブジェクトを返す。例外は投げない
//
//  読めない場合: { status: 'unknown', reason } だけ（他のキーを付けない）。reason は固定の列挙:
//    missing | symlink | not_file | too_large | empty | invalid_json | invalid_shape | read_error
//    symlink : 状態ファイル自体、または直接の親ディレクトリがリンク（lstat。ダングリングも。リンク先が妥当な JSON でも読まない）
//    not_file: ディレクトリ・FIFO など通常ファイル以外
//    too_large: lstat のサイズが上限超（読まない）。読んでいる途中で超えた場合も too_large
//    empty   : 0 バイト
//    invalid_json / invalid_shape: JSON 破損 / 必須欠落・型違い・status 列挙外・トップが null や配列
//  読めた場合: 許可リストだけ
//    { status, issue, branch, epic, retry, limits:{max_retry,max_minutes,max_same_gate_fail}, gates:{G1..G5:{result}}, halt_reason, started_at }
//    必須: status('running'|'halted'|'completed') / issue(文字列) / retry(0 以上の整数) / limits の 3 つ(0 以上の整数) /
//          started_at(YYYY-MM-DDTHH:MM:SSZ)
//    任意: branch・epic(文字列、無い・型違いは null) / halt_reason(文字列か null) /
//          gates(G1〜G5 のみ。result が pass|fail 以外は捨てる。reason・at は返さない)
//    文字列は C0 / DEL / C1 / 双方向制御文字を除去してから長さ制限（halt_reason 200 / branch 200 / issue・epic 64）
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（防御を1つ外した隔離コピーで、左の変異に対し右のテストが FAIL するべき）
//  手順: .claude/monitor を一時ディレクトリへコピーし、server/loop-state.mjs に左の変異を入れ、このファイルを node --test で走らせる
// ════════════════════════════════════════════════════════════════════════════
//   lstat 拒否を外す（statSync / readFileSync でリンクを辿る）
//                                  [symlink] 妥当な JSON へのリンク・ダングリング・親ディレクトリがリンク
//   親ディレクトリの lstat だけ外す  [symlink] 親ディレクトリがリンク
//   サイズ上限を外す / 上限を 65537 以上にする / lstat 判定をやめて読んでから測る
//                                  [size] 65537 バイトが too_large でない（65536 ちょうどは読める）
//   種別検査（isFile）を外す         [not_file] ディレクトリ・FIFO が not_file でない（FIFO は open で固まる）
//   「不明」への倒しを外す（失敗時に空の running 等を返す / 例外を投げる）
//                                  [unknown] missing・empty・invalid_json・invalid_shape の全件・[shape] 必須欠落と型違い・status 列挙外
//   (b) status の列挙検査 STATUSES.has(raw.status) を外す（常に true）
//                                  [shape] 他の必須を全部揃えた status=constructor / toString / __proto__ / hasOwnProperty / RUNNING / "" は invalid_shape
//   (c) gate の result 列挙検査 GATE_RESULTS.has(gate.result) を外す（常に true）
//                                  [allowlist] result=PASS / FAIL / ok / "" / constructor / toString / __proto__ / null / 1 のゲートが捨てられる
//   必須項目の型・範囲の検査を外す（retry・limits.*・started_at）  [shape] 型違い・範囲外（validState で他を揃えて 1 つだけ壊す）
//   status を検証せず素通しする       [shape] status が 'unknown' / 'RUNNING' / 数値
//   フィールド許可リストを外す（JSON をそのまま返す）
//                                  [allowlist] 返り値のキー集合の完全一致・awake_start / history / gates.*.reason が出ない
//   gates のキーを検証しない          [allowlist] G6 / __proto__ / constructor のゲートが出ない
//   gates.*.result を検証しない       [allowlist] result が pass|fail 以外のゲートが捨てられる
//   制御文字の除去を外す / bidi を残す [sanitize] C0 / DEL / C1 / 双方向制御文字
//   長さ制限を外す / 除去前に切る      [sanitize] 200 / 64 文字の上限・除去してから切る
//   実物の loop-state.sh の出力形式と食い違う  [real] init / gate / stop が作った実ファイル

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, symlinkSync, writeFileSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { cleanupTmp, load, makeTmpDir, MONITOR_DIR } from './helpers.mjs';

after(cleanupTmp);

const REPO_ROOT = join(MONITOR_DIR, '..', '..');
const SCRIPT = join(REPO_ROOT, '.claude', 'scripts', 'loop-state.sh');
const reader = async () => (await load('loop-state.mjs')).readLoopState;

const validState = (over = {}) => ({
  issue: '22',
  branch: 'feat/22-loop-state-panel',
  epic: 'ai-monitor',
  status: 'running',
  started_at: '2026-10-10T05:14:26Z',
  limits: { max_retry: 3, max_minutes: 180, max_same_gate_fail: 2 },
  retry: 1,
  gates: { G1: { result: 'pass', reason: 'ok', at: '2026-10-10T05:20:00Z' } },
  halt_reason: null,
  ...over,
});

function put(obj, name = 'loop-state.json') {
  const dir = makeTmpDir();
  const p = join(dir, name);
  writeFileSync(p, typeof obj === 'string' || Buffer.isBuffer(obj) ? obj : JSON.stringify(obj));
  return p;
}

async function expectUnknown(p, reason, label = '') {
  const read = await reader();
  let r;
  assert.doesNotThrow(() => { r = read(p); }, `${label} 例外を投げた`);
  assert.deepEqual(r, { status: 'unknown', reason }, `${label} 期待 unknown/${reason}、実際 ${JSON.stringify(r)}`);
}

// ---------- 前提 ----------

test('[import] loop-state.mjs が readLoopState と MAX_LOOP_STATE_BYTES=65536 を export する', async () => {
  const m = await load('loop-state.mjs');
  assert.equal(typeof m.readLoopState, 'function');
  assert.equal(m.MAX_LOOP_STATE_BYTES, 65536);
});

// ---------- 正常系 ----------

test('[ok] 妥当な状態を許可リストのキーだけで返す（キー集合の完全一致）', async () => {
  const r = (await reader())(put(validState()));
  assert.deepEqual(Object.keys(r).sort(),
    ['branch', 'epic', 'gates', 'halt_reason', 'issue', 'limits', 'retry', 'started_at', 'status']);
  assert.deepEqual(r, {
    status: 'running',
    issue: '22',
    branch: 'feat/22-loop-state-panel',
    epic: 'ai-monitor',
    retry: 1,
    limits: { max_retry: 3, max_minutes: 180, max_same_gate_fail: 2 },
    gates: { G1: { result: 'pass' } },
    halt_reason: null,
    started_at: '2026-10-10T05:14:26Z',
  });
});

for (const status of ['running', 'halted', 'completed']) {
  test(`[ok] status=${status} はそのまま返る`, async () => {
    const r = (await reader())(put(validState({ status })));
    assert.equal(r.status, status);
  });
}

test('[ok] 任意フィールド（branch・epic・halt_reason・gates）が無くても読める。無い文字列は null、gates は {}', async () => {
  const s = validState();
  delete s.branch; delete s.epic; delete s.halt_reason; delete s.gates;
  const r = (await reader())(put(s));
  assert.equal(r.status, 'running');
  assert.equal(r.branch, null);
  assert.equal(r.epic, null);
  assert.equal(r.halt_reason, null);
  assert.deepEqual(r.gates, {});
});

test('[ok] 任意フィールドが型違い（branch=数値・epic=配列）なら null（unknown にしない）', async () => {
  const r = (await reader())(put(validState({ branch: 1, epic: ['x'] })));
  assert.equal(r.status, 'running');
  assert.equal(r.branch, null);
  assert.equal(r.epic, null);
});

test('[ok] halt_reason の文字列は保持される', async () => {
  const r = (await reader())(put(validState({ status: 'halted', halt_reason: 'リトライ上限に到達' })));
  assert.equal(r.halt_reason, 'リトライ上限に到達');
});

test('[ok] 65536 バイトちょうどのファイルは読める（空白で埋めた妥当な JSON）', async () => {
  const body = JSON.stringify(validState());
  const pad = ' '.repeat(65536 - Buffer.byteLength(body));
  const p = put(body + pad);
  const r = (await reader())(p);
  assert.equal(r.status, 'running');
});

// ---------- [unknown] 読めない状態 ----------

test('[unknown] missing: ファイルが無い', async () => {
  await expectUnknown(join(makeTmpDir(), 'nope.json'), 'missing');
});

test('[unknown] empty: 0 バイト', async () => {
  await expectUnknown(put(''), 'empty');
});

test('[unknown] too_large: 65537 バイトは読まずに too_large（妥当な JSON でも）', async () => {
  const body = JSON.stringify(validState());
  const pad = ' '.repeat(65537 - Buffer.byteLength(body));
  await expectUnknown(put(body + pad), 'too_large');
});

test('[unknown] too_large: 巨大ファイル（1MB）も too_large', async () => {
  await expectUnknown(put(Buffer.alloc(1024 * 1024, 0x20)), 'too_large');
});

for (const [name, text] of [['壊れた JSON', '{"status": "running"'], ['JSON でない', 'hello'], ['末尾ゴミ', '{"a":1} x']]) {
  test(`[unknown] invalid_json: ${name}`, async () => {
    await expectUnknown(put(text), 'invalid_json');
  });
}

for (const [name, text] of [['null', 'null'], ['配列', '[]'], ['配列に妥当な状態', JSON.stringify([validState()])], ['数値', '1'], ['文字列', '"running"'], ['空オブジェクト', '{}']]) {
  test(`[unknown] invalid_shape: トップが ${name}`, async () => {
    await expectUnknown(put(text), 'invalid_shape');
  });
}

test('[unknown] not_file: ディレクトリ', async () => {
  const dir = makeTmpDir();
  const p = join(dir, 'loop-state.json');
  mkdirSync(p);
  await expectUnknown(p, 'not_file');
});

test('[unknown] not_file: FIFO（作れる環境のみ。open で固まらない）', async (t) => {
  const dir = makeTmpDir();
  const p = join(dir, 'loop-state.json');
  const mk = spawnSync('mkfifo', [p]);
  if (mk.status !== 0) return t.skip('mkfifo を作れない環境');
  await expectUnknown(p, 'not_file');
});

// ---------- [symlink] ----------

test('[symlink] 妥当な JSON へのリンクは読まず symlink', async () => {
  const dir = makeTmpDir();
  const real = join(dir, 'real.json');
  writeFileSync(real, JSON.stringify(validState()));
  const link = join(dir, 'loop-state.json');
  symlinkSync(real, link);
  await expectUnknown(link, 'symlink');
});

test('[symlink] ダングリングリンクは symlink（missing にしない）', async () => {
  const dir = makeTmpDir();
  const link = join(dir, 'loop-state.json');
  symlinkSync(join(dir, 'does-not-exist.json'), link);
  await expectUnknown(link, 'symlink');
});

test('[symlink] 直接の親ディレクトリがリンクなら symlink（中の状態ファイルが妥当でも）', async () => {
  const base = makeTmpDir();
  const realDir = join(base, 'real');
  mkdirSync(realDir);
  writeFileSync(join(realDir, 'loop-state.json'), JSON.stringify(validState()));
  const linkDir = join(base, 'memory');
  symlinkSync(realDir, linkDir);
  await expectUnknown(join(linkDir, 'loop-state.json'), 'symlink');
});

test('[symlink] 別の秘密ファイルへのリンクの中身は返り値に出ない', async () => {
  const dir = makeTmpDir();
  const secret = join(dir, 'secret.txt');
  writeFileSync(secret, 'TOPSECRET-VALUE');
  const link = join(dir, 'loop-state.json');
  symlinkSync(secret, link);
  const r = (await reader())(link);
  assert.deepEqual(r, { status: 'unknown', reason: 'symlink' });
  assert.ok(!JSON.stringify(r).includes('TOPSECRET'));
});

// ---------- [shape] 必須フィールド ----------

const REQUIRED = [
  ['status', (s) => { delete s.status; }],
  ['issue', (s) => { delete s.issue; }],
  ['retry', (s) => { delete s.retry; }],
  ['limits', (s) => { delete s.limits; }],
  ['limits.max_retry', (s) => { delete s.limits.max_retry; }],
  ['limits.max_minutes', (s) => { delete s.limits.max_minutes; }],
  ['limits.max_same_gate_fail', (s) => { delete s.limits.max_same_gate_fail; }],
  ['started_at', (s) => { delete s.started_at; }],
];
for (const [name, mutate] of REQUIRED) {
  test(`[shape] 必須 ${name} が欠けたら invalid_shape（running として返さない）`, async () => {
    const s = validState();
    mutate(s);
    await expectUnknown(put(s), 'invalid_shape', name);
  });
}

const WRONG_TYPES = [
  ['status=数値', { status: 1 }],
  ['status=unknown', { status: 'unknown' }],
  ['status=RUNNING', { status: 'RUNNING' }],
  ['status=空文字', { status: '' }],
  ['status=constructor', { status: 'constructor' }],
  ['status=toString', { status: 'toString' }],
  ['status=__proto__', { status: '__proto__' }],
  ['status=hasOwnProperty', { status: 'hasOwnProperty' }],
  ['status=halted の大文字', { status: 'HALTED' }],
  ['status=前後に空白', { status: 'running ' }],
  ['status=null', { status: null }],
  ['status=配列', { status: ['running'] }],
  ['issue=数値', { issue: 22 }],
  ['issue=null', { issue: null }],
  ['retry=文字列', { retry: '1' }],
  ['retry=負数', { retry: -1 }],
  ['retry=小数', { retry: 1.5 }],
  ['retry=null', { retry: null }],
  ['retry=安全でない整数', { retry: 2 ** 53 }],
  ['limits.max_retry=負数', { limits: { max_retry: -1, max_minutes: 180, max_same_gate_fail: 2 } }],
  ['limits.max_retry=小数', { limits: { max_retry: 1.5, max_minutes: 180, max_same_gate_fail: 2 } }],
  ['limits.max_minutes=文字列', { limits: { max_retry: 3, max_minutes: '180', max_same_gate_fail: 2 } }],
  ['limits.max_same_gate_fail=文字列', { limits: { max_retry: 3, max_minutes: 180, max_same_gate_fail: '2' } }],
  ['started_at=null', { started_at: null }],
  ['retry=NaN 相当の巨大値でない文字列', { retry: 'x' }],
  ['limits=null', { limits: null }],
  ['limits=配列', { limits: [3, 180, 2] }],
  ['limits.max_retry=文字列', { limits: { max_retry: '3', max_minutes: 180, max_same_gate_fail: 2 } }],
  ['limits.max_minutes=負数', { limits: { max_retry: 3, max_minutes: -1, max_same_gate_fail: 2 } }],
  ['limits.max_same_gate_fail=小数', { limits: { max_retry: 3, max_minutes: 180, max_same_gate_fail: 0.5 } }],
  ['started_at=数値', { started_at: 1791609266 }],
  ['started_at=形式違い', { started_at: '2026-10-10 05:14:26' }],
  ['started_at=タイムゾーン付き', { started_at: '2026-10-10T05:14:26+09:00' }],
  ['started_at=空文字', { started_at: '' }],
  ['started_at=ミリ秒付き', { started_at: '2026-10-10T05:14:26.123Z' }],
];
for (const [name, over] of WRONG_TYPES) {
  test(`[shape] 型違い・範囲外 ${name} は invalid_shape`, async () => {
    await expectUnknown(put(validState(over)), 'invalid_shape', name);
  });
}

// ---------- [allowlist] ----------

test('[allowlist] 未知のトップレベルキー・awake_start・boot_id・started_epoch・history・consecutive_gate_fail は返さない', async () => {
  const r = (await reader())(put(validState({
    awake_start: 438634, boot_id: 'ABC', started_epoch: 1791609266,
    history: [{ type: 'gate', reason: 'secret' }], consecutive_gate_fail: { G1: 1 },
    password: 'hunter2', __extra: 1,
  })));
  assert.deepEqual(Object.keys(r).sort(),
    ['branch', 'epic', 'gates', 'halt_reason', 'issue', 'limits', 'retry', 'started_at', 'status']);
  const text = JSON.stringify(r);
  for (const bad of ['awake_start', 'boot_id', 'started_epoch', 'history', 'consecutive_gate_fail', 'hunter2', 'secret']) {
    assert.ok(!text.includes(bad), `${bad} が出ている`);
  }
});

test('[allowlist] limits は 3 キーだけ（未知のキーを返さない）', async () => {
  const r = (await reader())(put(validState({ limits: { max_retry: 3, max_minutes: 180, max_same_gate_fail: 2, evil: 9 } })));
  assert.deepEqual(r.limits, { max_retry: 3, max_minutes: 180, max_same_gate_fail: 2 });
});

test('[allowlist] gates.*.reason と at を返さない（result だけ）', async () => {
  const r = (await reader())(put(validState({
    gates: {
      G1: { result: 'pass', reason: 'r1', at: 'a' },
      G2: { result: 'fail', reason: 'SECRET-REASON', at: 'b', extra: 1 },
    },
  })));
  assert.deepEqual(r.gates, { G1: { result: 'pass' }, G2: { result: 'fail' } });
  assert.ok(!JSON.stringify(r).includes('SECRET-REASON'));
});

test('[allowlist] G1〜G5 以外のゲート名（G0・G6・g1・constructor）は捨てる', async () => {
  const r = (await reader())(put(validState({
    gates: {
      G0: { result: 'pass' }, G6: { result: 'pass' }, g1: { result: 'pass' }, constructor: { result: 'pass' },
      G5: { result: 'fail' },
    },
  })));
  assert.deepEqual(Object.keys(r.gates), ['G5']);
});

test('[allowlist] JSON の __proto__ キーのゲートを捨て、プロトタイプを汚さない', async () => {
  const text = `{"issue":"22","status":"running","started_at":"2026-10-10T05:14:26Z","retry":0,`
    + `"limits":{"max_retry":3,"max_minutes":180,"max_same_gate_fail":2},`
    + `"gates":{"__proto__":{"result":"pass"},"G1":{"result":"pass"}},"__proto__":{"polluted":true}}`;
  const r = (await reader())(put(text));
  assert.equal(r.status, 'running');
  assert.deepEqual(Object.keys(r.gates), ['G1']);
  assert.equal(Object.getPrototypeOf(r.gates), Object.prototype);
  assert.equal({}.polluted, undefined);
  assert.equal(Object.hasOwn(r, 'polluted'), false);
});

for (const bad of ['PASS', 'FAIL', 'ok', '', 'constructor', 'toString', '__proto__', 'hasOwnProperty', null, 1, true, { x: 1 }]) {
  test(`[allowlist] result=${JSON.stringify(bad)} のゲートは捨てる`, async () => {
    const r = (await reader())(put(validState({ gates: { G1: { result: bad }, G2: { result: 'pass' } } })));
    assert.deepEqual(r.gates, { G2: { result: 'pass' } });
  });
}

test('[allowlist] gates が配列・文字列・null・ゲート値が null でも unknown にせず、読める分だけ返す', async () => {
  const read = await reader();
  for (const gates of [[], 'x', null, 5]) {
    const r = read(put(validState({ gates })));
    assert.equal(r.status, 'running', `gates=${JSON.stringify(gates)}`);
    assert.deepEqual(r.gates, {});
  }
  const r2 = read(put(validState({ gates: { G1: null, G2: 'pass', G3: { result: 'fail' } } })));
  assert.deepEqual(r2.gates, { G3: { result: 'fail' } });
});

// ---------- [sanitize] ----------

const CONTROLS = {
  'C0 (NUL/BEL/ESC/LF/CR/TAB)': '\u0000\u0007\u001b\n\r\t',
  DEL: '\u007f',
  'C1 (0x80-0x9f)': '\u0080\u008d\u009f',
  '双方向制御 (LRE-RLO / LRI-PDI / LRM RLM。ALM は event-schema.md の範囲外)': '\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\u200e\u200f',
};
for (const [name, chars] of Object.entries(CONTROLS)) {
  test(`[sanitize] halt_reason / branch / issue / epic から ${name} を除去する`, async () => {
    const r = (await reader())(put(validState({
      halt_reason: `a${chars}b`, branch: `c${chars}d`, issue: `1${chars}2`, epic: `e${chars}f`,
    })));
    assert.equal(r.halt_reason, 'ab');
    assert.equal(r.branch, 'cd');
    assert.equal(r.issue, '12');
    assert.equal(r.epic, 'ef');
  });
}

test('[sanitize] 通常の日本語・記号は残す', async () => {
  const r = (await reader())(put(validState({ halt_reason: 'リトライ上限に到達（3/3 回）。' })));
  assert.equal(r.halt_reason, 'リトライ上限に到達（3/3 回）。');
});

test('[sanitize] 長さ制限: halt_reason 200 / branch 200 / issue 64 / epic 64（文字数）', async () => {
  const r = (await reader())(put(validState({
    halt_reason: 'h'.repeat(500), branch: 'b'.repeat(500), issue: 'i'.repeat(500), epic: 'e'.repeat(500),
  })));
  assert.equal(r.halt_reason.length, 200);
  assert.equal(r.branch.length, 200);
  assert.equal(r.issue.length, 64);
  assert.equal(r.epic.length, 64);
});

test('[sanitize] 長さ制限は境界: 200 ちょうどは全部残り、201 は 200', async () => {
  const read = await reader();
  assert.equal(read(put(validState({ halt_reason: 'h'.repeat(200) }))).halt_reason.length, 200);
  assert.equal(read(put(validState({ halt_reason: 'h'.repeat(201) }))).halt_reason.length, 200);
  assert.equal(read(put(validState({ issue: 'i'.repeat(64) }))).issue.length, 64);
  assert.equal(read(put(validState({ issue: 'i'.repeat(65) }))).issue.length, 64);
});

test('[sanitize] 制御文字を先に除去してから切る（制御文字で水増しして本文を隠せない）', async () => {
  const r = (await reader())(put(validState({ halt_reason: `x${'\u0007'.repeat(300)}${'y'.repeat(50)}` })));
  assert.equal(r.halt_reason, `x${'y'.repeat(50)}`);
});

test('[sanitize] gates の result など列挙値に制御文字を混ぜても列挙外として捨てる', async () => {
  const r = (await reader())(put(validState({ gates: { G1: { result: 'pass\n' } } })));
  assert.deepEqual(r.gates, {});
});

// ---------- [real] 実物の loop-state.sh ----------

function runLoopState(projectDir, args, env = {}) {
  return spawnSync('bash', [SCRIPT, ...args], {
    env: { PATH: process.env.PATH, HOME: process.env.HOME, CLAUDE_PROJECT_DIR: projectDir, ...env },
    encoding: 'utf8',
  });
}

test('[real] 実物の loop-state.sh init / gate / stop が作った状態ファイルを期待どおり読む（一時ディレクトリ。本物の状態には触れない）', async (t) => {
  const projectDir = makeTmpDir();
  assert.notEqual(projectDir, REPO_ROOT);
  const init = runLoopState(projectDir, ['init', '22', 'feat/22-x', 'ai-monitor']);
  assert.equal(init.status, 0, init.stderr);
  const statePath = join(projectDir, '.claude', 'memory', 'loop-state.json');
  const read = await reader();

  let r = read(statePath);
  assert.equal(r.status, 'running');
  assert.equal(r.issue, '22');
  assert.equal(r.branch, 'feat/22-x');
  assert.equal(r.epic, 'ai-monitor');
  assert.equal(r.retry, 0);
  assert.deepEqual(r.gates, {});
  assert.equal(r.halt_reason, null);
  assert.match(r.started_at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.deepEqual(Object.keys(r.limits).sort(), ['max_minutes', 'max_retry', 'max_same_gate_fail']);

  const g1 = runLoopState(projectDir, ['gate', 'G1', 'pass']);
  assert.equal(g1.status, 0, g1.stderr);
  const g2 = runLoopState(projectDir, ['gate', 'G2', 'fail', 'SECRET-GATE-REASON']);
  assert.equal(g2.status, 0, g2.stderr);
  r = read(statePath);
  assert.deepEqual(r.gates, { G1: { result: 'pass' }, G2: { result: 'fail' } });
  assert.ok(!JSON.stringify(r).includes('SECRET-GATE-REASON'));

  // stop は終了コード 1 を返す仕様（halted を記録して非 0）
  const stop = runLoopState(projectDir, ['stop', 'テスト用の停止理由']);
  assert.notEqual(stop.status, null);
  r = read(statePath);
  assert.equal(r.status, 'halted');
  assert.equal(r.halt_reason, 'テスト用の停止理由');
  for (const k of ['awake_start', 'boot_id', 'started_epoch', 'history', 'consecutive_gate_fail']) {
    assert.equal(Object.hasOwn(r, k), false, `${k} が出ている`);
  }
  // 実ファイルに許可リスト外のキーが本当にある（このテストが空振りでない証拠）
  const raw = JSON.parse(readFileSync(statePath, 'utf8'));
  assert.ok(Object.hasOwn(raw, 'history'));
  t.diagnostic('real loop-state.sh OK');
});
