// テスト共通ヘルパー（node: 組み込みのみ。テストではない）
//
// サーバのモジュールは static import しない。実装が無い間（Red）も、
// 各テストが「個別に」失敗して件数が見えるように、テストの中で動的に読み込む。

import http from 'node:http';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const TEST_DIR = dirname(fileURLToPath(import.meta.url));
export const MONITOR_DIR = join(TEST_DIR, '..');
export const SERVER_DIR = join(MONITOR_DIR, 'server');
export const EMITTED_DIR = join(TEST_DIR, 'fixtures', 'emitted');

export const SID = '11111111-1111-4111-8111-111111111111';

// 指定子は全てリテラルにする（static.test.mjs の依存ゼロ検査が非リテラルの動的 import を禁じるため）
const LOADERS = {
  'validate.mjs': () => import('../server/validate.mjs'),
  'derive.mjs': () => import('../server/derive.mjs'),
  'store.mjs': () => import('../server/store.mjs'),
  'server.mjs': () => import('../server/server.mjs'),
};
export const load = (name) => {
  const loader = LOADERS[name];
  if (!loader) throw new Error(`未知のモジュール: ${name}`);
  return loader();
};

// ---------- fixtures ----------

export function emittedFixtures() {
  return readdirSync(EMITTED_DIR)
    .filter((f) => f.endsWith('.json'))
    .sort()
    .map((f) => {
      const text = readFileSync(join(EMITTED_DIR, f), 'utf8');
      return { name: f.replace(/\.json$/, ''), text, obj: JSON.parse(text) };
    });
}

export const fixture = (name) => {
  const f = emittedFixtures().find((x) => x.name === name);
  if (!f) throw new Error(`fixture が無い: ${name}`);
  return f.obj;
};

// ---------- 一時ディレクトリ（DB はテストごと。実ホームには触れない） ----------

const TMP_DIRS = [];
export function makeTmpDir() {
  const d = mkdtempSync(join(tmpdir(), 'monitor-test-'));
  TMP_DIRS.push(d);
  return d;
}
export function cleanupTmp() {
  for (const d of TMP_DIRS.splice(0)) rmSync(d, { recursive: true, force: true });
}

// ---------- サーバ起動 ----------

export async function startServer(opts = {}) {
  const { createServer } = await load('server.mjs');
  const dir = makeTmpDir();
  const dbPath = opts.dbPath ?? join(dir, 'monitor.db');
  const h = await createServer({ port: 0, bind: '127.0.0.1', dbPath, ...opts });
  return { h, port: h.port, dir, dbPath, store: h.store, close: () => h.close() };
}

/** サーバを起動して fn(s) を実行し、必ず close する。opts は startServer へそのまま渡す */
export async function withServer(fn, opts) {
  const s = await startServer(opts);
  try { await fn(s); } finally { await s.close(); }
}

/** dbPath を渡さず dataDir だけで起動する（既定パス相当の経路。#19 G5 retry 1）。失敗は reject のまま返す */
export async function createWithDataDir(dataDir, opts = {}) {
  const { createServer } = await load('server.mjs');
  // 注入口 dataDir が無視される実装（Red）でも、実リポジトリの既定データディレクトリを汚さない。
  // 実行前に無かったのに実行後にあれば、このテストが作ったものとして消して失敗にする
  const realDefault = join(MONITOR_DIR, 'data');
  const existed = existsSync(realDefault);
  // 実行前に無かったのに存在していれば消す。消したら true
  const cleanupDefault = () => {
    if (existed) return false;
    const created = existsSync(realDefault);
    rmSync(realDefault, { recursive: true, force: true });
    return created;
  };
  const handle = await createServer({ port: 0, bind: '127.0.0.1', dataDir, ...opts }).catch((err) => {
    cleanupDefault();
    throw err;
  });
  if (!existed && existsSync(realDefault)) {
    await handle.close();
    cleanupDefault();
    const err = new Error('dataDir が無視され、既定のデータディレクトリに DB が作られた（注入口 createServer({dataDir}) が未実装）');
    err.name = 'DataDirIgnoredError'; // 「リンクを拒否した reject」と取り違えない（拒否系テストが空振りで PASS しないように）
    throw err;
  }
  return handle;
}

/** リンク先に置く「本物の SQLite」。開かれて DDL が走れば中身（バイト列）が変わる＝改変を観測できる */
export function makeVictimDb(path) {
  const db = new DatabaseSync(path);
  db.exec("CREATE TABLE victim (v TEXT); INSERT INTO victim VALUES ('KEEP')");
  db.close();
  return readFileSync(path);
}

/** CLI を起動し、(a) 終了コードと出力 (b) listen してしまったか、を返す。listen したら止めて listening:true */
export async function runCliExpectExit(env, { waitMs = 4000 } = {}) {
  const cli = spawnCli(env);
  cli.listening.catch(() => {});
  const exited = new Promise((resolve) => cli.child.on('exit', (code) => resolve(code)));
  const timeout = new Promise((resolve) => setTimeout(() => resolve('TIMEOUT'), waitMs));
  const first = await Promise.race([exited, cli.listening.then(() => 'LISTENING', () => 'EXITED'), timeout]);
  if (first === 'LISTENING' || first === 'TIMEOUT') {
    await cli.stop();
    return { listening: true, code: null, out: cli.out };
  }
  const code = await exited;
  return { listening: false, code, out: cli.out };
}

// ---------- HTTP ----------

export function request(port, { method = 'GET', path = '/', headers = {}, body, timeout = 5000 } = {}) {
  return new Promise((resolve, reject) => {
    const hdr = { ...headers };
    const hasLen = Object.keys(hdr).some((k) => k.toLowerCase() === 'content-length');
    if (body !== undefined && !hasLen) hdr['Content-Length'] = String(Buffer.byteLength(body));
    const r = http.request({ host: '127.0.0.1', port, method, path, headers: hdr, agent: false }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
      res.on('error', reject);
    });
    r.setTimeout(timeout, () => r.destroy(new Error('request timeout')));
    r.on('error', reject);
    if (body !== undefined) r.write(body);
    r.end();
  });
}

export const JSON_HEADERS = { 'Content-Type': 'application/json' };

export const postEvent = (port, obj, { headers = {}, raw } = {}) =>
  request(port, {
    method: 'POST',
    path: '/api/events',
    headers: { ...JSON_HEADERS, ...headers },
    body: raw ?? JSON.stringify(obj),
  });

export const getState = async (port) => {
  const r = await request(port, { path: '/api/state' });
  return { ...r, json: r.status === 200 ? JSON.parse(r.body) : null };
};

/** 生ソケットでリクエスト文字列をそのまま送る（Host の欠落・空・HTTP/1.0 など http クライアントが作れない形用） */
export function rawRequest(port, text, { timeout = 3000 } = {}) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: '127.0.0.1', port });
    let buf = '';
    const done = () => {
      sock.destroy();
      const head = buf.split('\r\n\r\n')[0] ?? '';
      const lines = head.split('\r\n');
      const m = /^HTTP\/\d\.\d (\d{3})/.exec(lines[0] ?? '');
      const headers = {};
      for (const l of lines.slice(1)) {
        const k = l.indexOf(':');
        if (k > 0) headers[l.slice(0, k).toLowerCase()] = l.slice(k + 1).trim();
      }
      resolve({ status: m ? Number(m[1]) : null, headers, text: buf });
    };
    sock.setEncoding('utf8');
    sock.on('data', (c) => { buf += c; });
    sock.on('end', done);
    sock.on('close', done);
    sock.on('error', done);
    sock.setTimeout(timeout, done);
    sock.write(text);
  });
}

/** chunked で延々と送り続け、サーバがどこで読み取りを打ち切るかを観測する */
export function floodChunked(port, { capBytes = 8 * 1024 * 1024, timeoutMs = 4000 } = {}) {
  return new Promise((resolve) => {
    const sock = net.connect({ host: '127.0.0.1', port });
    let response = '';
    let sent = 0;
    let finished = false;
    const piece = Buffer.alloc(16 * 1024, 0x61);
    const finish = (closed) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      sock.destroy();
      const m = /^HTTP\/\d\.\d (\d{3})/.exec(response);
      resolve({ status: m ? Number(m[1]) : null, sent, closed, response });
    };
    const timer = setTimeout(() => finish(false), timeoutMs);
    sock.setEncoding('utf8');
    sock.on('data', (c) => { response += c; });
    sock.on('close', () => finish(true));
    sock.on('error', () => finish(true));
    sock.write(
      `POST /api/events HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n`,
    );
    const pump = () => {
      while (!finished && sent < capBytes) {
        const ok = sock.write(Buffer.concat([Buffer.from(`${piece.length.toString(16)}\r\n`), piece, Buffer.from('\r\n')]));
        sent += piece.length;
        if (!ok) { sock.once('drain', pump); return; }
      }
      if (!finished) setTimeout(() => finish(false), 300);
    };
    pump();
  });
}

// ---------- SSE ----------

export function openStream(port, { headers = {}, path = '/api/stream' } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port, path, headers: { Accept: 'text/event-stream', ...headers }, agent: false }, (res) => {
      let buf = '';
      let ended = false;
      res.setEncoding('utf8');
      res.on('data', (c) => { buf += c; });
      res.on('end', () => { ended = true; });
      res.on('close', () => { ended = true; });
      res.on('error', () => { ended = true; });
      const stream = {
        status: res.statusCode,
        headers: res.headers,
        get text() { return buf; },
        get ended() { return ended; },
        async waitFor(pred, ms = 3000) {
          const t0 = Date.now();
          while (!pred(buf)) {
            if (Date.now() - t0 > ms) throw new Error(`SSE 待機タイムアウト。受信済み: ${JSON.stringify(buf.slice(0, 300))}`);
            await new Promise((r2) => setTimeout(r2, 10));
          }
        },
        async waitEnd(ms = 3000) {
          const t0 = Date.now();
          while (!ended) {
            if (Date.now() - t0 > ms) throw new Error('SSE 終了待ちタイムアウト');
            await new Promise((r2) => setTimeout(r2, 10));
          }
        },
        destroy() { r.destroy(); res.destroy(); },
      };
      resolve(stream);
    });
    r.on('error', reject);
    r.end();
  });
}

/** SSE 本文から `data:` の JSON を取り出す */
export function parseSse(text) {
  const out = [];
  for (const block of text.split('\n\n')) {
    const dataLines = block.split('\n').filter((l) => l.startsWith('data:')).map((l) => l.slice(5).replace(/^ /, ''));
    if (dataLines.length === 0) continue;
    try { out.push(JSON.parse(dataLines.join('\n'))); } catch { /* コメント行・不完全ブロックは無視 */ }
  }
  return out;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export const acaoHeaders = (headers) => Object.keys(headers).filter((k) => k.toLowerCase().startsWith('access-control-'));

/** CLI（node server.mjs）を子プロセスで起動する。stdout / stderr を out に貯める */
export function spawnCli(env) {
  const dir = makeTmpDir();
  const child = spawn(process.execPath, [join(SERVER_DIR, 'server.mjs')], {
    env: { PATH: process.env.PATH, NODE_NO_WARNINGS: '1', MONITOR_DB: join(dir, 'monitor.db'), LOOP_MONITOR_PORT: '0', ...env },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const out = { stdout: '', stderr: '' };
  child.stdout.on('data', (c) => { out.stdout += c; });
  child.stderr.on('data', (c) => { out.stderr += c; });
  const listening = new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`CLI が listen 行を出さない。stdout=${out.stdout} stderr=${out.stderr}`)), 8000);
    const poll = setInterval(() => {
      const m = /listening on (\S+):(\d+)/.exec(out.stdout);
      if (m) { clearTimeout(t); clearInterval(poll); resolve({ bind: m[1], port: Number(m[2]) }); }
    }, 20);
    child.on('exit', (code) => { clearTimeout(t); clearInterval(poll); reject(new Error(`CLI が終了した code=${code} stderr=${out.stderr}`)); });
  });
  const stop = () => new Promise((resolve) => {
    if (child.exitCode !== null) return resolve();
    child.on('exit', () => resolve());
    child.kill('SIGTERM');
    setTimeout(() => child.kill('SIGKILL'), 3000);
  });
  return { child, out, listening, stop };
}
