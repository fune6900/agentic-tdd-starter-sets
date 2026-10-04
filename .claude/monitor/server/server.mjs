// 監視の受信サーバ（node:http のみ）。倒す向きは fail closed（フック側 monitor-emit.sh は fail open で逆）。
// 検査の順序: Host → Origin → Sec-Fetch-Site → ルート → Content-Type → ボディ上限 → JSON → validateEvent → 保存。
// 受信した値の行き先は SQLite・/api/state・SSE のみ。エラー本文とログには載せない。

import http from 'node:http';
import { realpathSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { prepareDbPath } from './db-guard.mjs';
import { deriveState } from './derive.mjs';
import { openStore } from './store.mjs';
import { validateEvent } from './validate.mjs';

export const MAX_BODY_BYTES = 65_536;
export const MAX_SSE_CLIENTS = 16;
export const DEFAULT_PORT = 4319;
const DEFAULT_BIND = '127.0.0.1';
// 保持期間の削除: 起動時 + 一定間隔（暇なサーバでも古い行が消える）+ 追記 N 件ごと（バースト時に上限を超え続けない）
const PRUNE_INTERVAL_MS = 60 * 60 * 1000;
const PRUNE_EVERY_APPENDS = 1000;
// 既定のデータディレクトリ。gitignore 済みの .claude/monitor/data/（リポジトリにも、ホーム配下にも置かない）
const DEFAULT_DATA_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'data');
const DB_FILE_NAME = 'monitor.db';

const ERRORS = Object.freeze({
  FORBIDDEN: [403, 'Forbidden'],
  NOT_FOUND: [404, 'Not found'],
  METHOD_NOT_ALLOWED: [405, 'Method not allowed'],
  PAYLOAD_TOO_LARGE: [413, 'Payload too large'],
  UNSUPPORTED_MEDIA_TYPE: [415, 'Unsupported media type'],
  VALIDATION_ERROR: [400, 'Invalid request'],
  UNAVAILABLE: [503, 'Service unavailable'],
  INTERNAL_ERROR: [500, 'Internal server error'],
});

/** @param {Record<string, string | undefined>} env */
export function resolveBind(env) {
  return typeof env.MONITOR_BIND === 'string' && env.MONITOR_BIND !== '' ? env.MONITOR_BIND : DEFAULT_BIND;
}

/**
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {unknown} payload
 * @param {Record<string, string>} [extraHeaders]
 */
function sendJson(res, status, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...extraHeaders,
  });
  res.end(body);
}

/**
 * @param {import('node:http').ServerResponse} res
 * @param {keyof typeof ERRORS} code
 * @param {Record<string, string>} [extraHeaders]
 */
function sendError(res, code, extraHeaders) {
  const [status, message] = ERRORS[code];
  sendJson(res, status, { data: null, error: { message, code } }, extraHeaders);
}

// ブラウザは Sec-Fetch-Site を必ず付ける（スクリプトから偽装できない）。付いていて same-origin / none 以外なら拒否。
// 無ければ通す（curl・フック・同一端末のプロセス）。重複ヘッダは Node が ", " で連結するので完全一致で落ちる
const ALLOWED_FETCH_SITES = new Set(['same-origin', 'none']);

const isJsonContentType = (value) => typeof value === 'string' && value.split(';')[0].trim().toLowerCase() === 'application/json';

const TOO_LARGE = Symbol('too-large');
const ABORTED = Symbol('aborted');

/**
 * ボディを上限まで読む。超えたら読み取りを止めて TOO_LARGE、途中で切れたら ABORTED
 * @param {import('node:http').IncomingMessage} req
 * @returns {Promise<Buffer | symbol>}
 */
function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    const settle = (value) => { if (!settled) { settled = true; resolve(value); } };
    req.on('data', (chunk) => {
      if (settled) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        req.pause();
        settle(TOO_LARGE);
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => settle(Buffer.concat(chunks)));
    req.on('error', () => settle(ABORTED));
    req.on('close', () => settle(ABORTED));
  });
}

/**
 * @param {Buffer} buffer
 * @returns {{ok: true, value: unknown} | {ok: false}}
 */
function parseJson(buffer) {
  try {
    return { ok: true, value: JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(buffer)) };
  } catch {
    return { ok: false };
  }
}

/** 413 を返したらその接続は読み捨てずに閉じる（残りのボディを食わない） */
function rejectTooLarge(req, res) {
  sendError(res, 'PAYLOAD_TOO_LARGE', { Connection: 'close' });
  res.once('finish', () => req.socket.destroy());
}

/**
 * @param {{port?: number, bind?: string, dbPath?: string, dataDir?: string, now?: () => number, retentionMs?: number, maxRows?: number, derive?: typeof deriveState}} opts
 */
export async function createServer({
  port = DEFAULT_PORT, bind = resolveBind(process.env), dbPath, dataDir = DEFAULT_DATA_DIR, now, retentionMs, maxRows, derive = deriveState,
} = {}) {
  // 検査 → 作成の順。リンクなら listen の前に reject する
  const store = openStore({ dbPath: prepareDbPath(dbPath ?? join(dataDir, DB_FILE_NAME)), now, retentionMs, maxRows });
  const clients = new Set();
  let actualPort = 0;
  let appendsSincePrune = 0;
  let stateCache = null; // {last_seq, body}。last_seq が変わった時だけ導出し直す

  const pruneSafe = () => {
    try {
      if (store.prune() > 0) stateCache = null; // 行が消えたら導出結果も古い（seq は進まない）
    } catch { /* close 済み・失敗は次回に回す。本文は出さない */ }
  };
  pruneSafe();
  const timer = setInterval(pruneSafe, PRUNE_INTERVAL_MS);
  timer.unref();

  const broadcast = (record) => {
    const frame = `id: ${record.seq}\ndata: ${JSON.stringify(record)}\n\n`;
    // client.write の戻り値（バックプレッシャ）は見ない。上限16件で、close 時に clients から消えるため許容
    for (const client of clients) client.write(frame);
  };

  async function postEvent(req, res) {
    if (!isJsonContentType(req.headers['content-type'])) return sendError(res, 'UNSUPPORTED_MEDIA_TYPE');
    const declared = Number(req.headers['content-length']);
    if (declared > MAX_BODY_BYTES) return rejectTooLarge(req, res);

    const body = await readBody(req);
    if (body === ABORTED) return undefined;
    if (body === TOO_LARGE) return rejectTooLarge(req, res);

    const parsed = parseJson(body);
    if (!parsed.ok) return sendError(res, 'VALIDATION_ERROR');
    const verdict = validateEvent(parsed.value);
    if (!verdict.ok) return sendError(res, 'VALIDATION_ERROR');

    const { seq, received_at } = store.append(verdict.event);
    appendsSincePrune += 1;
    if (appendsSincePrune >= PRUNE_EVERY_APPENDS) {
      appendsSincePrune = 0;
      pruneSafe();
    }
    broadcast({ seq, received_at, ...verdict.event });
    return sendJson(res, 201, { data: { seq }, error: null });
  }

  function getState(res) {
    const lastSeq = store.lastSeq();
    if (stateCache?.last_seq !== lastSeq) {
      stateCache = { last_seq: lastSeq, body: { sessions: derive(store.list()).sessions, last_seq: lastSeq } };
    }
    sendJson(res, 200, stateCache.body);
  }

  /**
   * @param {import('node:http').ServerResponse} res
   * @returns {undefined}
   */
  function openStream(res) {
    if (clients.size >= MAX_SSE_CLIENTS) return sendError(res, 'UNAVAILABLE', { Connection: 'close' });
    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
      'X-Content-Type-Options': 'nosniff',
    });
    res.flushHeaders();
    clients.add(res);
    res.on('close', () => clients.delete(res));
    return undefined;
  }

  const routes = {
    '/api/events': { POST: postEvent },
    '/api/state': { GET: (req, res) => getState(res) },
    '/api/stream': { GET: (_req, res) => openStream(res) },
  };

  async function handle(req, res) {
    const { host, origin } = req.headers;
    const fetchSite = req.headers['sec-fetch-site'];
    const allowedHosts = [`127.0.0.1:${actualPort}`, `localhost:${actualPort}`];
    if (typeof host !== 'string' || !allowedHosts.includes(host)) return sendError(res, 'FORBIDDEN');
    if (origin !== undefined && origin !== `http://${host}`) return sendError(res, 'FORBIDDEN');

    if (fetchSite !== undefined && !ALLOWED_FETCH_SITES.has(fetchSite)) return sendError(res, 'FORBIDDEN');

    const path = req.url.split('?')[0];
    const route = Object.hasOwn(routes, path) ? routes[path] : undefined;
    if (!route) return sendError(res, 'NOT_FOUND');
    const handler = Object.hasOwn(route, req.method) ? route[req.method] : undefined;
    if (!handler) return sendError(res, 'METHOD_NOT_ALLOWED');
    return handler(req, res);
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch(() => {
      // 例外・スタック・パス・入力値は載せない。ヘッダ送信済みなら接続を切るだけ
      if (res.headersSent) res.destroy();
      else sendError(res, 'INTERNAL_ERROR');
    });
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, bind, () => { server.off('error', reject); resolve(); });
  });
  actualPort = server.address().port;

  return {
    port: actualPort,
    bind,
    server,
    store,
    async close() {
      clearInterval(timer);
      for (const client of clients) client.end();
      clients.clear();
      server.closeAllConnections();
      await new Promise((resolve) => { server.close(() => resolve()); });
      try { store.close(); } catch { /* 既に close 済み */ }
    },
  };
}

// ---------- CLI（import しただけでは listen しない） ----------

// フック側（monitor-emit.sh）と同じ規則: 1〜65535 の10進以外は既定に倒す。CLI のみ 0（空きポート）も許す
function resolveCliPort(env) {
  const raw = env.LOOP_MONITOR_PORT;
  if (typeof raw === 'string' && /^(0|[1-9][0-9]{0,4})$/.test(raw) && Number(raw) <= 65_535) return Number(raw);
  return DEFAULT_PORT;
}

function isMain() {
  try {
    return process.argv[1] !== undefined && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href;
  } catch {
    return false;
  }
}

if (isMain()) {
  try {
    const handle = await createServer({
      port: resolveCliPort(process.env),
      bind: resolveBind(process.env),
      dbPath: process.env.MONITOR_DB || undefined,
    });
    // CLI の起動通知。受信値は載せない
    process.stdout.write(`listening on ${handle.bind}:${handle.port}\n`);
    const shutdown = () => { handle.close().finally(() => process.exit(0)); };
    process.once('SIGTERM', shutdown);
    process.once('SIGINT', shutdown);
  } catch {
    console.error('monitor server failed to start');
    process.exit(1);
  }
}
