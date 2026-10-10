// 監視ビュー。純関数（DOM 非依存）を export し、DOM 起動は document がある時だけ行う。
// 描画は createElement + textContent のみ。外部由来の値（file_path・bash_command・agent_type 等）の行き先は textContent だけで、
// class 名・属性には入れない（状態は固定の許可リストで class に写す）。

export const MAX_TIMELINE_EVENTS = 500;
export const MAX_AGENT_NAME_LENGTH = 64;
export const SESSION_ID_SHORT_LENGTH = 8;
const STATE_REFRESH_MIN_INTERVAL_MS = 1000;
// style.css の .depth-0..N の N と一致させる（数を変えたら両方直す）
const MAX_TREE_DEPTH_CLASS = 5;
const UNKNOWN_AGENT = 'unknown';
const MAIN_AGENT_NAME = 'Tech Lead';

const ROLE_NAMES = Object.freeze({
  main: MAIN_AGENT_NAME,
  'sub-agent-planner': 'Planner',
  'sub-agent-qa': 'QA',
  'sub-agent-architect': 'Architect',
  'sub-agent-coder': 'Coder',
  'sub-agent-designer': 'Designer',
  'sub-agent-evaluator': 'Evaluator',
  'sub-agent-tester': 'Tester',
  'sub-agent-spec-reviewer': 'Spec Reviewer',
  'sub-agent-code-reviewer': 'Code Reviewer',
  'sub-agent-security-reviewer': 'Security Reviewer',
});

const STATUS_LABELS = Object.freeze({
  running: '稼働中',
  waiting: '待機',
  done: '完了',
  ended: '終了',
});
const UNKNOWN_STATUS_LABEL = '不明';
const NO_TIME = '--:--:--';

const asString = (value) => (typeof value === 'string' ? value : '');

/** @param {unknown} agentType @param {number} [maxLength] */
export function agentDisplayName(agentType, maxLength = MAX_AGENT_NAME_LENGTH) {
  if (typeof agentType !== 'string' || agentType === '') return UNKNOWN_AGENT;
  if (Object.hasOwn(ROLE_NAMES, agentType)) return ROLE_NAMES[agentType];
  const chars = [...agentType];
  return chars.length > maxLength ? `${chars.slice(0, maxLength - 1).join('')}…` : agentType;
}

const isKnownStatus = (status) => typeof status === 'string' && Object.hasOwn(STATUS_LABELS, status);

/** @param {unknown} status */
export function statusLabel(status) {
  return isKnownStatus(status) ? STATUS_LABELS[status] : UNKNOWN_STATUS_LABEL;
}

/** class 名に使う状態。許可リストにある値だけを通し、外部値は決して class に入れない */
function statusClass(status) {
  return `status-${isKnownStatus(status) ? status : 'unknown'}`;
}

/** @param {unknown} sessionId */
export function shortSessionId(sessionId) {
  return typeof sessionId === 'string' ? sessionId.slice(0, SESSION_ID_SHORT_LENGTH) : '';
}

/**
 * UTC の HH:MM:SS に整形する。有限の数値でなければ NO_TIME。
 * @param {unknown} epochMs
 */
export function formatTime(epochMs) {
  if (typeof epochMs !== 'number' || !Number.isFinite(epochMs)) return NO_TIME;
  const date = new Date(epochMs);
  return Number.isNaN(date.getTime()) ? NO_TIME : date.toISOString().slice(11, 19);
}

/** @template T @param {T[]} events @param {T} record @param {number} [limit] */
export function appendTimeline(events, record, limit = MAX_TIMELINE_EVENTS) {
  const next = [...events, record];
  return next.slice(Math.max(0, next.length - limit));
}

/** @param {Record<string, unknown>} record */
export function formatEventRow(record) {
  const hasAgent = record.agent_id !== undefined && record.agent_id !== null;
  return {
    time: formatTime(record.received_at),
    session: shortSessionId(record.session_id),
    agent: hasAgent ? agentDisplayName(record.agent_type) : MAIN_AGENT_NAME,
    event: asString(record.event),
    tool: asString(record.tool_name),
    detail: asString(record.file_path) || asString(record.bash_command),
  };
}

/** @param {Record<string, unknown>} session */
export function formatSessionRow(session) {
  return {
    session: shortSessionId(session.session_id),
    status: asString(session.status),
    statusLabel: statusLabel(session.status),
    lastSeen: formatTime(session.last_received_at),
  };
}

/** @param {Record<string, unknown>} tree */
export function flattenAgentTree(tree, depth = 0) {
  const tools = Array.isArray(tree.running_tools) ? tree.running_tools.map((t) => asString(t?.tool_name)) : [];
  const rows = [{
    depth,
    agent_id: tree.agent_id,
    name: agentDisplayName(tree.agent_type),
    status: tree.status,
    statusLabel: statusLabel(tree.status),
    tools,
    usage: formatUsage(tree.usage),
  }];
  if (Array.isArray(tree.children)) {
    for (const child of tree.children) rows.push(...flattenAgentTree(child, depth + 1));
  }
  return rows;
}

// ---------- ループ状態パネル ----------

const LOOP_GATES = Object.freeze(['G1', 'G2', 'G3', 'G4', 'G5']);
const GATE_LABELS = Object.freeze({ pass: '✅', fail: '❌' });
const GATE_NOT_RUN = '未実行';
// className は status から組み立てず、固定の許可リストからだけ選ぶ
const LOOP_STATES = Object.freeze({
  running: { label: '稼働中', className: 'loop-running' },
  halted: { label: 'ハードストップ', className: 'loop-halted' },
  completed: { label: '完了', className: 'loop-completed' },
});
const LOOP_UNKNOWN_CLASS = 'loop-unknown';
const LOOP_UNKNOWN_REASONS = Object.freeze({
  missing: '状態ファイルなし',
  symlink: 'リンク',
  not_file: '通常ファイルでない',
  too_large: 'サイズ超過',
  empty: '空',
  invalid_json: 'JSON不正',
  invalid_shape: '形式不正',
  read_error: '読み取り失敗',
});
const MS_PER_MINUTE = 60_000;

const ownObject = (object, key) => (Object.hasOwn(object, key) && object[key] !== null && typeof object[key] === 'object' ? object[key] : null);
const ownString = (object, key) => (Object.hasOwn(object, key) && typeof object[key] === 'string' ? object[key] : null);
const ownCount = (object, key) => (Object.hasOwn(object, key) && Number.isSafeInteger(object[key]) && object[key] >= 0 ? object[key] : null);

function unknownLoopPanel(reason) {
  const detail = typeof reason === 'string' && Object.hasOwn(LOOP_UNKNOWN_REASONS, reason) ? LOOP_UNKNOWN_REASONS[reason] : null;
  return {
    state: 'unknown',
    stateLabel: detail === null ? UNKNOWN_STATUS_LABEL : `${UNKNOWN_STATUS_LABEL}（${detail}）`,
    className: LOOP_UNKNOWN_CLASS,
    issue: '',
    retryText: '',
    gates: [],
    elapsedText: '',
    haltReason: '',
  };
}

/**
 * /api/state の loop を表示用に整える。判定できない入力は全て unknown に倒す（例外を投げない・入力を書き換えない）。
 * @param {unknown} loop @param {unknown} nowMs
 */
export function formatLoopPanel(loop, nowMs) {
  if (loop === null || typeof loop !== 'object' || Array.isArray(loop)) return unknownLoopPanel(undefined);
  const status = ownString(loop, 'status');
  if (status === 'unknown') return unknownLoopPanel(ownString(loop, 'reason'));
  const issue = ownString(loop, 'issue');
  const retry = ownCount(loop, 'retry');
  const limits = ownObject(loop, 'limits') ?? {};
  const maxRetry = ownCount(limits, 'max_retry');
  const maxMinutes = ownCount(limits, 'max_minutes');
  const startedAt = ownString(loop, 'started_at');
  const required = [issue, retry, maxRetry, maxMinutes, startedAt];
  if (status === null || !Object.hasOwn(LOOP_STATES, status) || required.some((v) => v === null) || Number.isNaN(Date.parse(startedAt))) {
    return unknownLoopPanel(undefined);
  }
  const gates = ownObject(loop, 'gates') ?? {};
  const elapsedMs = nowMs - Date.parse(startedAt);
  const showElapsed = status === 'running' && Number.isFinite(nowMs) && Number.isFinite(elapsedMs);
  return {
    state: status,
    stateLabel: LOOP_STATES[status].label,
    className: LOOP_STATES[status].className,
    issue,
    retryText: `${retry} / ${maxRetry}`,
    gates: LOOP_GATES.map((gate) => {
      const result = ownObject(gates, gate)?.result;
      return { gate, label: result === 'pass' || result === 'fail' ? GATE_LABELS[result] : GATE_NOT_RUN };
    }),
    elapsedText: showElapsed ? `壁時計 ${Math.max(0, Math.floor(elapsedMs / MS_PER_MINUTE))}分 / 上限 ${maxMinutes}分` : '',
    haltReason: status === 'halted' ? (ownString(loop, 'halt_reason') ?? '') : '',
  };
}

// ---------- トークン数・推定コスト ----------

const MICRO_USD_PER_USD = 1_000_000;
const MICRO_USD_PER_DISPLAY_UNIT = 100; // 表示は小数 4 桁（1e-4 ドル単位）
const DISPLAY_UNITS_PER_USD = MICRO_USD_PER_USD / MICRO_USD_PER_DISPLAY_UNIT;
const USAGE_STATES = Object.freeze({
  known: 'usage-known',
  lower_bound: 'usage-lower-bound',
  unknown: 'usage-unknown',
  none: 'usage-none',
});
const USAGE_UNKNOWN_TEXT = '不明';
const USAGE_TOKEN_KEYS = Object.freeze(['input', 'output', 'cache_creation', 'cache_read']);

const isRecord = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const ownRecord = (object, key) => (Object.hasOwn(object, key) && isRecord(object[key]) ? object[key] : null);
const withCommas = (count) => String(count).replace(/\B(?=(\d{3})+(?!\d))/g, ',');

function usageResult(state, costText = '', tokensText = '') {
  return { state, costText, tokensText, className: USAGE_STATES[state] };
}
const unknownUsage = () => usageResult('unknown', USAGE_UNKNOWN_TEXT);

/** マイクロドル -> '$0.0123'（小数 4 桁・整数部 3 桁区切り）。0 は '$0' */
function formatMicroUsd(microUsd) {
  if (microUsd === 0) return '$0';
  const units = Math.round(microUsd / MICRO_USD_PER_DISPLAY_UNIT);
  const dollars = Math.floor(units / DISPLAY_UNITS_PER_USD);
  const fraction = String(units % DISPLAY_UNITS_PER_USD).padStart(4, '0');
  return `$${withCommas(dollars)}.${fraction}`;
}

function formatTokens(tokens, unknownSnapshots) {
  const values = USAGE_TOKEN_KEYS.map((key) => (isRecord(tokens) ? ownCount(tokens, key) : null));
  if (values.some((v) => v === null) || unknownSnapshots === null) return '';
  const [input, output, cacheCreation, cacheRead] = values.map(withCommas);
  const text = `入力 ${input} / 出力 ${output} / キャッシュ書込 ${cacheCreation} / キャッシュ読取 ${cacheRead}`;
  return unknownSnapshots > 0 ? `${text}（不明なスナップショット ${unknownSnapshots} 件は含まない）` : text;
}

function costResult({ knownMicroUsd, knownCount, unknownCount }, tokensText) {
  if (unknownCount === 0) return usageResult('known', `推定 ${formatMicroUsd(knownMicroUsd)}`, tokensText);
  if (knownCount > 0) return usageResult('lower_bound', `推定 ${formatMicroUsd(knownMicroUsd)} 以上（不明を含む）`, tokensText);
  return usageResult('unknown', USAGE_UNKNOWN_TEXT, tokensText);
}

/**
 * セッションの usage_total を表示用に整える。判定できない入力は「不明」に倒す（例外を投げない）。
 * @param {unknown} usageTotal
 */
export function formatUsageTotal(usageTotal) {
  try {
    if (!isRecord(usageTotal)) return unknownUsage();
    const cost = ownRecord(usageTotal, 'cost');
    if (cost === null) return unknownUsage();
    const knownMicroUsd = ownCount(cost, 'known_micro_usd');
    const knownCount = ownCount(cost, 'known_count');
    const unknownCount = ownCount(cost, 'unknown_count');
    if (knownMicroUsd === null || knownCount === null || unknownCount === null) return unknownUsage();
    const tokensText = formatTokens(ownRecord(usageTotal, 'tokens'), ownCount(usageTotal, 'unknown_snapshots'));
    return costResult({ knownMicroUsd, knownCount, unknownCount }, tokensText);
  } catch {
    return unknownUsage();
  }
}

const MODEL_TOKEN_FIELDS = Object.freeze({
  input: ['input_tokens'],
  output: ['output_tokens'],
  cache_creation: ['cache_creation_5m_input_tokens', 'cache_creation_1h_input_tokens'],
  cache_read: ['cache_read_input_tokens'],
});

/** models の 1 要素を { tokens, cost } にする。形が壊れていれば null */
function readModel(model) {
  if (!isRecord(model)) return null;
  const cost = ownRecord(model, 'cost');
  const status = cost === null ? null : ownString(cost, 'status');
  const microUsd = cost === null ? null : ownCount(cost, 'micro_usd');
  if (status !== 'unknown' && !(status === 'known' && microUsd !== null)) return null;
  const tokens = {};
  for (const [key, fields] of Object.entries(MODEL_TOKEN_FIELDS)) {
    const counts = fields.map((field) => ownCount(model, field));
    if (counts.some((c) => c === null)) return null;
    tokens[key] = counts.reduce((a, b) => a + b, 0);
  }
  return { tokens, microUsd: status === 'known' ? microUsd : null };
}

/**
 * ノード（メイン・サブ）の usage を表示用に整える。不明なモデルを 0 円として足さない。
 * @param {unknown} usage
 */
export function formatUsage(usage) {
  try {
    if (usage === null || usage === undefined) return usageResult('none');
    if (!isRecord(usage)) return unknownUsage();
    const status = ownString(usage, 'status');
    if (status === 'unknown') return unknownUsage();
    if (status !== 'ok' || !Object.hasOwn(usage, 'models') || !Array.isArray(usage.models)) return unknownUsage();
    const models = usage.models.map(readModel);
    if (models.some((m) => m === null)) return unknownUsage();
    const tokens = { input: 0, output: 0, cache_creation: 0, cache_read: 0 };
    const cost = { knownMicroUsd: 0, knownCount: 0, unknownCount: 0 };
    for (const m of models) {
      for (const key of USAGE_TOKEN_KEYS) tokens[key] += m.tokens[key];
      if (m.microUsd === null) {
        cost.unknownCount += 1;
      } else {
        cost.knownMicroUsd += m.microUsd;
        cost.knownCount += 1;
      }
    }
    return costResult(cost, formatTokens(tokens, 0));
  } catch {
    return unknownUsage();
  }
}

// ---------- DOM（document がある時だけ） ----------

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className !== undefined) node.className = className;
  return node;
}

/** cellClasses は列ごとの class（固定の許可リスト由来のみ）。無い列は undefined */
function row(cells, cellClasses = []) {
  const tr = el('tr');
  cells.forEach((text, index) => tr.append(el('td', text, cellClasses[index])));
  return tr;
}

function renderSessions(sessions) {
  const body = document.getElementById('sessions-body');
  body.replaceChildren(...sessions.map((session) => {
    const r = formatSessionRow(session);
    return row([r.session, r.statusLabel, r.lastSeen], [undefined, statusClass(session.status)]);
  }));
  document.getElementById('sessions-empty').hidden = sessions.length > 0;
}

function renderLoop(loop) {
  const panel = formatLoopPanel(loop, Date.now());
  const container = document.getElementById('loop-panel');
  const rows = [el('p', panel.stateLabel, `loop-state ${panel.className}`)];
  if (panel.state !== 'unknown') {
    rows.push(
      el('p', `Issue #${panel.issue}`),
      el('p', `リトライ ${panel.retryText}`),
      el('p', panel.gates.map((g) => `${g.gate} ${g.label}`).join('  ')),
    );
    if (panel.elapsedText !== '') rows.push(el('p', panel.elapsedText));
    if (panel.haltReason !== '') rows.push(el('p', panel.haltReason, 'loop-halt-reason'));
  }
  container.replaceChildren(...rows);
}

/** 金額とトークン数。className は formatUsage / formatUsageTotal が固定の許可リストから返したものだけ */
function usageSpan(usage) {
  const span = el('span', usage.costText, `usage ${usage.className}`);
  if (usage.tokensText !== '') span.append(' ', el('span', usage.tokensText, 'usage-tokens'));
  return span;
}

function renderTrees(sessions) {
  const container = document.getElementById('trees');
  container.replaceChildren(...sessions.map((session) => {
    const group = el('div', undefined, 'tree-group');
    group.append(el('h3', shortSessionId(session.session_id)));
    group.append(usageSpan(formatUsageTotal(session.usage_total)));
    const list = el('ul', undefined, 'tree-list');
    for (const node of flattenAgentTree(session.tree)) {
      const li = el('li', undefined, `tree-node depth-${Math.min(node.depth, MAX_TREE_DEPTH_CLASS)}`);
      li.append(el('span', node.name, 'tree-name'), ' ', el('span', node.statusLabel, statusClass(node.status)));
      if (node.tools.length > 0) li.append(' ', el('span', node.tools.join(', '), 'tree-tools'));
      if (node.usage.state !== 'none') li.append(' ', usageSpan(node.usage));
      list.append(li);
    }
    group.append(list);
    return group;
  }));
}

// 新しい行を先頭に足し、timeline（上限は appendTimeline が決める）を超えた分の古い行を末尾から外す
function renderTimelineRow(body, record, retainedCount) {
  const r = formatEventRow(record);
  body.prepend(row([r.time, r.session, r.agent, r.event, r.tool, r.detail]));
  while (body.children.length > retainedCount) body.lastElementChild.remove();
}

function setConnection(text) {
  document.getElementById('connection-status').textContent = text;
}

function startView() {
  let timeline = [];
  let lastRefresh = 0;
  let pending = null;

  async function refreshState() {
    lastRefresh = Date.now();
    try {
      const response = await fetch('api/state');
      if (!response.ok) return;
      const state = await response.json();
      if (!Array.isArray(state.sessions)) return;
      renderLoop(state.loop);
      renderSessions(state.sessions);
      renderTrees(state.sessions);
    } catch {
      setConnection('状態の取得に失敗');
    }
  }

  // サーバは seq が進むたびに全行から導出するので、SSE 着信ごとに取り直さず最大 1 秒に 1 回へ間引く（末尾は必ず拾う）
  function scheduleRefresh() {
    if (pending !== null) return;
    const wait = Math.max(0, STATE_REFRESH_MIN_INTERVAL_MS - (Date.now() - lastRefresh));
    pending = setTimeout(() => { pending = null; refreshState(); }, wait);
  }

  const body = document.getElementById('timeline-body');
  const source = new EventSource('api/stream');
  source.onopen = () => setConnection('接続済み');
  source.onerror = () => setConnection('再接続中');
  source.onmessage = (message) => {
    let record;
    try {
      record = JSON.parse(message.data);
    } catch {
      return;
    }
    if (record === null || typeof record !== 'object') return;
    timeline = appendTimeline(timeline, record);
    renderTimelineRow(body, record, timeline.length);
    scheduleRefresh();
  };

  source.addEventListener('loop', scheduleRefresh);

  refreshState();
}

if (typeof document !== 'undefined') startView();
