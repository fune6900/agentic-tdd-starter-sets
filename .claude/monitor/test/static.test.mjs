// ソースの静的検査（Issue #19 / Red）。契約は server.test.mjs の冒頭コメントを見ろ。
//
//   [SQL]  server/ 配下の全 .mjs に、SQL 文字列への動的な値の混入が無いこと
//          prepare( / exec( の第1引数は静的（文字列リテラル・置換なしテンプレート・識別子）
//          SQL らしい置換付きテンプレート・`+` 連結が無い
//   [deps] .claude/monitor 配下の全 .mjs の import 指定子が node: か相対パスのみ（動的 import・require も検査）
//          package.json があれば dependencies / devDependencies 等が空
//
// 検査自体の自己診断（lessons #5: 全部 PASS は何も検査していなくても起きる）:
//   既知の悪い書き方を必ず検出し、コメント・文字列・正規表現リテラル内の同じ字面は誤検出しないことを固定する。
//   `don't` のようなコメント内のアポストロフィで後続が読み飛ばされて検知漏れ、を潰すのが目的。

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { findImports, findSqlInjectionRisks, isAllowedSpecifier } from './scan.mjs';
import { MONITOR_DIR, SERVER_DIR } from './helpers.mjs';

function listFiles(dir, pred, skip = []) {
  if (!existsSync(dir)) return [];
  const out = [];
  for (const name of readdirSync(dir)) {
    if (skip.includes(name)) continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...listFiles(p, pred, skip));
    else if (pred(name)) out.push(p);
  }
  return out;
}

const serverSources = () => listFiles(SERVER_DIR, (n) => n.endsWith('.mjs'));
const allSources = () => listFiles(MONITOR_DIR, (n) => n.endsWith('.mjs'), ['node_modules']);

// ---------- 自己診断: SQL 検査 ----------

const BT = '`';
const SQL_BAD = {
  'prepare + テンプレート埋め込み': `db.prepare(${BT}SELECT * FROM events WHERE id = \${id}${BT});`,
  'exec + テンプレート埋め込み': `db.exec(${BT}DELETE FROM events WHERE seq < \${n}${BT});`,
  'prepare + 文字列連結': `db.prepare("SELECT * FROM events WHERE id = " + id);`,
  'prepare + 関数呼び出し': `db.prepare(buildSql(id));`,
  '変数経由のテンプレート': `const q = ${BT}SELECT * FROM events WHERE id = \${id}${BT};\ndb.prepare(q);`,
  '変数経由の連結': `const q = "DELETE FROM events WHERE seq < " + n;\ndb.prepare(q);`,
  '改行を含む SQL テンプレート': `const q = ${BT}\n  SELECT seq\n  FROM events\n  WHERE x = \${x}\n${BT};`,
  'コメントの後ろの本物': `// don't worry about it\ndb.prepare(${BT}SELECT 1 FROM events WHERE a = \${a}${BT});`,
  '文字列の後ろの本物': `const s = "it's // not a comment";\ndb.prepare(${BT}SELECT 1 FROM events WHERE a = \${a}${BT});`,
  '正規表現リテラルの後ろの本物（同じ行）': `const re = /'/; db.prepare(${BT}SELECT 1 FROM events WHERE a = \${a}${BT});`,
  '入れ子の置換内': `const x = ${BT}a \${ db.prepare(${BT}SELECT 1 FROM events WHERE a = \${a}${BT}) } b${BT};`,
  'PRAGMA に埋め込み': `db.exec(${BT}PRAGMA user_version = \${v}${BT});`,
  '?. 経由': `this.db?.prepare(${BT}INSERT INTO events (a) VALUES (\${a})${BT});`,
};
const SQL_GOOD = {
  '静的リテラル': `db.prepare("SELECT * FROM events WHERE seq > ?").all(afterSeq);`,
  '置換なしテンプレート': `db.prepare(${BT}SELECT * FROM events WHERE seq > ?${BT}).all(afterSeq);`,
  '識別子の連なり': `db.prepare(SQL.insert).run(a);`,
  'exec も静的': `db.exec("CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL)");`,
  'コメント内の悪い字面': `// db.prepare(${BT}SELECT * FROM events WHERE id = \${id}${BT});\nconst a = 1;`,
  'ブロックコメント内の悪い字面': `/* db.prepare(${BT}DROP TABLE events WHERE \${x}${BT}) */\nconst a = 1;`,
  '文字列内の悪い字面': `const msg = "db.prepare(\` + SELECT * FROM events \${x}";`,
  'SQL でないテンプレート': `const m = ${BT}listening on \${bind}:\${port}${BT};`,
  'ログ文言の from': `const m = ${BT}failed from \${where}${BT};`,
  '正規表現リテラル内': `const re = /prepare\\(\`.*\\$\\{/;`,
};

test('[SQL 自己診断] 悪い書き方はコメント・文字列・正規表現を挟んでも必ず検出する', () => {
  for (const [name, src] of Object.entries(SQL_BAD)) {
    assert.ok(findSqlInjectionRisks(src).length > 0, `検知漏れ: ${name}`);
  }
});

test('[SQL 自己診断] コメント・文字列・正規表現・無関係なテンプレートの中の字面は誤検出しない', () => {
  for (const [name, src] of Object.entries(SQL_GOOD)) {
    assert.deepEqual(findSqlInjectionRisks(src), [], `誤検出: ${name}`);
  }
});

// ---------- 自己診断: import 検査 ----------

const IMPORT_BAD = {
  'bare パッケージ': `import express from "express";`,
  'bare 組み込み（node: 無し）': `import fs from "fs";`,
  '副作用 import': `import "lodash";`,
  'export from': `export * from "pkg";`,
  '名前付き export from': `export { a } from "pkg";`,
  '動的 import（リテラル）': `const m = await import("lodash");`,
  '動的 import（変数）': `const m = await import(name);`,
  '動的 import（テンプレート埋め込み）': `const m = await import(${BT}pkg-\${x}${BT});`,
  'require 使用': `const x = require("x");`,
  'createRequire 使用': `import { createRequire } from "node:module";\nconst r = createRequire(import.meta.url);`,
  '絶対パス': `import x from "/abs/path.mjs";`,
  'コメント後ろの本物': `// don't\nimport x from "express";`,
  '文字列後ろの本物': `const s = "it's";\nimport x from "express";`,
  'URL': `import x from "https://example.com/x.mjs";`,
};
const IMPORT_GOOD = {
  'node: 組み込み': `import http from "node:http";\nimport { DatabaseSync } from 'node:sqlite';`,
  '相対': `import { a } from "./validate.mjs";\nimport b from '../x.mjs';`,
  '動的 import（node:）': `const { DatabaseSync } = await import("node:sqlite");`,
  'import.meta': `const u = new URL("./x", import.meta.url);`,
  'コメント内': `// import x from "express";\n/* import("lodash") */`,
  '文字列内': `const s = 'import x from "express"';`,
  'Array.from': `const a = Array.from("abc");`,
  'from プロパティ': `const o = { from: "x" };`,
};

function importProblems(src) {
  const { specifiers, problems } = findImports(src);
  return [...problems, ...specifiers.filter((s) => !isAllowedSpecifier(s)).map((s) => `許可外: ${s}`)];
}

test('[deps 自己診断] 許可外の import / 動的 import / require を必ず検出する', () => {
  for (const [name, src] of Object.entries(IMPORT_BAD)) {
    assert.ok(importProblems(src).length > 0, `検知漏れ: ${name}`);
  }
});

test('[deps 自己診断] node:・相対パス・コメント/文字列内の字面は誤検出しない', () => {
  for (const [name, src] of Object.entries(IMPORT_GOOD)) {
    assert.deepEqual(importProblems(src), [], `誤検出: ${name}`);
  }
});

// ---------- 実ソース ----------

test('[SQL] server/ に validate / derive / store / server の 4 モジュールがある（検査対象が空では PASS させない）', () => {
  const names = serverSources().map((p) => p.split('/').pop());
  for (const m of ['validate.mjs', 'derive.mjs', 'store.mjs', 'server.mjs']) assert.ok(names.includes(m), `${m} が無い`);
});

test('[SQL] server/ 全ソースに、SQL への動的な値の混入（prepare(`…${…}` 形・連結）が無い', () => {
  const files = serverSources();
  assert.ok(files.length >= 4, `検査対象が少なすぎる: ${files.length}`);
  for (const f of files) {
    assert.deepEqual(findSqlInjectionRisks(readFileSync(f, 'utf8')), [], f);
  }
});

test('[SQL] store.mjs は prepare を実際に使っている（プレースホルダ付きプリペアドステートメントの存在確認）', () => {
  const store = join(SERVER_DIR, 'store.mjs');
  assert.ok(existsSync(store), 'store.mjs が無い');
  const src = readFileSync(store, 'utf8');
  assert.match(src, /\.prepare\(/);
  assert.match(src, /\?|\$\w+|:\w+/, 'プレースホルダ（? / $name / :name）が1つも無い');
});

test('[deps] .claude/monitor 配下の全 .mjs の import 指定子は node: か相対パスのみ（動的 import・require 含む）', () => {
  const files = allSources();
  assert.ok(files.length >= 10, `検査対象が少なすぎる: ${files.length}（サーバ実装が無い）`);
  assert.ok(files.some((f) => f.startsWith(SERVER_DIR)), 'server/ の .mjs が検査対象に入っていない');
  for (const f of files) {
    assert.deepEqual(importProblems(readFileSync(f, 'utf8')), [], f);
  }
});

test('[deps] package.json があれば dependencies / devDependencies 等が空。node_modules が無い', () => {
  assert.ok(!existsSync(join(MONITOR_DIR, 'node_modules')), 'node_modules がある＝依存ゼロでない');
  for (const pj of listFiles(MONITOR_DIR, (n) => n === 'package.json', ['node_modules'])) {
    const json = JSON.parse(readFileSync(pj, 'utf8'));
    for (const key of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies', 'bundledDependencies']) {
      const v = json[key];
      const empty = v === undefined || (Array.isArray(v) ? v.length === 0 : Object.keys(v).length === 0);
      assert.ok(empty, `${pj} の ${key} が空でない`);
    }
  }
});
