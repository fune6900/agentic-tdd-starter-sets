// 制御文字クラスの共通化（Issue #22 retry 1 / Red）。
//   server/control-chars.mjs が制御文字・双方向制御文字の文字クラスを「エスケープ表記」で 1 つだけ定義し、
//   schema.mjs（拒否用）と loop-state.mjs（除去用）が import する。server/*.mjs に生の双方向制御文字を置かない。

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { SERVER_DIR, MONITOR_DIR } from './helpers.mjs';

const MODULE = join(SERVER_DIR, 'control-chars.mjs');
const read = (f) => readFileSync(join(SERVER_DIR, f), 'utf8');
const serverFiles = () => readdirSync(SERVER_DIR).filter((n) => n.endsWith('.mjs'));

const BIDI = [[0x200e, 0x200f], [0x202a, 0x202e], [0x2066, 0x2069]]; // event-schema.md:73。U+061C は仕様外

test('[control-chars] server/control-chars.mjs が存在し、1 つ以上 export する', async () => {
  assert.ok(existsSync(MODULE), 'control-chars.mjs が無い');
  const m = await import('../server/control-chars.mjs');
  assert.ok(Object.keys(m).length >= 1);
});

test('[control-chars] export された文字クラス（RegExp または文字列）が制御文字と双方向制御文字に一致し、通常の文字には一致しない', async () => {
  const m = await import('../server/control-chars.mjs');
  const toRegExp = (v) => {
    if (v instanceof RegExp) return new RegExp(v.source, v.flags.replace(/[gy]/g, ''));
    if (typeof v === 'string') {
      try { return new RegExp(v.startsWith('[') ? v : `[${v}]`, 'u'); } catch { return null; }
    }
    return null;
  };
  const candidates = Object.values(m).map(toRegExp).filter((r) => r !== null);
  assert.ok(candidates.length >= 1, 'RegExp でも文字列でもない export しかない');
  const must = ['\u0000', '\u0007', '\u001f', '\u007f', '\u0085', '\u009f', '\u200e', '\u200f', '\u202a', '\u202e', '\u2066', '\u2069'];
  // U+061C（ALM）・U+2028/2029・U+200B・U+200D・U+2065・U+2060 などは仕様外。拒否・除去してはいけない
  const mustNot = ['a', 'Z', '0', ' ', '日', '/', 'x', '\u00a0', '\u061c', '\u200d', '\u2028', '\u2065', '\u202f', '\u2060', '\u206a'];
  const good = candidates.filter((r) => must.every((c) => r.test(c)) && mustNot.every((c) => !r.test(c)));
  assert.ok(good.length >= 1, '全ての制御文字に一致して通常文字に一致しない文字クラスが export されていない');
});

test('[control-chars] control-chars.mjs はエスケープ表記（\\uXXXX）で書かれている', () => {
  const src = readFileSync(MODULE, 'utf8');
  for (const needle of ['\\u202a', '\\u202e', '\\u2066', '\\u2069', '\\u200e', '\\u200f', '\\u0000', '\\u007f', '\\u009f']) {
    assert.ok(src.toLowerCase().includes(needle), `${needle} のエスケープが無い`);
  }
});

test('[control-chars] schema.mjs と loop-state.mjs が ./control-chars.mjs から import し、import した名前が実在する', async () => {
  const m = await import('../server/control-chars.mjs');
  for (const f of ['schema.mjs', 'loop-state.mjs']) {
    const match = read(f).match(/import\s*\{([^}]*)\}\s*from\s*['"]\.\/control-chars\.mjs['"]/);
    assert.ok(match, `${f} が ./control-chars.mjs から import していない`);
    const names = match[1].split(',').map((x) => x.trim().split(/\s+as\s+/)[0]).filter(Boolean);
    assert.ok(names.length >= 1);
    for (const n of names) assert.ok(n in m, `${f} が import した ${n} が control-chars.mjs に無い`);
  }
});

test('[control-chars] 定義は 1 箇所だけ: control-chars.mjs 以外の server/*.mjs に制御文字範囲のエスケープ（\\u202A 等）を書かない', () => {
  for (const f of serverFiles().filter((n) => n !== 'control-chars.mjs')) {
    const src = read(f).toLowerCase();
    for (const needle of ['\\u202a', '\\u2066', '\\u200e', '\\u007f-\\u009f', '\\u0000-\\u001f']) {
      assert.ok(!src.includes(needle), `${f} に重複定義がある: ${needle}`);
    }
  }
});

test('[control-chars] server/*.mjs に生の双方向制御文字（U+202A-202E, U+2066-2069, U+200E/200F）が 1 文字も無い', () => {
  const files = serverFiles();
  assert.ok(files.length >= 8, `検査対象が少なすぎる: ${files.length}`);
  assert.ok(files.includes('control-chars.mjs'), 'control-chars.mjs が検査対象に入っていない');
  for (const f of files) {
    const src = read(f);
    for (const ch of src) {
      const cp = ch.codePointAt(0);
      assert.ok(!BIDI.some(([lo, hi]) => cp >= lo && cp <= hi), `${f} に生の U+${cp.toString(16).toUpperCase().padStart(4, '0')}`);
    }
  }
});

test('[control-chars] U+061C（ALM）は仕様（event-schema.md:73）に無いので、共有クラスは一致しない', async () => {
  const m = await import('../server/control-chars.mjs');
  const regs = Object.values(m).filter((v) => v instanceof RegExp).map((r) => new RegExp(r.source, r.flags.replace(/[gy]/g, '')));
  assert.ok(regs.length >= 1, 'RegExp の export が無い');
  for (const r of regs) assert.ok(!r.test('\u061c'), 'U+061C に一致している（送信側 monitor-emit.sh は落とさない）');
});

test('[control-chars] 共有クラスが event-schema.md の file_path 禁止範囲と 0000-FFFF 全域で完全に一致する', async () => {
  const spec = readFileSync(join(MONITOR_DIR, 'docs', 'event-schema.md'), 'utf8');
  const rows = spec.split('\n').filter((l) => /^- (C0 制御文字|DEL と C1 制御文字|双方向制御文字)[:：]/.test(l));
  assert.equal(rows.length, 3, 'event-schema.md の 3 行（C0 / DEL と C1 / 双方向）が取り出せない');
  const ranges = [];
  for (const row of rows) {
    const toks = [...row.matchAll(/U\+([0-9A-Fa-f]{4})(?:-U\+([0-9A-Fa-f]{4}))?/g)];
    assert.ok(toks.length >= 1, `範囲が取り出せない: ${row}`);
    for (const t of toks) ranges.push([parseInt(t[1], 16), parseInt(t[2] ?? t[1], 16)]);
  }
  const inSpec = (cp) => ranges.some(([lo, hi]) => cp >= lo && cp <= hi);
  const m = await import('../server/control-chars.mjs');
  const regs = Object.values(m).filter((v) => v instanceof RegExp).map((r) => new RegExp(r.source, r.flags.replace(/[gy]/g, '')));
  assert.ok(regs.length >= 1, 'RegExp の export が無い');
  for (const r of regs) {
    const diff = [];
    for (let cp = 0; cp <= 0xffff; cp++) {
      if (cp >= 0xd800 && cp <= 0xdfff) continue;
      if (r.test(String.fromCodePoint(cp)) !== inSpec(cp)) diff.push('U+' + cp.toString(16).toUpperCase().padStart(4, '0'));
    }
    assert.deepEqual(diff, [], `仕様と不一致: ${diff.slice(0, 10).join(', ')}`);
  }
});
