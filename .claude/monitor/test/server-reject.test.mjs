// 受信サーバの拒否系（Issue #19 / Red）。契約は server.test.mjs の冒頭コメントを見ろ。
// 全ケースで「4xx（指定のステータス）かつ DB の行数が増えない」ことを確認する。
// 変異テスト対応表も server.test.mjs 冒頭。ここは [Host] [Origin] [CT] [413] [schema] [ACAO] の各タグ。

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import {
  acaoHeaders, cleanupTmp, fixture, floodChunked, getState, openStream, postEvent, rawRequest, request, SID, withServer,
} from './helpers.mjs';

after(cleanupTmp);

const GOOD = () => fixture('SessionStart');
const base = (event, extra = {}) => ({ schema_version: 1, event, session_id: SID, ...extra });

const notAccepted = (status) => status === null || status >= 400;

// ---------- [Host] DNS リバインディング対策 ----------

test('[Host] 127.0.0.1:<port> と localhost:<port> は許可、それ以外は 403 で DB 行数不変（POST / GET state）', async () => {
  await withServer(async (s) => {
    const p = s.port;
    for (const host of [`127.0.0.1:${p}`, `localhost:${p}`]) {
      assert.equal((await postEvent(p, GOOD(), { headers: { Host: host } })).status, 201, host);
      assert.equal((await request(p, { path: '/api/state', headers: { Host: host } })).status, 200, host);
    }
    const accepted = s.store.count();
    const bad = [
      'evil.com', `evil.com:${p}`, `127.0.0.1:${p + 1}`, `localhost:${p + 1}`, `LOCALHOST:${p}`, `Localhost:${p}`,
      '127.0.0.1', 'localhost', `127.0.0.1.evil:${p}`, `127.0.0.1.evil.com:${p}`, `localhost.evil.com:${p}`,
      `evil127.0.0.1:${p}`, `127.0.0.1:${p}:80`, `127.0.0.1:${p}.evil`, `[::1]:${p}`, `0.0.0.0:${p}`, `127.0.0.2:${p}`,
      `127.1:${p}`, `2130706433:${p}`, `localhost:${p}@evil.com`, `evil.com@127.0.0.1:${p}`, `127.0.0.1:0${p}`,
      `127.0.0.1:${p},evil.com`, `127.0.0.1:${p}/`, `127.0.0.1:`,
    ];
    for (const host of bad) {
      const r1 = await postEvent(p, GOOD(), { headers: { Host: host } });
      assert.equal(r1.status, 403, `POST Host=${host} -> ${r1.status}`);
      const r2 = await request(p, { path: '/api/state', headers: { Host: host } });
      assert.equal(r2.status, 403, `GET Host=${host} -> ${r2.status}`);
    }
    assert.equal(s.store.count(), accepted, '拒否で行数が増えていない');
  });
});

test('[Host] Host が空・欠落（HTTP/1.0）・evil が先の重複でも 2xx にならず、行数は増えない', async () => {
  await withServer(async (s) => {
    const body = JSON.stringify(GOOD());
    const post = (host) => `POST /api/events HTTP/1.1\r\n${host}Content-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`;
    const cases = {
      空: post('Host: \r\n'),
      欠落_1_1: post(''),
      欠落_1_0: `POST /api/events HTTP/1.0\r\nContent-Type: application/json\r\nContent-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`,
      重複_evilが先: post(`Host: evil.com\r\nHost: 127.0.0.1:${s.port}\r\n`),
    };
    for (const [name, text] of Object.entries(cases)) {
      const r = await rawRequest(s.port, text);
      assert.ok(notAccepted(r.status), `${name}: ${r.status}`);
      assert.deepEqual(acaoHeaders(r.headers), [], name);
    }
    const g = await rawRequest(s.port, 'GET /api/state HTTP/1.0\r\n\r\n');
    assert.ok(notAccepted(g.status), `GET HTTP/1.0 Host 無し: ${g.status}`);
    assert.equal(s.store.count(), 0);
  });
});

test('[Host] SSE も Host を検査する（evil Host の /api/stream は 403）', async () => {
  await withServer(async (s) => {
    const stream = await openStream(s.port, { headers: { Host: `evil.com:${s.port}` } });
    assert.equal(stream.status, 403);
    stream.destroy();
  });
});

test('[Host] 未知のパス・許可外メソッドでも Host 検査が先（evil Host なら 404/405 ではなく 403）', async () => {
  await withServer(async (s) => {
    for (const [method, path] of [['GET', '/nope'], ['DELETE', '/api/events'], ['PUT', '/api/state']]) {
      const r = await request(s.port, { method, path, headers: { Host: 'evil.com' } });
      assert.equal(r.status, 403, `${method} ${path}`);
    }
  });
});

// ---------- [Origin] ----------

test('[Origin] 存在し同一オリジンでなければ 403。同一オリジンと Origin 無しは通る', async () => {
  await withServer(async (s) => {
    const p = s.port;
    assert.equal((await postEvent(p, GOOD())).status, 201, 'Origin 無し');
    assert.equal((await postEvent(p, GOOD(), { headers: { Origin: `http://127.0.0.1:${p}` } })).status, 201, '同一オリジン');
    assert.equal((await postEvent(p, GOOD(), { headers: { Host: `localhost:${p}`, Origin: `http://localhost:${p}` } })).status, 201, 'localhost 同一オリジン');
    const accepted = s.store.count();

    const bad = [
      'http://evil.com', `http://evil.com:${p}`, `http://localhost:${p}`, `https://127.0.0.1:${p}`, `http://127.0.0.1:${p}/`,
      'http://127.0.0.1', 'null', '', `http://127.0.0.1:${p}.evil.com`, `http://127.0.0.1.evil.com:${p}`, 'file://',
      `HTTP://127.0.0.1:${p}`, `http://127.0.0.1:${p + 1}`, `http://evil.com@127.0.0.1:${p}`,
    ];
    for (const origin of bad) {
      const r1 = await postEvent(p, GOOD(), { headers: { Origin: origin } });
      assert.equal(r1.status, 403, `POST Origin=${JSON.stringify(origin)} -> ${r1.status}`);
      const r2 = await request(p, { path: '/api/state', headers: { Origin: origin } });
      assert.equal(r2.status, 403, `GET Origin=${JSON.stringify(origin)} -> ${r2.status}`);
    }
    assert.equal(s.store.count(), accepted);
  });
});

test('[Origin] SSE も Origin を検査する（クロスオリジンの /api/stream は 403）', async () => {
  await withServer(async (s) => {
    const stream = await openStream(s.port, { headers: { Origin: 'http://evil.com' } });
    assert.equal(stream.status, 403);
    stream.destroy();
    const ok = await openStream(s.port, { headers: { Origin: `http://127.0.0.1:${s.port}` } });
    assert.equal(ok.status, 200);
    ok.destroy();
  });
});

test('[Origin] CORS プリフライト（OPTIONS）に応えない: クロスオリジンは 403、同一/無しは 405。Access-Control-* は無し', async () => {
  await withServer(async (s) => {
    const preflight = { Origin: 'http://evil.com', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type' };
    for (const path of ['/api/events', '/api/state', '/api/stream']) {
      const r = await request(s.port, { method: 'OPTIONS', path, headers: preflight });
      assert.equal(r.status, 403, `OPTIONS ${path}`);
      assert.deepEqual(acaoHeaders(r.headers), [], path);
    }
    for (const headers of [{}, { Origin: `http://127.0.0.1:${s.port}` }]) {
      const r = await request(s.port, { method: 'OPTIONS', path: '/api/events', headers });
      assert.equal(r.status, 405);
      assert.deepEqual(acaoHeaders(r.headers), []);
    }
  });
});

// ---------- [ACAO] どのレスポンスにも Access-Control-* を付けない ----------

test('[ACAO] 成功・各種エラー・404・405・SSE・OPTIONS の全レスポンスに Access-Control-* が無い（Origin 付きでも）', async () => {
  await withServer(async (s) => {
    const p = s.port;
    const origin = { Origin: `http://127.0.0.1:${p}` };
    const responses = [
      await postEvent(p, GOOD(), { headers: origin }),
      await postEvent(p, GOOD()),
      await postEvent(p, null, { raw: '{' }),
      await postEvent(p, GOOD(), { headers: { 'Content-Type': 'text/plain' } }),
      await postEvent(p, null, { raw: `${JSON.stringify(GOOD())}${' '.repeat(65_536)}` }),
      await postEvent(p, GOOD(), { headers: { Host: 'evil.com' } }),
      await postEvent(p, GOOD(), { headers: { Origin: 'http://evil.com' } }),
      await request(p, { path: '/api/state', headers: origin }),
      await request(p, { path: '/nope', headers: origin }),
      await request(p, { method: 'DELETE', path: '/api/events', headers: origin }),
      await request(p, { method: 'OPTIONS', path: '/api/events', headers: origin }),
    ];
    for (const r of responses) assert.deepEqual(acaoHeaders(r.headers), [], `status ${r.status}`);
    const stream = await openStream(p, { headers: origin });
    assert.equal(stream.status, 200);
    assert.deepEqual(acaoHeaders(stream.headers), [], 'SSE');
    stream.destroy();
  });
});

// ---------- [CT] Content-Type ----------

test('[CT] application/json と charset 付きは受理。それ以外は 415 で行数不変', async () => {
  await withServer(async (s) => {
    for (const ct of ['application/json', 'application/json; charset=utf-8', 'application/json;charset=UTF-8']) {
      assert.equal((await postEvent(s.port, GOOD(), { headers: { 'Content-Type': ct } })).status, 201, ct);
    }
    const accepted = s.store.count();
    const bad = [
      'text/plain', 'application/x-www-form-urlencoded', 'multipart/form-data; boundary=x', 'text/plain; x=application/json',
      'text/plain;application/json', 'application/jsonx', 'application/json-patch+json', 'application/xml', 'text/json', 'json', '*/*',
      'application/ json', 'application/jsonp',
    ];
    for (const ct of bad) {
      const r = await postEvent(s.port, GOOD(), { headers: { 'Content-Type': ct } });
      assert.equal(r.status, 415, `Content-Type=${ct} -> ${r.status}`);
    }
    // 欠落（postEvent は既定で付けるので request で直接）
    const none = await request(s.port, { method: 'POST', path: '/api/events', body: JSON.stringify(GOOD()) });
    assert.equal(none.status, 415, 'Content-Type 欠落');
    assert.equal(s.store.count(), accepted);
  });
});

// ---------- [413] ボディ上限 ----------

const padded = (totalBytes) => {
  const core = JSON.stringify(GOOD());
  return core + ' '.repeat(totalBytes - Buffer.byteLength(core));
};

test('[413] ちょうど 65536 バイトは受理、65537 バイトは 413 で行数不変', async () => {
  await withServer(async (s) => {
    const ok = await postEvent(s.port, null, { raw: padded(65_536) });
    assert.equal(ok.status, 201);
    const before = s.store.count();
    const over = await postEvent(s.port, null, { raw: padded(65_537) });
    assert.equal(over.status, 413);
    assert.equal(s.store.count(), before);
  });
});

test('[413] Content-Length で巨大ボディを宣言したら、本体の到着を待たずに 413 を返す', async () => {
  await withServer(async (s) => {
    const text = `POST /api/events HTTP/1.1\r\nHost: 127.0.0.1:${s.port}\r\nContent-Type: application/json\r\nContent-Length: 10485760\r\nConnection: close\r\n\r\n${'{'.repeat(100)}`;
    const r = await rawRequest(s.port, text, { timeout: 2500 });
    assert.equal(r.status, 413, `本体を待ってしまった/別の応答: ${r.status}`);
    assert.equal(s.store.count(), 0);
  });
});

test('[413] chunked で送り続けても、上限到達時点で読み取りを打ち切り接続を終える（全部は食わない）', async () => {
  await withServer(async (s) => {
    const r = await floodChunked(s.port, { capBytes: 8 * 1024 * 1024 });
    assert.equal(r.closed, true, '接続が早期に終わっていない（読み続けている）');
    // 未読データを残したまま閉じると TCP の RST で 413 本文がクライアントに届かないことがある。
    // 413 が読めた場合は 413 であること。読めなかった場合も、接続が上限で打ち切られたことは上で検査済み
    assert.ok(r.status === 413 || r.status === null, `413 以外の応答: ${r.status}`);
    assert.ok(r.sent < 8 * 1024 * 1024, `送信できたのが ${r.sent} バイト。上限なしで読み続けている`);
    assert.equal(s.store.count(), 0);
    assert.equal((await postEvent(s.port, GOOD())).status, 201, '打ち切り後もサーバは健在');
  });
});

// ---------- 不正 JSON / スキーマ ----------

test('[schema] 不正 JSON・空ボディは 400 で行数不変', async () => {
  await withServer(async (s) => {
    const bad = ['{', '', 'not json', `${JSON.stringify(GOOD())}x`, "{'a':1}", `{"schema_version":1,"event":"Stop","session_id":"${SID}",}`, '\u0000'];
    for (const raw of bad) {
      const r = await postEvent(s.port, null, { raw });
      assert.equal(r.status, 400, `${JSON.stringify(raw)} -> ${r.status}`);
    }
    assert.equal(s.store.count(), 0);
  });
});

test('[schema] スキーマ外キー・型違い・列挙外・最大長超過・必須欠落・非オブジェクトは 400 で行数不変', async () => {
  await withServer(async (s) => {
    const bad = {
      未知キー_cwd: { ...GOOD(), cwd: 'x' },
      未知キー_prompt: { ...GOOD(), prompt: 'x' },
      未知キー_proto: JSON.parse(`{"schema_version":1,"event":"Stop","session_id":"${SID}","__proto__":{"a":1}}`),
      型違い_session_id: { ...GOOD(), session_id: 123 },
      型違い_schema_version: { ...GOOD(), schema_version: '1' },
      列挙外_event: { ...GOOD(), event: 'Foo' },
      最大長超過_session_id: { ...GOOD(), session_id: 'a'.repeat(65) },
      最大長超過_file_path: base('PreToolUse', { tool_name: 'Read', tool_use_id: 't1', file_path: 'a'.repeat(129) }),
      最大長超過_bash_command: base('PreToolUse', { tool_name: 'Bash', tool_use_id: 't1', bash_command: 'a'.repeat(33) }),
      必須欠落_tool_use_id: base('PreToolUse', { tool_name: 'Read' }),
      イベント外キー: base('Stop', { tool_name: 'Read' }),
      配列: [GOOD()],
      null: null,
      文字列: 'x',
      空オブジェクト: {},
    };
    for (const [name, obj] of Object.entries(bad)) {
      const r = await postEvent(s.port, obj);
      assert.equal(r.status, 400, `${name} -> ${r.status} ${r.body}`);
    }
    assert.equal(s.store.count(), 0);
    assert.deepEqual((await getState(s.port)).json.sessions, []);
  });
});

test('[schema] 境界: session_id ちょうど 64 は 201、65 は 400（HTTP 経由でも同じ）', async () => {
  await withServer(async (s) => {
    assert.equal((await postEvent(s.port, base('Stop', { session_id: 'a'.repeat(64) }))).status, 201);
    assert.equal((await postEvent(s.port, base('Stop', { session_id: 'a'.repeat(65) }))).status, 400);
    assert.equal(s.store.count(), 1);
  });
});

test('[schema] 拒否レスポンスの本文に入力値（秘密かもしれない）を含めない', async () => {
  await withServer(async (s) => {
    const marker = 'SECRETMARKER_k4p9';
    for (const obj of [{ ...GOOD(), session_id: `bad ${marker}` }, { ...GOOD(), [marker]: 1 }, { ...GOOD(), event: marker }]) {
      const r = await postEvent(s.port, obj);
      assert.equal(r.status, 400);
      assert.ok(!r.body.includes(marker), `拒否本文に入力値が載った: ${r.body}`);
    }
    const r2 = await postEvent(s.port, null, { raw: `{"x":"${marker}` });
    assert.ok(!r2.body.includes(marker));
  });
});

test('[route] 未知のパスは 404、許可外メソッドは 405（Host / Origin が正しい時）', async () => {
  await withServer(async (s) => {
    assert.equal((await request(s.port, { path: '/nope' })).status, 404);
    assert.equal((await request(s.port, { path: '/api/events' })).status, 405, 'GET /api/events');
    assert.equal((await request(s.port, { method: 'POST', path: '/api/state', headers: { 'Content-Type': 'application/json' }, body: '{}' })).status, 405);
    assert.equal((await request(s.port, { method: 'DELETE', path: '/api/events' })).status, 405);
    assert.equal(s.store.count(), 0);
  });
});
