// Sec-Fetch-Site 検査と /api/state キャッシュ（Issue #19 / G5 差し戻し retry 1）。契約は server.test.mjs の冒頭コメント。
//
// 攻撃: <img src="http://127.0.0.1:4319/api/stream"> のような no-cors サブリソース GET は Origin を付けず、
// Host は正しい。Host / Origin 検査を両方通り、SSE 16 枠の占有と /api/state の連打（毎回全行を同期導出）で
// イベントループを止められる。ブラウザは必ず Sec-Fetch-Site を付ける（偽装不可・forbidden header）ので、
// 「ヘッダがあり same-origin / none 以外」を 403 にする。ヘッダ無し（curl・フック・同一端末のプロセス）は通す。

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import {
  acaoHeaders, cleanupTmp, fixture, getState, load, openStream, postEvent, rawRequest, request, SID, withServer,
} from './helpers.mjs';

after(cleanupTmp);

const GOOD = () => fixture('SessionStart');
const FETCH_SITE = (v) => ({ 'Sec-Fetch-Site': v });
const DENIED = ['cross-site', 'same-site'];
const ALLOWED = ['same-origin', 'none'];
// 完全一致のみ。大小文字違い・前後の語・複数値・未知の値・空は拒否
const SLOPPY = ['Same-Origin', 'SAME-ORIGIN', 'None', 'NONE', 'same-origin, cross-site', 'cross-site, same-origin',
  'same-origin,same-origin', 'same-origin;x=1', 'same_origin', 'sameorigin', 'same-origins', 'cross-site;none', 'unknown', '*', ''];

// ---------- 自己診断（lessons #5）: 検査対象の経路が本当に 2xx を返す。全部 403 のサーバで全部 PASS しない ----------

test('[FetchSite 自己診断] ヘッダ無し・same-origin・none では全経路が従来どおり通る（403 固定の実装を弾く）', async () => {
  await withServer(async (s) => {
    for (const headers of [{}, ...ALLOWED.map(FETCH_SITE)]) {
      const label = JSON.stringify(headers);
      assert.equal((await postEvent(s.port, GOOD(), { headers })).status, 201, `POST ${label}`);
      assert.equal((await request(s.port, { path: '/api/state', headers })).status, 200, `state ${label}`);
      assert.equal((await request(s.port, { path: '/nope', headers })).status, 404, `404 ${label}`);
      assert.equal((await request(s.port, { method: 'DELETE', path: '/api/events', headers })).status, 405, `405 ${label}`);
      const st = await openStream(s.port, { headers });
      try { assert.equal(st.status, 200, `stream ${label}`); } finally { st.destroy(); }
    }
  });
});

// ---------- 拒否 ----------

for (const value of DENIED) {
  test(`[FetchSite] Sec-Fetch-Site: ${value} は全経路で 403（stream / state / POST / 未知パス / 許可外メソッド）。DB 行数不変`, async () => {
    await withServer(async (s) => {
      const headers = FETCH_SITE(value);
      const stream = await openStream(s.port, { headers });
      try { assert.equal(stream.status, 403, 'GET /api/stream'); } finally { stream.destroy(); }
      assert.equal((await request(s.port, { path: '/api/state', headers })).status, 403, 'GET /api/state');
      assert.equal((await postEvent(s.port, GOOD(), { headers })).status, 403, 'POST /api/events');
      assert.equal((await request(s.port, { path: '/nope', headers })).status, 403, '未知パスは 404 でなく 403（ルート判定より前）');
      assert.equal((await request(s.port, { method: 'DELETE', path: '/api/events', headers })).status, 403, '許可外メソッドは 405 でなく 403');
      assert.equal((await request(s.port, { method: 'OPTIONS', path: '/api/events', headers })).status, 403, 'OPTIONS');
      // 検査の順序: Content-Type 不正でも 415 でなく 403（ボディを読む前に弾く）
      const ct = await postEvent(s.port, GOOD(), { headers: { ...headers, 'Content-Type': 'text/plain' } });
      assert.equal(ct.status, 403, 'CT 不正でも 403');
      assert.equal(s.store.count(), 0, '拒否で行数が増えていない');
    });
  });
}

test('[FetchSite] 値は完全一致のみ。大小文字違い・複数値・未知の値・空は 403（same-site も含め許可は same-origin / none だけ）', async () => {
  await withServer(async (s) => {
    for (const value of SLOPPY) {
      const g = await request(s.port, { path: '/api/state', headers: FETCH_SITE(value) });
      assert.equal(g.status, 403, `GET state Sec-Fetch-Site=${JSON.stringify(value)} -> ${g.status}`);
      const p = await postEvent(s.port, GOOD(), { headers: FETCH_SITE(value) });
      assert.equal(p.status, 403, `POST Sec-Fetch-Site=${JSON.stringify(value)} -> ${p.status}`);
    }
    assert.equal(s.store.count(), 0);
  });
});

test('[FetchSite] ヘッダが重複（same-origin と cross-site）していても 403（先頭だけ見て通さない）', async () => {
  await withServer(async (s) => {
    for (const order of [['same-origin', 'cross-site'], ['cross-site', 'same-origin'], ['none', 'same-site']]) {
      const text = `GET /api/state HTTP/1.1\r\nHost: 127.0.0.1:${s.port}\r\nSec-Fetch-Site: ${order[0]}\r\nSec-Fetch-Site: ${order[1]}\r\nConnection: close\r\n\r\n`;
      const r = await rawRequest(s.port, text);
      assert.equal(r.status, 403, `${order.join(' + ')} -> ${r.status}`);
    }
  });
});

test('[FetchSite] 名前の大小文字を変えても（sec-fetch-site / SEC-FETCH-SITE）同じ扱い。cross-site は 403', async () => {
  await withServer(async (s) => {
    for (const name of ['sec-fetch-site', 'SEC-FETCH-SITE', 'Sec-fetch-Site']) {
      const text = `GET /api/state HTTP/1.1\r\nHost: 127.0.0.1:${s.port}\r\n${name}: cross-site\r\nConnection: close\r\n\r\n`;
      assert.equal((await rawRequest(s.port, text)).status, 403, name);
    }
  });
});

test('[FetchSite] Origin 無し・Host 正常・cross-site / no-cors の GET（PoC の再現）は 403。SSE の枠を消費しない', async () => {
  await withServer(async (s) => {
    const poc = { 'Sec-Fetch-Site': 'cross-site', 'Sec-Fetch-Mode': 'no-cors', 'Sec-Fetch-Dest': 'image', Accept: 'image/*' };
    const open = [];
    try {
      for (let i = 0; i < 40; i += 1) {
        const r = await openStream(s.port, { headers: poc });
        open.push(r);
        assert.equal(r.status, 403, `PoC #${i}`);
      }
      // 40 本投げた後でも、正規の接続が MAX_SSE_CLIENTS 本まで 200 で開ける（枠を食われていない）
      const { MAX_SSE_CLIENTS } = await load('server.mjs');
      const legit = [];
      try {
        for (let i = 0; i < MAX_SSE_CLIENTS; i += 1) {
          const r = await openStream(s.port);
          legit.push(r);
          assert.equal(r.status, 200, `正規の接続 #${i}`);
        }
        const over = await openStream(s.port);
        legit.push(over);
        assert.equal(over.status, 503, '上限超過は従来どおり 503');
      } finally { for (const r of legit) r.destroy(); }
    } finally { for (const r of open) r.destroy(); }
  });
});

test('[FetchSite] cross-site の 403 に Access-Control-* が付かない。same-origin / none / 無しの成功にも付かない', async () => {
  await withServer(async (s) => {
    for (const value of [...DENIED, ...ALLOWED, undefined]) {
      const headers = value === undefined ? {} : FETCH_SITE(value);
      for (const r of [await request(s.port, { path: '/api/state', headers }), await postEvent(s.port, GOOD(), { headers })]) {
        assert.deepEqual(acaoHeaders(r.headers), [], `Sec-Fetch-Site=${value}: ${r.status}`);
      }
    }
  });
});

test('[FetchSite] 403 の本文は固定文言で、ヘッダ値（マーカー）を載せない', async () => {
  await withServer(async (s) => {
    const r = await request(s.port, { path: '/api/state', headers: FETCH_SITE('cross-site-MARKER_q7f2') });
    assert.equal(r.status, 403);
    assert.ok(!r.body.includes('MARKER_q7f2'), r.body);
    const parsed = JSON.parse(r.body);
    assert.equal(parsed.data, null);
    assert.equal(parsed.error.code, 'FORBIDDEN');
  });
});

test('[FetchSite] Host 検査は従来どおり先。evil Host + same-origin は 403（same-origin を名乗っても Host は免除されない）', async () => {
  await withServer(async (s) => {
    const r = await request(s.port, { path: '/api/state', headers: { Host: 'evil.com', ...FETCH_SITE('same-origin') } });
    assert.equal(r.status, 403);
  });
});

// ---------- CPU: /api/state の導出キャッシュ ----------
// 契約: createServer({ derive }) で導出関数（既定は derive.mjs の deriveState）を注入できる。
//       同じ last_seq の間は derive を再実行しない。seq が進んだ（新着の POST が成功した）時だけ作り直す。

async function countingDerive() {
  const { deriveState } = await load('derive.mjs');
  const counter = { calls: 0 };
  const derive = (records) => { counter.calls += 1; return deriveState(records); };
  return { derive, counter };
}

test('[cache] 同じ last_seq の間は導出を再実行しない（連打しても derive は増えない）。注入した関数が実際に使われる', async () => {
  const { derive, counter } = await countingDerive();
  await withServer(async (s) => {
    for (const name of ['SessionStart', 'UserPromptSubmit']) assert.equal((await postEvent(s.port, fixture(name))).status, 201);
    const first = await getState(s.port);
    assert.equal(first.status, 200);
    // 注入が効いていること（0 回なら注入口が無視されている。キャッシュが効いているのと区別する）
    assert.equal(counter.calls, 1, `初回の GET で derive が 1 回呼ばれる。実際 ${counter.calls}（注入口 derive が無視されている可能性）`);
    for (let i = 0; i < 20; i += 1) {
      const again = await getState(s.port);
      assert.deepEqual(again.json, first.json);
    }
    assert.equal(counter.calls, 1, `20 回連打して導出が再実行された: ${counter.calls}`);
  }, { derive });
});

test('[cache] 新着 POST の後は最新状態が返る（陳腐化しない）。作り直しは seq が進んだ回だけ', async () => {
  const { derive, counter } = await countingDerive();
  await withServer(async (s) => {
    assert.equal((await postEvent(s.port, fixture('SessionStart'))).status, 201);
    const a = await getState(s.port);
    assert.equal(a.json.sessions.length, 1);
    const callsAfterA = counter.calls;
    assert.equal(callsAfterA, 1);

    // 状態が変わる系列を 1 件ずつ POST し、直後の GET が必ず最新の last_seq / 状態を返すこと
    let prevSeq = a.json.last_seq;
    for (const name of ['UserPromptSubmit', 'SubagentStart', 'Stop', 'SessionEnd']) {
      assert.equal((await postEvent(s.port, fixture(name))).status, 201, name);
      const st = await getState(s.port);
      assert.ok(st.json.last_seq > prevSeq, `${name}: last_seq が進んでいない（古いキャッシュ）`);
      assert.equal(st.json.last_seq, s.store.list().at(-1).seq, `${name}: DB の最新 seq と一致`);
      prevSeq = st.json.last_seq;
      await getState(s.port); // 同じ seq の 2 回目はキャッシュ
    }
    assert.equal((await getState(s.port)).json.sessions[0].status, 'ended', 'SessionEnd 後の状態が反映されている');
    // GET が計 1 + 4*2 + 1 回あっても、導出は seq が進んだ 1 + 4 回だけ
    assert.equal(counter.calls, 5, `導出は seq が進むたびに 1 回: ${counter.calls}`);
  }, { derive });
});

test('[cache] 拒否された POST（seq が進まない）ではキャッシュを捨てない。DB に直接追記した場合は次の GET で反映', async () => {
  const { derive, counter } = await countingDerive();
  await withServer(async (s) => {
    await postEvent(s.port, fixture('SessionStart'));
    await getState(s.port);
    assert.equal(counter.calls, 1);
    assert.equal((await postEvent(s.port, { ...GOOD(), cwd: '/x' })).status, 400);
    assert.equal((await postEvent(s.port, GOOD(), { headers: { 'Sec-Fetch-Site': 'cross-site' } })).status, 403);
    await getState(s.port);
    assert.equal(counter.calls, 1, '拒否された POST で導出が走った');

    // seq は DB が決める。サーバ経由でない追記（別経路・将来の取り込み）でも、last_seq が進めば作り直す
    s.store.append({ schema_version: 1, event: 'Stop', session_id: SID });
    const st = await getState(s.port);
    assert.equal(counter.calls, 2);
    assert.equal(st.json.last_seq, s.store.list().at(-1).seq);
  }, { derive });
});

test('[cache] 空の DB（last_seq 0）でも連打で導出を繰り返さず、1 件目の POST 後は反映される', async () => {
  const { derive, counter } = await countingDerive();
  await withServer(async (s) => {
    for (let i = 0; i < 5; i += 1) {
      const st = await getState(s.port);
      assert.deepEqual(st.json, { sessions: [], last_seq: 0 });
    }
    assert.equal(counter.calls, 1, `空 DB で連打して導出が ${counter.calls} 回`);
    await postEvent(s.port, fixture('SessionStart'));
    assert.equal((await getState(s.port)).json.sessions.length, 1, '空の結果がキャッシュされたまま');
    assert.equal(counter.calls, 2);
  }, { derive });
});
