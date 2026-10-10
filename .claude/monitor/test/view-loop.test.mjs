// ビューのループ状態パネル（Issue #22 / Red）。DOM に触れない部分と、静的ファイルの構造を固定する。
//
// ════════════════════════════════════════════════════════════════════════════
//  Coder への契約
// ════════════════════════════════════════════════════════════════════════════
//  public/app.js が export する（document / fetch / EventSource をトップレベルで参照しない）:
//    formatLoopPanel(loop, nowMs) -> {
//      state: 'running'|'halted'|'completed'|'unknown', stateLabel, className, issue, retryText,
//      gates: [{ gate: 'G1'..'G5', label }], elapsedText, haltReason }
//    state     : loop.status が running|halted|completed ならそれ。それ以外・不正な入力は全て 'unknown'（例外を投げない）
//    stateLabel: 稼働中 / ハードストップ / 完了 / 不明（<理由の日本語>）。symlink は '不明（リンク）'。未知の reason は原文を出さない
//    className : 'loop-running' | 'loop-halted' | 'loop-completed' | 'loop-unknown' の固定の許可リストからだけ選ぶ
//    retryText : `${retry} / ${limits.max_retry}`（例 '1 / 3'）
//    gates     : 常に G1..G5 の 5 要素（この順）。label は pass=✅ / fail=❌ / 無い=未実行
//    elapsedText: started_at から nowMs までの壁時計の分（切り捨て・0 未満は 0）と上限。'壁時計 12分 / 上限 180分'
//    haltReason: halted の時の halt_reason（無ければ ''）。running / completed では ''
//    不明の時: issue・retryText・elapsedText・haltReason は ''（または null）、gates は []（空配列）
//  public/index.html: #loop-section（data-testid="loop-section"）と #loop-panel（data-testid="loop-panel"）を
//    セッション一覧（#sessions-section）より上に置く。注記（ハードストップの判定は起きていた時間で数える…）を静的に持つ
//  public/style.css: .loop-running / .loop-halted / .loop-completed / .loop-unknown。.loop-halted は赤系
//  public/app.js: EventSource の 'loop' イベントで api/state を再取得（既存の 1 秒の間引きを共用）。DOM シンクを使わない
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（public/ の隔離コピーに左の変異を入れ、このファイルを node --test で走らせると右が FAIL するべき）
// ════════════════════════════════════════════════════════════════════════════
//   「不明」への倒しを外す（不正な入力で例外 / running 扱い）  [unknown] null・配列・__proto__・status 列挙外・欠落
//   不明の時に issue / retry / ゲートを出す                    [unknown] 隠す
//   (a) status の許可リスト検査 Object.hasOwn(LOOP_STATES, status) を外す（常に true）
//                                                               [unknown] 必須を全部揃えても status=constructor / toString / __proto__ / hasOwnProperty / RUNNING / unknown / ""
//   必須項目の型・範囲の検査を外す（issue・retry・max_retry・max_minutes・started_at）  [unknown] 他の項目が正しくても必須 ... なら unknown
//   gate の result を pass / fail の完全一致で見ない              [gates] result がプロトタイプ名・大文字・空・制御文字付きでも未実行
//   未知の reason / status を className や label に写す         [class] 許可リスト・[unknown] 原文を出さない
//   className を status から組み立てる（`loop-${status}`）      [class] 敵対的な status が許可リストの外に出ない
//   halted を赤にしない / halted でも running の className      [state] halted の className・[css] .loop-halted が赤系
//   ゲート label を取り違える / G1..G5 以外を出す / 順序が崩れる [gates]
//   elapsedText の単位・切り捨て・上限の取り違え                 [elapsed]
//   注記を外す                                                  [html] 注記
//   #loop-section をセッション一覧の下に置く                     [html] 順序
//   loop イベントを購読しない / 毎回即時に再取得する             [source] addEventListener('loop')・間引きの共用
//   innerHTML 等を使う                                          view-source.test.mjs の [sink]（新しいコードにもそのまま効く）

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { MONITOR_DIR } from './helpers.mjs';

const PUBLIC_DIR = join(MONITOR_DIR, 'public');
const read = (f) => readFileSync(join(PUBLIC_DIR, f), 'utf8');
const app = () => import('../public/app.js');
const NOW = Date.parse('2026-10-10T05:26:26Z');
// 第 2 引数を省略した時だけ NOW。undefined を明示して渡せば undefined のまま formatLoopPanel に届く
const fmt = async (...args) => (await app()).formatLoopPanel(args[0], args.length >= 2 ? args[1] : NOW);

const CLASSES = ['loop-running', 'loop-halted', 'loop-completed', 'loop-unknown'];
const running = (over = {}) => ({
  status: 'running', issue: '22', branch: 'feat/22-x', epic: 'ai-monitor', retry: 1,
  limits: { max_retry: 3, max_minutes: 180, max_same_gate_fail: 2 },
  gates: { G1: { result: 'pass' }, G2: { result: 'fail' } },
  halt_reason: null, started_at: '2026-10-10T05:14:26Z', ...over,
});

test('[import] app.js が formatLoopPanel を export する', async () => {
  assert.equal(typeof (await app()).formatLoopPanel, 'function');
});

// ---------- [state] ----------

test('[state] running: 稼働中・loop-running・issue・retryText "1 / 3"', async () => {
  const r = await fmt(running());
  assert.equal(r.state, 'running');
  assert.equal(r.stateLabel, '稼働中');
  assert.equal(r.className, 'loop-running');
  assert.ok(String(r.issue).includes('22'));
  assert.equal(r.retryText, '1 / 3');
  assert.equal(r.haltReason, '');
});

test('[state] halted: ハードストップ・loop-halted・haltReason を原文で返す', async () => {
  const r = await fmt(running({ status: 'halted', halt_reason: 'リトライ上限に到達（3/3 回）<b>' }));
  assert.equal(r.state, 'halted');
  assert.equal(r.stateLabel, 'ハードストップ');
  assert.equal(r.className, 'loop-halted');
  assert.equal(r.haltReason, 'リトライ上限に到達（3/3 回）<b>'); // 描画は textContent。エスケープして返さない
});

test('[state] halted で halt_reason が null なら haltReason は ""', async () => {
  assert.equal((await fmt(running({ status: 'halted', halt_reason: null }))).haltReason, '');
});

test('[state] completed: 完了・loop-completed・haltReason は ""', async () => {
  const r = await fmt(running({ status: 'completed', halt_reason: 'stale' }));
  assert.equal(r.state, 'completed');
  assert.equal(r.stateLabel, '完了');
  assert.equal(r.className, 'loop-completed');
  assert.equal(r.haltReason, '');
});

test('[state] retryText は retry と max_retry の値に従う（0 / 3・3 / 3・2 / 5）', async () => {
  assert.equal((await fmt(running({ retry: 0 }))).retryText, '0 / 3');
  assert.equal((await fmt(running({ retry: 3 }))).retryText, '3 / 3');
  assert.equal((await fmt(running({ retry: 2, limits: { max_retry: 5, max_minutes: 60, max_same_gate_fail: 2 } }))).retryText, '2 / 5');
});

// ---------- [gates] ----------

test('[gates] 常に G1..G5 の 5 要素がこの順で並び、pass=✅ / fail=❌ / 無い=未実行', async () => {
  const r = await fmt(running({ gates: { G1: { result: 'pass' }, G3: { result: 'fail' } } }));
  assert.deepEqual(r.gates, [
    { gate: 'G1', label: '✅' }, { gate: 'G2', label: '未実行' }, { gate: 'G3', label: '❌' },
    { gate: 'G4', label: '未実行' }, { gate: 'G5', label: '未実行' },
  ]);
});

test('[gates] gates が空でも 5 要素すべて未実行', async () => {
  const r = await fmt(running({ gates: {} }));
  assert.deepEqual(r.gates.map((g) => g.label), ['未実行', '未実行', '未実行', '未実行', '未実行']);
});

test('[gates] G6 や不正な result は表に出ない（5 要素のまま・未実行）', async () => {
  const r = await fmt(running({ gates: { G6: { result: 'pass' }, G1: { result: '<img>' }, G2: null } }));
  assert.deepEqual(r.gates.map((g) => g.gate), ['G1', 'G2', 'G3', 'G4', 'G5']);
  assert.deepEqual(r.gates.map((g) => g.label), ['未実行', '未実行', '未実行', '未実行', '未実行']);
});

test('[gates] result がプロトタイプ名・大文字・空・制御文字付きでも他が正しければ未実行（pass / fail だけが印になる）', async () => {
  for (const result of ['constructor', 'toString', '__proto__', 'PASS', 'FAIL', '', 'pass\n', ' pass', 1, true, null, {}]) {
    const r = await fmt(running({ gates: { G1: { result }, G2: { result: 'pass' } } }));
    assert.equal(r.state, 'running');
    assert.deepEqual(r.gates.map((g) => g.label), ['未実行', '✅', '未実行', '未実行', '未実行'], JSON.stringify(result));
  }
});

test('[gates] gates が無い・null でも 5 要素の未実行（例外を出さない）', async () => {
  const r = await fmt(running({ gates: undefined }));
  assert.equal(r.gates.length, 5);
});

// ---------- [elapsed] ----------

test('[elapsed] started_at から nowMs までの壁時計と上限: "壁時計 12分 / 上限 180分"', async () => {
  const r = await fmt(running(), Date.parse('2026-10-10T05:26:26Z'));
  assert.equal(r.elapsedText, '壁時計 12分 / 上限 180分');
});

test('[elapsed] 分は切り捨て（12分59秒 -> 12分）', async () => {
  const r = await fmt(running(), Date.parse('2026-10-10T05:27:25Z'));
  assert.equal(r.elapsedText, '壁時計 12分 / 上限 180分');
});

test('[elapsed] 開始直後は 0分。時計が戻っている（now < started_at）場合も 0分（負にしない）', async () => {
  assert.equal((await fmt(running(), Date.parse('2026-10-10T05:14:26Z'))).elapsedText, '壁時計 0分 / 上限 180分');
  assert.equal((await fmt(running(), Date.parse('2026-10-10T04:00:00Z'))).elapsedText, '壁時計 0分 / 上限 180分');
});

test('[elapsed] 上限は limits.max_minutes に従う', async () => {
  const r = await fmt(running({ limits: { max_retry: 3, max_minutes: 60, max_same_gate_fail: 2 } }), Date.parse('2026-10-10T06:14:26Z'));
  assert.equal(r.elapsedText, '壁時計 60分 / 上限 60分');
});

test('[elapsed] nowMs が数値でない（NaN・undefined）でも例外を出さず、文字列を返す', async () => {
  for (const now of [NaN, undefined, null, 'x']) {
    const r = await fmt(running(), now);
    assert.equal(typeof r.elapsedText, 'string');
    assert.equal(r.state, 'running');
  }
});

test('[elapsed] halted と completed は経過時間を出さない（elapsedText は ""）', async () => {
  for (const status of ['halted', 'completed']) {
    const r = await fmt(running({ status, halt_reason: 'x' }), Date.parse('2026-10-10T05:26:26Z'));
    assert.equal(r.state, status);
    assert.equal(r.elapsedText, '', status);
  }
});

test('[elapsed] running は従来どおり壁時計の分数を出す', async () => {
  assert.equal((await fmt(running(), Date.parse('2026-10-10T05:26:26Z'))).elapsedText, '壁時計 12分 / 上限 180分');
});

test('[elapsed] nowMs が数値でない・有限でない時は "0分" と出さず "" にする', async () => {
  for (const now of [undefined, NaN, null, 'x', Infinity, {}]) {
    const r = await fmt(running(), now);
    assert.equal(r.state, 'running');
    assert.equal(r.elapsedText, '', `nowMs=${String(now)}`);
    assert.ok(!r.elapsedText.includes('0分'));
  }
});

test('[unknown] started_at が Date.parse で NaN になる文字列なら unknown（running として描かない）', async () => {
  for (const started_at of ['2026-13-45T25:61:61Z', '2026-02-30T99:00:00Z', 'not a date', '']) {
    assert.ok(Number.isNaN(Date.parse(started_at)), `前提: ${started_at}`);
    const r = await fmt(running({ started_at }));
    assert.equal(r.state, 'unknown', started_at);
    assert.equal(r.className, 'loop-unknown');
    assert.deepEqual(r.gates, []);
  }
});

test('[source] app.js のクライアントは started_at を正規表現で二重検証しない（Date.parse の NaN 判定だけ）', () => {
  const js = read('app.js');
  assert.ok(!js.includes('ISO_SECOND_PATTERN'));
  assert.ok(js.includes('Date.parse'));
});

// ---------- [unknown] ----------

test('[unknown] symlink: 不明（リンク）・loop-unknown。issue / retry / gates / 経過 / 理由を出さない', async () => {
  const r = await fmt({ status: 'unknown', reason: 'symlink' });
  assert.equal(r.state, 'unknown');
  assert.equal(r.stateLabel, '不明（リンク）');
  assert.equal(r.className, 'loop-unknown');
  for (const k of ['issue', 'retryText', 'elapsedText', 'haltReason']) assert.ok(r[k] === '' || r[k] === null, `${k} が隠れていない: ${JSON.stringify(r[k])}`);
  assert.deepEqual(r.gates, []);
});

test('[unknown] reason 8 種すべてが「不明（…）」で、日本語の理由が付き、reason の英語原文は出さない', async () => {
  const reasons = ['missing', 'symlink', 'not_file', 'too_large', 'empty', 'invalid_json', 'invalid_shape', 'read_error'];
  const labels = new Set();
  for (const reason of reasons) {
    const r = await fmt({ status: 'unknown', reason });
    assert.match(r.stateLabel, /^不明（.+）$/, reason);
    assert.ok(!r.stateLabel.includes(reason), `${reason} の原文が出ている: ${r.stateLabel}`);
    assert.equal(r.className, 'loop-unknown');
    labels.add(r.stateLabel);
  }
  assert.equal(labels.size, reasons.length, '理由ごとにラベルが区別できない');
});

test('[unknown] 未知の reason は原文を出さず「不明」のまま（XSS 文字列・長い文字列）', async () => {
  for (const reason of ['<img src=x onerror=alert(1)>', 'x'.repeat(500), undefined, null, 5, {}]) {
    const r = await fmt({ status: 'unknown', reason });
    assert.equal(r.state, 'unknown');
    assert.match(r.stateLabel, /^不明/);
    assert.ok(!r.stateLabel.includes('<img'));
    assert.ok(r.stateLabel.length < 40);
    assert.equal(r.className, 'loop-unknown');
  }
});

test('[unknown] 不明の時に loop に issue などが紛れていても出さない', async () => {
  const r = await fmt({ status: 'unknown', reason: 'missing', issue: '22', retry: 1, gates: { G1: { result: 'pass' } }, halt_reason: 'x' });
  assert.equal(r.state, 'unknown');
  assert.ok(r.issue === '' || r.issue === null);
  assert.deepEqual(r.gates, []);
  assert.ok(r.haltReason === '' || r.haltReason === null);
});

const BAD_INPUTS = {
  null: null, undefined, 配列: [], '配列に状態': [running()], 文字列: 'running', 数値: 1, 真偽値: true, 関数: () => {},
  空オブジェクト: {}, 'status 欠落': { issue: '22', retry: 0 }, 'status 列挙外': { status: 'RUNNING' },
  'status=<script>': { status: '<script>alert(1)</script>' }, 'status=数値': { status: 1 },
  'status=constructor': { status: 'constructor' }, 'status=__proto__': { status: '__proto__' },
  'status=toString': { status: 'toString' },
  'JSON の __proto__ キー': JSON.parse('{"__proto__":{"status":"running"}}'),
  'JSON の __proto__ に reason': JSON.parse('{"__proto__":{"status":"unknown","reason":"symlink"}}'),
};
for (const [name, input] of Object.entries(BAD_INPUTS)) {
  test(`[unknown] 不正な入力 ${name} は例外を出さず unknown 扱い`, async () => {
    const m = await app();
    let r;
    assert.doesNotThrow(() => { r = m.formatLoopPanel(input, 0); });
    assert.equal(r.state, 'unknown');
    assert.equal(r.className, 'loop-unknown');
    assert.match(r.stateLabel, /^不明/);
    assert.deepEqual(r.gates, []);
    assert.ok(r.issue === '' || r.issue === null);
  });
}

test('[unknown] running でも必須が壊れている（retry や limits が無い・型違い）なら running として描かず unknown', async () => {
  for (const over of [{ retry: undefined }, { retry: 'x' }, { limits: undefined }, { limits: { max_retry: 'a' } }, { started_at: undefined }]) {
    const r = await fmt(running(over));
    assert.equal(r.state, 'unknown', JSON.stringify(over));
    assert.equal(r.className, 'loop-unknown');
  }
});

// 他の必須項目をすべて正しく揃えた入力で status だけを壊す。必須欠落という別の経路で弾かれて、許可リスト検査に到達しない形を避ける
const BAD_STATUSES = ['constructor', 'toString', '__proto__', 'hasOwnProperty', 'RUNNING', 'unknown', ''];
for (const status of BAD_STATUSES) {
  test(`[unknown] 必須を全部揃えても status=${JSON.stringify(status)} は許可リストで弾かれ unknown（issue / retry を出さない）`, async () => {
    const input = running({ status });
    for (const k of ['issue', 'retry', 'limits', 'started_at']) assert.ok(Object.hasOwn(input, k), `前提: ${k}`);
    const m = await app();
    let r;
    assert.doesNotThrow(() => { r = m.formatLoopPanel(input, NOW); });
    assert.equal(r.state, 'unknown');
    assert.equal(r.className, 'loop-unknown');
    assert.match(r.stateLabel, /^不明/);
    assert.ok(r.issue === '' || r.issue === null);
    assert.ok(r.retryText === '' || r.retryText === null);
    assert.deepEqual(r.gates, []);
    assert.equal(r.elapsedText, '');
    assert.equal(r.haltReason, '');
  });
}

// 他の項目は正しいまま、必須項目の型・範囲を 1 つずつ壊す
const BAD_REQUIRED = [
  ['issue=数値', { issue: 22 }], ['issue=null', { issue: null }],
  ['retry=文字列 "1"', { retry: '1' }], ['retry=負数', { retry: -1 }], ['retry=小数', { retry: 1.5 }],
  ['retry=安全でない整数', { retry: 2 ** 53 }], ['retry=null', { retry: null }],
  ['limits=null', { limits: null }], ['limits=配列', { limits: [3, 180, 2] }],
  ['limits.max_retry=文字列 "3"', { limits: { max_retry: '3', max_minutes: 180, max_same_gate_fail: 2 } }],
  ['limits.max_retry=負数', { limits: { max_retry: -1, max_minutes: 180, max_same_gate_fail: 2 } }],
  ['limits.max_retry=小数', { limits: { max_retry: 1.5, max_minutes: 180, max_same_gate_fail: 2 } }],
  ['limits.max_minutes=文字列', { limits: { max_retry: 3, max_minutes: '180', max_same_gate_fail: 2 } }],
  ['limits.max_minutes=負数', { limits: { max_retry: 3, max_minutes: -1, max_same_gate_fail: 2 } }],
  ['started_at=数値 123', { started_at: 123 }], ['started_at=null', { started_at: null }],
];
for (const [name, over] of BAD_REQUIRED) {
  test(`[unknown] 他の項目が正しくても必須 ${name} なら unknown`, async () => {
    for (const status of ['running', 'halted', 'completed']) {
      const r = await fmt(running({ status, ...over }));
      assert.equal(r.state, 'unknown', `${status}: ${name}`);
      assert.equal(r.className, 'loop-unknown');
      assert.ok(r.issue === '' || r.issue === null);
      assert.ok(r.retryText === '' || r.retryText === null);
      assert.deepEqual(r.gates, []);
    }
  });
}

test('[unknown] 入力を書き換えない', async () => {
  const input = running();
  const copy = JSON.parse(JSON.stringify(input));
  await fmt(input);
  assert.deepEqual(input, copy);
});

// ---------- [class] ----------

test('[class] className は常に許可リスト 4 つのどれか（全 status と敵対的な入力）', async () => {
  const inputs = [running(), running({ status: 'halted' }), running({ status: 'completed' }), { status: 'unknown', reason: 'missing' },
    { status: 'x y' }, { status: 'loop-halted' }, { status: 'running loop-halted' }, null, []];
  for (const i of inputs) assert.ok(CLASSES.includes((await fmt(i)).className), JSON.stringify(i));
});

test('[class] status 以外の値（branch・halt_reason など）は className に影響しない', async () => {
  const r = await fmt(running({ branch: 'loop-halted', halt_reason: 'loop-halted', epic: 'x" onclick="y' }));
  assert.equal(r.className, 'loop-running');
});

test('[class] 4 状態の className は互いに異なる', async () => {
  const set = new Set([
    (await fmt(running())).className, (await fmt(running({ status: 'halted' }))).className,
    (await fmt(running({ status: 'completed' }))).className, (await fmt(null)).className,
  ]);
  assert.equal(set.size, 4);
});

// ---------- [html] ----------

test('[html] index.html に #loop-section（data-testid="loop-section"）と #loop-panel（data-testid="loop-panel"）がある', () => {
  const html = read('index.html');
  assert.match(html, /<section[^>]*id="loop-section"[^>]*>/);
  assert.match(html, /<section[^>]*data-testid="loop-section"[^>]*>/);
  assert.match(html, /id="loop-panel"/);
  assert.match(html, /data-testid="loop-panel"/);
});

test('[html] #loop-section はセッション一覧（#sessions-section）より上にあり、#loop-panel はその中にある', () => {
  const html = read('index.html');
  const loop = html.indexOf('id="loop-section"');
  const panel = html.indexOf('id="loop-panel"');
  const sessions = html.indexOf('id="sessions-section"');
  assert.ok(loop >= 0 && panel >= 0 && sessions >= 0);
  assert.ok(loop < sessions, 'loop-section がセッション一覧より下');
  assert.ok(loop < panel && panel < sessions, 'loop-panel が loop-section の中にない');
});

test('[html] 注記: ハードストップの判定は起きていた時間で数えるため、壁時計の経過より短いことがある', () => {
  const html = read('index.html');
  assert.match(html, /ハードストップの判定は起きていた時間で数える/);
  assert.match(html, /壁時計の経過より短い/);
});

// ---------- [css] ----------

function cssBlock(css, selector) {
  const i = css.indexOf(selector);
  if (i < 0) return null;
  const open = css.indexOf('{', i);
  const close = css.indexOf('}', open);
  return open >= 0 && close > open ? css.slice(open + 1, close) : null;
}

// 色の定義は既存の :root（ライト）と @media dark の :root に統合する。接頭辞は --loop-{ok,halt,done,unk}- の 4 種類だけ。var() の fallback は付けない。
const LOOP_VAR_PREFIXES = ['ok', 'halt', 'done', 'unk'];
const rootBlocks = (css) => {
  const dark = css.indexOf('@media (prefers-color-scheme: dark)');
  const light = css.indexOf(':root');
  assert.ok(light >= 0 && dark >= 0 && light < dark, 'ライトの :root がダークの @media より前に無い');
  const darkRoot = css.indexOf(':root', dark);
  return { light: cssBlock(css, ':root'), dark: cssBlock(css.slice(darkRoot), ':root') };
};
const hexOf = (block, name) => {
  const m = block.match(new RegExp(`${name}\\s*:\\s*#([0-9a-f]{6}|[0-9a-f]{3})\\b`, 'i'));
  if (!m) return null;
  const h = m[1].length === 3 ? [...m[1]].map((c) => c + c).join('') : m[1];
  return [0, 2, 4].map((o) => parseInt(h.slice(o, o + 2), 16));
};
// 赤系: R が十分大きく、G・B より 0x40 以上大きい（ダークの淡い赤 #ffb4ab も含む）
const isReddish = ([r, g, b]) => r >= 0xb0 && r - g >= 0x40 && r - b >= 0x40;

test('[css] style.css に 4 つのクラスがあり、.loop-halted は --loop-halt-* 変数を参照する（hex を直書きしない）', () => {
  const css = read('style.css');
  for (const c of CLASSES) assert.ok(css.includes(`.${c}`), `.${c} が無い`);
  const halted = cssBlock(css, '.loop-halted');
  assert.ok(halted, '.loop-halted のブロックが無い');
  assert.match(halted, /var\(\s*--loop-halt-[a-z]+\s*\)/, '.loop-halted が --loop-halt-* を参照していない');
  assert.ok(!/#[0-9a-f]{3,8}\b/i.test(halted), `.loop-halted に hex の直書きがある: ${halted.trim().slice(0, 120)}`);
});

test('[css] --loop-halt-fg / --loop-halt-border はライトとダーク両方の :root で赤系、--loop-halt-bg も両方で定義される', () => {
  const { light, dark } = rootBlocks(read('style.css'));
  for (const [theme, block] of [['light', light], ['dark', dark]]) {
    assert.ok(block, `${theme} の :root が無い`);
    for (const name of ['--loop-halt-fg', '--loop-halt-border']) {
      const rgb = hexOf(block, name);
      assert.ok(rgb, `${theme}: ${name} が hex で定義されていない`);
      assert.ok(isReddish(rgb), `${theme}: ${name} が赤系でない: ${rgb}`);
    }
    assert.ok(hexOf(block, '--loop-halt-bg'), `${theme}: --loop-halt-bg が定義されていない`);
  }
});

test('[css] 他の状態の変数（ok / done / unk）もライトとダーク両方の :root で定義される', () => {
  const { light, dark } = rootBlocks(read('style.css'));
  for (const name of ['--loop-ok-fg', '--loop-ok-bg', '--loop-done-fg', '--loop-unk-fg']) {
    assert.ok(hexOf(light, name), `light: ${name} が無い`);
    assert.ok(hexOf(dark, name), `dark: ${name} が無い`);
  }
});

test('[css] ループ用の変数の接頭辞は --loop-ok- / --loop-halt- / --loop-done- / --loop-unk- だけ（旧 --halt-* を残さない）', () => {
  const css = read('style.css');
  const defined = [...css.matchAll(/(--[a-z0-9-]+)\s*:/gi)].map((m) => m[1]);
  const loopish = defined.filter((n) => /^--(loop|halt)/.test(n));
  assert.ok(loopish.length >= 5, `ループ用の変数が少なすぎる: ${loopish}`);
  const ok = new RegExp(`^--loop-(${LOOP_VAR_PREFIXES.join('|')})-[a-z]+$`);
  for (const n of loopish) assert.match(n, ok, `接頭辞が許可外: ${n}`);
  for (const n of css.matchAll(/var\(\s*(--[a-z0-9-]+)/gi)) {
    if (/^--(loop|halt)/.test(n[1])) assert.match(n[1], ok, `参照が許可外: ${n[1]}`);
  }
});

test('[css] ループ用の :root は既存の 2 つ（ライトと dark の @media）に統合され、追加の :root ブロックが無い', () => {
  assert.equal((read('style.css').match(/:root\s*\{/g) ?? []).length, 2);
});

test('[css] ループのルールに var() の fallback（var(--x, ...) 形）が無い', () => {
  const css = read('style.css');
  assert.ok(!/var\(\s*--loop-[a-z-]+\s*,/i.test(css), '--loop-* の fallback がある');
  const rules = [...css.matchAll(/([^{}]*loop[^{}]*)\{([^{}]*)\}/g)];
  assert.ok(rules.length >= 8, `loop のルールが少なすぎる: ${rules.length}`);
  for (const [, sel, body] of rules) assert.ok(!/var\([^)]*,/.test(body), `fallback がある: ${sel.trim()}`);
});

test('[css] .loop-unknown は .loop-halted と見分けがつく（同じブロックでない）', () => {
  const css = read('style.css');
  const a = cssBlock(css, '.loop-halted');
  const b = cssBlock(css, '.loop-unknown');
  assert.ok(a && b);
  assert.notEqual(a.replace(/\s+/g, ''), b.replace(/\s+/g, ''));
});

// ---------- [source] ----------

test('[source] app.js は EventSource の loop イベントを購読し、api/state を再取得する（既存の間引きを共用）', () => {
  const js = read('app.js');
  assert.match(js, /addEventListener\(\s*['"]loop['"]/);
  assert.ok(js.includes('formatLoopPanel'));
  assert.ok(js.includes('loop-panel'), 'app.js が #loop-panel を参照していない');
  assert.equal((js.match(/STATE_REFRESH_MIN_INTERVAL_MS\s*=/g) ?? []).length, 1, '間引きの定数が複数ある（共用していない）');
});

test('[source] app.js の loop 描画は textContent 経由（innerHTML 等のシンクが無い）。view-source.test.mjs の全文検査と二重に見る', () => {
  const js = read('app.js');
  assert.ok(js.includes('formatLoopPanel'));
  for (const sink of ['innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'eval(', 'new Function']) {
    assert.ok(!js.includes(sink), `${sink} がある`);
  }
});
