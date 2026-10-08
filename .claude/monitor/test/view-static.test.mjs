// 静的配信とセキュリティヘッダ（Issue #21 / Red）。サーバ（server/server.mjs）の契約テスト。
//
// ════════════════════════════════════════════════════════════════════════════
//  Coder への契約
// ════════════════════════════════════════════════════════════════════════════
//  静的ファイル: .claude/monitor/public/{index.html,app.js,style.css} の 3 つだけ。サーバのルート表に固定パスで足す
//    GET /          -> public/index.html   Content-Type: text/html; charset=utf-8
//    GET /app.js    -> public/app.js       Content-Type: text/javascript; charset=utf-8
//    GET /style.css -> public/style.css    Content-Type: text/css; charset=utf-8
//    全て 200 / Cache-Control: no-store / 本文は public/ の実ファイルとバイト一致（Content-Length があればバイト数と一致）
//    URL からファイルパスを組み立てない（デコード・正規化・join・path 解決をしない）。ルート表との完全一致だけ。
//    クエリ（?以降）は既存ルートと同じく無視する（/app.js?v=1 は app.js）。それ以外の形は 404
//    メソッドは GET のみ。許可リストの 3 パスへの GET 以外（POST / HEAD / PUT / DELETE / PATCH / OPTIONS）は 405
//    既存の検査順は変えない: Host → Origin → Sec-Fetch-Site → ルート。静的 GET にも同じ検査が掛かる（lessons #19）
//    Origin: ES module の <script> 取得はブラウザが Origin を付ける（http://<Host>）。これは通る（既存の Origin 検査の範囲）
//  全応答（静的・JSON・SSE・403 / 404 / 405 / 400 / 413 / 415 / 500 / 503 を含むエラー）に次の 3 ヘッダ（値は完全一致）:
//    Content-Security-Policy: default-src 'self'
//    X-Content-Type-Options: nosniff
//    X-Frame-Options: DENY
//  付けるのは 1 箇所（sendJson / 静的 / SSE の writeHead の全てに同じ定数）。Access-Control-* は付けない
//
// ════════════════════════════════════════════════════════════════════════════
//  変異テスト対応表（防御を1つ外した隔離コピーで、左の変異に対し右のテストが FAIL するべき）
//  手順: .claude/monitor を一時ディレクトリへコピーし、server/server.mjs に左の変異を入れ、このファイルを node --test で走らせる
// ════════════════════════════════════════════════════════════════════════════
//   静的パスを URL から組み立てる（join(PUBLIC, decodeURIComponent(path)) で読む）
//                                         [traversal] 全ケース（/../server/server.mjs・/%2e%2e/・/index.html・/public/app.js 等が 200 になる）
//   許可リストに /index.html を足す          [traversal] /index.html が 404 でない
//   許可リストに server.mjs を足す           [traversal] /server/server.mjs・/../server/server.mjs
//   パスを正規化してから照合する（new URL / path.normalize） [traversal] /app.js/..・//app.js・/./app.js・/app.js/.
//   パスの大文字小文字を無視する             [traversal] /APP.JS・/Style.css
//   パスのデコード後に照合する               [traversal] /%61pp.js・/app.js%00・/%2e%2e/
//   GET 以外を許す（メソッドを見ない）        [method] POST / PUT / DELETE / PATCH / OPTIONS / HEAD が 405 でない
//   CSP ヘッダを外す（1 経路でも）            [headers] 経路ごとのマトリクス（静的 3 + JSON + SSE + 403/404/405/400/413/415/500/503）
//   sendError だけ / sendJson だけ に付ける    [headers] 付けなかった経路のケース
//   SSE の writeHead に付け忘れる             [headers] SSE（200）と 503
//   値を default-src * などに緩める           [headers] 完全一致
//   X-Frame-Options / nosniff を外す          [headers] 同上
//   Host 検査を静的ルートの後ろに回す          [guard] Host 不一致で / が 200
//   Sec-Fetch-Site 検査を静的ルートで外す      [guard] cross-site / same-site で / が 403 でない
//   Origin を静的ルートで見ない               [guard] 別オリジンの Origin で /app.js が 403 でない
//   Content-Type を text/plain などにする      [type] 3 ファイルの Content-Type 完全一致
//   Cache-Control を外す                      [type] no-store
//   本文を加工する（BOM・改行・圧縮・キャッシュの陳腐化）  [bytes] 実ファイルとバイト一致

import http from 'node:http';
import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import {
  acaoHeaders, cleanupTmp, fixture, load, makeTmpDir, MONITOR_DIR, openStream, postEvent, rawRequest, request, withServer,
} from './helpers.mjs';

after(cleanupTmp);

const PUBLIC_DIR = join(MONITOR_DIR, 'public');
const STATIC = [
  { path: '/', file: 'index.html', type: 'text/html; charset=utf-8' },
  { path: '/app.js', file: 'app.js', type: 'text/javascript; charset=utf-8' },
  { path: '/style.css', file: 'style.css', type: 'text/css; charset=utf-8' },
];
const SECURITY_HEADERS = Object.freeze({
  'content-security-policy': "default-src 'self'",
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
});

/** バイト列のまま本文を受け取る（utf8 に落とすと BOM・不正バイトの差が見えなくなる） */
function requestBytes(port, { method = 'GET', path = '/', headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request({ host: '127.0.0.1', port, method, path, headers, agent: false }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks), rawHeaders: res.rawHeaders }));
      res.on('error', reject);
    });
    r.setTimeout(5000, () => r.destroy(new Error('request timeout')));
    r.on('error', reject);
    r.end();
  });
}

function assertSecurityHeaders(headers, label) {
  for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
    assert.equal(headers[k], v, `${label}: ${k} が '${v}' でない（実際: ${JSON.stringify(headers[k])}）`);
  }
  assert.deepEqual(acaoHeaders(headers), [], `${label}: Access-Control-* がある`);
}

// ---------- 前提: 実ファイル ----------

test('[files] public/ に index.html / app.js / style.css があり、空でない（空==空で一致させない）', () => {
  for (const { file } of STATIC) {
    const p = join(PUBLIC_DIR, file);
    assert.ok(existsSync(p), `${p} が無い`);
    assert.ok(statSync(p).isFile(), `${p} が通常ファイルでない`);
    assert.ok(statSync(p).size > 0, `${p} が空`);
  }
});

// ---------- [type] / [bytes] 静的応答 ----------

for (const { path, file, type } of STATIC) {
  test(`[type] GET ${path} は 200・Content-Type: ${type}・Cache-Control: no-store`, async () => {
    await withServer(async (s) => {
      const r = await requestBytes(s.port, { path });
      assert.equal(r.status, 200);
      assert.equal(r.headers['content-type'], type);
      assert.equal(r.headers['cache-control'], 'no-store');
      assertSecurityHeaders(r.headers, `GET ${path}`);
    });
  });

  test(`[bytes] GET ${path} の本文は public/${file} の実ファイルとバイト一致（Content-Length があればバイト数と一致）`, async () => {
    const expected = readFileSync(join(PUBLIC_DIR, file));
    assert.ok(expected.length > 0);
    await withServer(async (s) => {
      for (let i = 0; i < 2; i += 1) { // 2 回目で、読み捨て・使い回しのバッファ破壊を見る
        const r = await requestBytes(s.port, { path });
        assert.equal(r.status, 200);
        assert.ok(r.body.equals(expected), `本文が実ファイルと違う（${r.body.length} / ${expected.length} バイト）`);
        if (r.headers['content-length'] !== undefined) assert.equal(Number(r.headers['content-length']), expected.length);
        assert.equal(r.headers['content-encoding'], undefined, '圧縮してはいけない（バイト一致を崩す）');
      }
    });
  });

  test(`[bytes] GET ${path}?v=1 のようなクエリは無視して同じファイルを返す。クエリでパスを差し替えられない`, async () => {
    const expected = readFileSync(join(PUBLIC_DIR, file));
    await withServer(async (s) => {
      for (const q of ['?v=1', '?', '?/../server/server.mjs', '?path=/app.js', '?x=%2e%2e']) {
        const r = await requestBytes(s.port, { path: `${path}${q}` });
        assert.equal(r.status, 200, `${path}${q}`);
        assert.ok(r.body.equals(expected), `${path}${q}: 本文が違う`);
      }
    });
  });
}

// ---------- [traversal] 許可リスト外は 404 ----------

const NOT_FOUND_PATHS = [
  '/../server/server.mjs',
  '/..%2fserver/server.mjs',
  '/%2e%2e/',
  '/%2e%2e/server/server.mjs',
  '/%2E%2E/server/server.mjs',
  '/..%5cserver%5cserver.mjs',
  '/app.js/..',
  '/app.js/../server/server.mjs',
  '/app.js/.',
  '/./app.js',
  '/index.html',
  '/public/app.js',
  '/public/index.html',
  '/public/',
  '/public',
  '//app.js',
  '//',
  '///app.js',
  '/app.js%00',
  '/app.js%00.html',
  '/%00',
  '/app.js/',
  '/app.js%2f',
  '/app.js%20',
  '/%61pp.js',
  '/app%2ejs',
  '/APP.JS',
  '/App.js',
  '/Style.css',
  '/STYLE.CSS',
  '/app.js;x',
  '/app.js.map',
  '/app.mjs',
  '/style.css/',
  '/style.css%00',
  '/server/server.mjs',
  '/server/derive.mjs',
  '/server',
  '/test/helpers.mjs',
  '/docs/event-schema.md',
  '/data/monitor.db',
  '/Dockerfile',
  '/.dockerignore',
  '/.env',
  '/.git/config',
  '/favicon.ico',
  '/robots.txt',
  '/api',
  '/api/',
  '/api/events/',
  '/index',
  '/index.htm',
  '/app',
  '/style',
  '/~',
  '/..',
  '/../',
  '/./',
  '/.',
  '/%2e',
];

test('[traversal] 許可リスト（/ /app.js /style.css）以外のパスは全て 404。本文にファイルの中身・内部情報が出ない', async () => {
  const servedSources = ['createServer', 'import ', 'node:sqlite', 'DatabaseSync', 'export '];
  await withServer(async (s) => {
    const failures = [];
    for (const path of NOT_FOUND_PATHS) {
      let r;
      try {
        r = await request(s.port, { path });
      } catch (err) {
        failures.push(`${path}: リクエスト失敗 ${err.message}`);
        continue;
      }
      if (r.status !== 404) failures.push(`${path}: ${r.status}`);
      const leaked = servedSources.filter((w) => r.body.includes(w));
      if (leaked.length > 0) failures.push(`${path}: 本文に ${leaked.join(',')}`);
      for (const [k, v] of Object.entries(SECURITY_HEADERS)) {
        if (r.headers[k] !== v) failures.push(`${path}: ${k}=${r.headers[k]}`);
      }
    }
    assert.deepEqual(failures, [], failures.join('\n'));
  });
});

test('[traversal] 404 の本文は固定の JSON エラー（パスを反射しない）', async () => {
  await withServer(async (s) => {
    const marker = 'REFLECT_ME_12345';
    const r = await request(s.port, { path: `/${marker}/../x` });
    assert.equal(r.status, 404);
    assert.ok(!r.body.includes(marker), '要求パスを本文に反射している');
    assert.deepEqual(JSON.parse(r.body), { data: null, error: { message: 'Not found', code: 'NOT_FOUND' } });
  });
});

test('[traversal] 生ソケットで送った異常な要求行（バックスラッシュ・NUL 相当・二重スラッシュ）も許可リスト外は 404', async () => {
  await withServer(async (s) => {
    for (const target of ['/..\\server\\server.mjs', '//app.js', '/app.js%00', '/../../../../etc/passwd', '/%2e%2e%2f%2e%2e%2fetc%2fpasswd']) {
      const r = await rawRequest(s.port, `GET ${target} HTTP/1.1\r\nHost: 127.0.0.1:${s.port}\r\nConnection: close\r\n\r\n`);
      assert.equal(r.status, 404, `${target}: ${r.status}`);
      assert.ok(!r.text.includes('root:'), `${target}: /etc/passwd の中身が出た`);
      assertSecurityHeaders(r.headers, target);
    }
  });
});

// ---------- [method] GET のみ ----------

test('[method] 許可リストの 3 パスへの GET 以外は 405（POST / HEAD / PUT / DELETE / PATCH / OPTIONS）。セキュリティヘッダ付き', async () => {
  await withServer(async (s) => {
    for (const { path } of STATIC) {
      for (const method of ['POST', 'PUT', 'DELETE', 'PATCH', 'OPTIONS', 'HEAD']) {
        const r = await request(s.port, { method, path, headers: { 'Content-Type': 'application/json' }, body: method === 'POST' ? '{}' : undefined });
        assert.equal(r.status, 405, `${method} ${path}`);
        assertSecurityHeaders(r.headers, `${method} ${path}`);
        assert.ok(!/<html|function |export /i.test(r.body), `${method} ${path}: 405 の本文にファイルの中身`);
      }
    }
  });
});

test('[method] POST / は 405 で、イベントとして保存されない（行数不変）', async () => {
  await withServer(async (s) => {
    const before = s.store.list().length;
    const r = await request(s.port, { method: 'POST', path: '/', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(fixture('SessionStart')) });
    assert.equal(r.status, 405);
    assert.equal(s.store.list().length, before);
  });
});

// ---------- [guard] Host → Origin → Sec-Fetch-Site が静的 GET にも掛かる（lessons #19） ----------

test('[guard] 静的 GET も Host が許可外なら 403（ファイルの中身を返さない）', async () => {
  await withServer(async (s) => {
    for (const { path } of STATIC) {
      for (const host of ['evil.example', `evil.example:${s.port}`, `127.0.0.1:${s.port + 1}`, '127.0.0.1', `LOCALHOST:${s.port}`]) {
        const r = await request(s.port, { path, headers: { Host: host } });
        assert.equal(r.status, 403, `${path} Host=${JSON.stringify(host)}`);
        assert.ok(!/<html|function |export /i.test(r.body), `${path}: 403 の本文にファイルの中身`);
        assertSecurityHeaders(r.headers, `${path} 403`);
      }
      // 空の Host は http.request が捨てて既定の Host に差し替える（実測）ので、生ソケットで `Host:` 空値をそのまま送る
      const raw = await rawRequest(s.port, `GET ${path} HTTP/1.1\r\nHost: \r\nConnection: close\r\n\r\n`);
      assert.equal(raw.status, 403, `${path} Host=空（生ソケット）`);
      assert.ok(!/<html|function |export /i.test(raw.text.split('\r\n\r\n').slice(1).join('')), `${path}: 空 Host の 403 の本文にファイルの中身`);
      assertSecurityHeaders(raw.headers, `${path} 空 Host 403`);
    }
  });
});

test('[guard] 静的 GET も Origin が Host と一致しなければ 403。ES module 取得の Origin（http://<Host>）は通る', async () => {
  await withServer(async (s) => {
    for (const { path } of STATIC) {
      for (const origin of ['http://evil.example', 'null', '', `http://127.0.0.1:${s.port}/`, `https://127.0.0.1:${s.port}`, `http://localhost:${s.port}`]) {
        const r = await request(s.port, { path, headers: { Origin: origin } });
        assert.equal(r.status, 403, `${path} Origin=${JSON.stringify(origin)}`);
        assertSecurityHeaders(r.headers, `${path} 403`);
      }
    }
    const ok = await request(s.port, { path: '/app.js', headers: { Origin: `http://127.0.0.1:${s.port}` } });
    assert.equal(ok.status, 200, 'module script の取得（Origin 付き）が通らない');
    const okLocalhost = await request(s.port, { path: '/app.js', headers: { Host: `localhost:${s.port}`, Origin: `http://localhost:${s.port}` } });
    assert.equal(okLocalhost.status, 200, 'localhost でのアクセスが通らない');
  });
});

test('[guard] 静的 GET も Sec-Fetch-Site が cross-site / same-site / 未知値 なら 403。same-origin / none / 無しは 200', async () => {
  await withServer(async (s) => {
    for (const { path } of STATIC) {
      for (const v of ['cross-site', 'same-site', 'Same-Origin', 'same-origin, cross-site', 'unknown', '']) {
        const r = await request(s.port, { path, headers: { 'Sec-Fetch-Site': v } });
        assert.equal(r.status, 403, `${path} Sec-Fetch-Site=${JSON.stringify(v)}`);
        assert.ok(!/<html|function |export /i.test(r.body), `${path}: 403 の本文にファイルの中身`);
        assertSecurityHeaders(r.headers, `${path} 403`);
      }
      for (const v of ['same-origin', 'none']) {
        const r = await request(s.port, { path, headers: { 'Sec-Fetch-Site': v } });
        assert.equal(r.status, 200, `${path} Sec-Fetch-Site=${v}`);
      }
      assert.equal((await request(s.port, { path })).status, 200, `${path} ヘッダ無し`);
    }
  });
});

test('[guard] cross-site の <img> 風 GET（Host 正・Origin 無し・Sec-Fetch-Site: cross-site）で / を取れない', async () => {
  await withServer(async (s) => {
    const r = await request(s.port, { path: '/', headers: { 'Sec-Fetch-Site': 'cross-site', Accept: 'image/*' } });
    assert.equal(r.status, 403);
  });
});

test('[guard] Host ヘッダが無い要求（HTTP/1.0）は静的パスでも 403。ヘッダ付き', async () => {
  await withServer(async (s) => {
    const r = await rawRequest(s.port, 'GET / HTTP/1.0\r\n\r\n');
    assert.equal(r.status, 403);
    assertSecurityHeaders(r.headers, 'Host 欠落');
  });
});

// ---------- [headers] 全応答にセキュリティヘッダ ----------

test('[headers 自己診断] 期待ヘッダの値は Issue の文字列そのもの（テスト側の定数が崩れていない）', () => {
  assert.deepEqual(SECURITY_HEADERS, {
    'content-security-policy': "default-src 'self'",
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
  });
});

test('[headers] 静的 3 + JSON（/api/state・POST 201）+ エラー（400 / 403 / 404 / 405 / 413 / 415）の全応答にセキュリティヘッダが付く', async () => {
  await withServer(async (s) => {
    const good = fixture('SessionStart');
    const cases = [
      ['GET /', () => request(s.port, { path: '/' }), 200],
      ['GET /app.js', () => request(s.port, { path: '/app.js' }), 200],
      ['GET /style.css', () => request(s.port, { path: '/style.css' }), 200],
      ['GET /api/state', () => request(s.port, { path: '/api/state' }), 200],
      ['POST /api/events 201', () => postEvent(s.port, good), 201],
      ['POST /api/events 400（不正 JSON）', () => postEvent(s.port, null, { raw: '{not json' }), 400],
      ['POST /api/events 400（検証失敗）', () => postEvent(s.port, { schema_version: 1, event: 'Nope', session_id: 'x' }), 400],
      ['POST /api/events 415', () => request(s.port, { method: 'POST', path: '/api/events', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify(good) }), 415],
      ['POST /api/events 413', () => postEvent(s.port, null, { raw: 'x'.repeat(65_537) }), 413],
      ['GET /nope 404', () => request(s.port, { path: '/nope' }), 404],
      ['GET /index.html 404', () => request(s.port, { path: '/index.html' }), 404],
      ['GET /../server/server.mjs 404', () => request(s.port, { path: '/../server/server.mjs' }), 404],
      ['POST / 405', () => request(s.port, { method: 'POST', path: '/', headers: { 'Content-Type': 'application/json' }, body: '{}' }), 405],
      ['DELETE /api/state 405', () => request(s.port, { method: 'DELETE', path: '/api/state' }), 405],
      ['OPTIONS /api/events 405', () => request(s.port, { method: 'OPTIONS', path: '/api/events' }), 405],
      ['GET /api/events 405', () => request(s.port, { path: '/api/events' }), 405],
      ['403 Host', () => request(s.port, { path: '/api/state', headers: { Host: 'evil.example' } }), 403],
      ['403 Origin', () => request(s.port, { path: '/api/state', headers: { Origin: 'http://evil.example' } }), 403],
      ['403 Sec-Fetch-Site', () => request(s.port, { path: '/', headers: { 'Sec-Fetch-Site': 'cross-site' } }), 403],
      ['403 POST /api/events（Host 偽）', () => postEvent(s.port, good, { headers: { Host: 'evil.example' } }), 403],
    ];
    for (const [label, run, status] of cases) {
      const r = await run();
      assert.equal(r.status, status, `${label}: ステータス ${r.status}`);
      assertSecurityHeaders(r.headers, label);
    }
  });
});

test('[headers] 生ソケットの要求（Host 欠落・異常な要求）への 403 / 404 にもセキュリティヘッダが付く', async () => {
  await withServer(async (s) => {
    const r1 = await rawRequest(s.port, 'GET /api/state HTTP/1.1\r\nConnection: close\r\n\r\n');
    assert.equal(r1.status, 403);
    assertSecurityHeaders(r1.headers, 'Host 欠落 /api/state');
    const r2 = await rawRequest(s.port, `GET /x HTTP/1.1\r\nHost: 127.0.0.1:${s.port}\r\nConnection: close\r\n\r\n`);
    assert.equal(r2.status, 404);
    assertSecurityHeaders(r2.headers, 'GET /x');
  });
});

test('[headers] SSE（/api/stream）の 200 応答にセキュリティヘッダが付き、イベントも流れる（ヘッダ追加で壊していない）', async () => {
  await withServer(async (s) => {
    const stream = await openStream(s.port);
    try {
      assert.equal(stream.status, 200);
      assert.match(stream.headers['content-type'], /^text\/event-stream/);
      assertSecurityHeaders(stream.headers, 'SSE 200');
      await postEvent(s.port, fixture('SessionStart'));
      await stream.waitFor((t) => t.includes('data:'));
    } finally {
      stream.destroy();
    }
  });
});

test('[headers] SSE の枠が埋まった時の 503 にもセキュリティヘッダが付く', async () => {
  await withServer(async (s) => {
    const { MAX_SSE_CLIENTS } = await load('server.mjs');
    const open = [];
    try {
      for (let i = 0; i < MAX_SSE_CLIENTS; i += 1) open.push(await openStream(s.port));
      const over = await openStream(s.port);
      try {
        assert.equal(over.status, 503);
        assertSecurityHeaders(over.headers, 'SSE 503');
      } finally {
        over.destroy();
      }
    } finally {
      for (const o of open) o.destroy();
    }
  });
});

test('[headers] 500（導出が例外を投げる）にもセキュリティヘッダが付き、本文に内部情報が出ない', async () => {
  const dir = makeTmpDir();
  const { createServer } = await load('server.mjs');
  const handle = await createServer({
    port: 0, bind: '127.0.0.1', dbPath: join(dir, 'monitor.db'),
    derive: () => { throw new Error('SECRET_BOOM_/home/user'); },
  });
  try {
    const r = await request(handle.port, { path: '/api/state' });
    assert.equal(r.status, 500);
    assertSecurityHeaders(r.headers, '500');
    assert.ok(!r.body.includes('SECRET_BOOM') && !r.body.includes('/home/user'), `500 本文に内部情報: ${r.body}`);
  } finally {
    await handle.close();
  }
});

test('[headers] 静的ファイル・JSON のどちらでも、各ヘッダは 1 回だけ（重複送信で値が "a, a" にならない）', async () => {
  await withServer(async (s) => {
    for (const path of ['/', '/app.js', '/style.css', '/api/state', '/nope']) {
      const r = await requestBytes(s.port, { path });
      const names = r.rawHeaders.filter((_, i) => i % 2 === 0).map((n) => n.toLowerCase());
      for (const h of Object.keys(SECURITY_HEADERS)) {
        assert.equal(names.filter((n) => n === h).length, 1, `${path}: ${h} が ${names.filter((n) => n === h).length} 回`);
      }
    }
  });
});
