// GET /api/stream（SSE）のテスト（Issue #19 / Red）。契約は server.test.mjs の冒頭コメントを見ろ。

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { cleanupTmp, fixture, load, openStream, parseSse, postEvent, SID, sleep, startServer, withServer } from './helpers.mjs';

after(cleanupTmp);

test('[SSE] 接続直後に 200 / text/event-stream / no-cache のヘッダが返る', async () => {
  await withServer(async (s) => {
    const st = await openStream(s.port);
    assert.equal(st.status, 200);
    assert.match(st.headers['content-type'] ?? '', /^text\/event-stream/);
    assert.match(st.headers['cache-control'] ?? '', /no-cache/);
    st.destroy();
  });
});

test('[SSE] 受理した新着イベントを `id: <seq>` と `data: <Record の JSON>` で配信する', async () => {
  await withServer(async (s) => {
    const st = await openStream(s.port);
    const r = await postEvent(s.port, fixture('PreToolUse.bash'));
    assert.equal(r.status, 201);
    await st.waitFor((t) => t.includes('toolu_dummy0000000000000000001'));
    const [rec] = parseSse(st.text);
    assert.equal(rec.event, 'PreToolUse');
    assert.equal(rec.session_id, SID);
    assert.equal(rec.bash_command, 'ls');
    assert.equal(typeof rec.seq, 'number');
    assert.equal(typeof rec.received_at, 'number');
    assert.equal(rec.seq, s.store.list().at(-1).seq);
    assert.match(st.text, new RegExp(`(^|\\n)id: ${rec.seq}\\n`));
    st.destroy();
  });
});

test('[SSE] 拒否されたイベントは配信されない。受理されたものだけが seq 順に届く', async () => {
  await withServer(async (s) => {
    const st = await openStream(s.port);
    await postEvent(s.port, { ...fixture('SessionStart'), cwd: '/x' }); // 400
    await postEvent(s.port, fixture('UserPromptSubmit'));
    await postEvent(s.port, fixture('Stop'));
    await st.waitFor((t) => parseSse(t).length >= 2);
    const recs = parseSse(st.text);
    assert.deepEqual(recs.map((r) => r.event), ['UserPromptSubmit', 'Stop']);
    assert.ok(recs[0].seq < recs[1].seq);
    st.destroy();
  });
});

test('[SSE] 複数クライアントに同じ新着が届く', async () => {
  await withServer(async (s) => {
    const a = await openStream(s.port);
    const b = await openStream(s.port);
    await postEvent(s.port, fixture('UserPromptSubmit'));
    await Promise.all([a, b].map((c) => c.waitFor((t) => parseSse(t).length >= 1)));
    assert.equal(parseSse(a.text)[0].seq, parseSse(b.text)[0].seq);
    a.destroy();
    b.destroy();
  });
});

test('[SSE] 同時接続 16 まで受理、17 本目は 503。切断すると枠が戻る', async () => {
  await withServer(async (s) => {
    const { MAX_SSE_CLIENTS } = await load('server.mjs');
    assert.equal(MAX_SSE_CLIENTS, 16);
    const open = [];
    for (let i = 0; i < 16; i += 1) {
      const c = await openStream(s.port);
      assert.equal(c.status, 200, `${i + 1} 本目`);
      open.push(c);
    }
    const over = await openStream(s.port);
    assert.equal(over.status, 503, '17 本目');
    await over.waitEnd();
    assert.ok(!/at .*\.mjs|node:|Error:/.test(over.text), `503 本文に内部情報: ${over.text}`);
    assert.deepEqual(Object.keys(over.headers).filter((k) => k.startsWith('access-control-')), []);

    // 503 になった接続は枠を食わない。1本切れば、すぐ1本入れる
    open.shift().destroy();
    let again;
    for (let i = 0; i < 60 && !again; i += 1) {
      const c = await openStream(s.port);
      if (c.status === 200) again = c;
      else { c.destroy(); await sleep(50); }
    }
    assert.ok(again, '切断後に枠が戻らない（接続数のリーク）');
    // 17 本目（again 込みで 16）が満杯に戻っていること
    const full = await openStream(s.port);
    assert.equal(full.status, 503);
    full.destroy();
    again.destroy();
    for (const c of open) c.destroy();
  });
});

test('[SSE] 切断を繰り返しても枠が漏れない（20 回接続・切断してから 16 本張れる）', async () => {
  await withServer(async (s) => {
    for (let i = 0; i < 20; i += 1) {
      const c = await openStream(s.port);
      assert.equal(c.status, 200);
      c.destroy();
    }
    await sleep(200);
    const open = [];
    for (let i = 0; i < 16; i += 1) {
      const c = await openStream(s.port);
      assert.equal(c.status, 200, `${i + 1} 本目`);
      open.push(c);
    }
    for (const c of open) c.destroy();
  });
});

test('[SSE] サーバの close() は開いている SSE 接続も切って完了する（ハングしない）', async () => {
  const s = await startServer();
  const c1 = await openStream(s.port);
  const c2 = await openStream(s.port);
  const closed = await Promise.race([s.close().then(() => 'closed'), sleep(4000).then(() => 'timeout')]);
  assert.equal(closed, 'closed');
  await c1.waitEnd();
  await c2.waitEnd();
});
