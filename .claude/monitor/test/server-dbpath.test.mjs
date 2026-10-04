// DB パスのリンク拒否とパーミッション（Issue #19 / G5 差し戻し retry 1）。契約は server.test.mjs の冒頭コメント。
//
// 攻撃: .claude/monitor/data がコミットされたシンボリックリンクだと、mkdirSync と new DatabaseSync がリンクを辿り、
// リンク先に SQLite を作る・既存ファイルを DB として開いて改変する。lessons #11（リンクは追わない）/ #10（ダングリングを
// 「存在しない」と誤判定して書き込む）。値の行き先（#11）: ディレクトリ・DB 本体・-wal / -shm・リンク先の 4 つを全部数える。

import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import {
  existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, realpathSync, statSync, symlinkSync, writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import {
  cleanupTmp, createWithDataDir, fixture, load, makeTmpDir, makeVictimDb, postEvent, runCliExpectExit, startServer,
} from './helpers.mjs';

after(cleanupTmp);

const mode = (p) => statSync(p).mode & 0o777;
const KEEP = 'KEEP-ME: SQLite ではない既存ファイル（改変・上書きされたら FAIL）';
const sameBytes = (path, original) => readFileSync(path).equals(original);

/** 一時ディレクトリに「既定パス相当」を用意する。tmp/data が dataDir、tmp/outside がリンク先 */
function layout() {
  const tmp = realpathSync(makeTmpDir()); // macOS の /var → /private/var を先に解決（祖先のリンクを検査対象にしない）
  const outside = join(tmp, 'outside');
  mkdirSync(outside);
  return { tmp, outside, dataDir: join(tmp, 'data') };
}

async function assertRejected(promise, ...secrets) {
  let handle = null;
  try {
    handle = await promise;
  } catch (err) {
    assert.notEqual(err?.name, 'DataDirIgnoredError', err?.message);
    const text = `${err?.message ?? ''}`;
    for (const s of secrets) assert.ok(!text.includes(s), `エラー文言にパスが載った: ${text}`);
    return;
  }
  await handle.close();
  assert.fail('リンクを辿って起動してしまった（reject / throw されるべき）');
}

// ---------- 自己診断: 正常系は通る。何でも reject する実装を弾く ----------

test('[link 自己診断] リンクの無い dataDir（未作成・作成済み）では起動でき、DB は dataDir の中に作られる', async () => {
  const { dataDir, tmp } = layout();
  const h = await createWithDataDir(dataDir);
  try {
    assert.ok(existsSync(join(dataDir, 'monitor.db')), 'dataDir/monitor.db が無い');
    assert.equal((await postEvent(h.port, fixture('SessionStart'))).status, 201);
  } finally { await h.close(); }
  const again = await createWithDataDir(dataDir); // 作成済みでも起動できる（冪等）
  await again.close();
  assert.ok(readdirSync(tmp).sort().join() === 'data,outside', `dataDir 以外が作られた: ${readdirSync(tmp)}`);
});

// ---------- リンク拒否（既定パス = dataDir 経路） ----------

test('[link] dataDir がシンボリックリンクなら起動を拒否し、リンク先に何も作らない', async () => {
  const { dataDir, outside, tmp } = layout();
  symlinkSync(outside, dataDir);
  assert.ok(lstatSync(dataDir).isSymbolicLink());
  await assertRejected(createWithDataDir(dataDir), tmp);
  assert.deepEqual(readdirSync(outside), [], 'リンク先に SQLite ファイルが作られた');
});

test('[link] dataDir がダングリングリンク（リンク先が存在しない）でも拒否し、リンク先を作らない', async () => {
  const { dataDir, tmp } = layout();
  const missing = join(tmp, 'not-yet', 'deep');
  symlinkSync(missing, dataDir);
  await assertRejected(createWithDataDir(dataDir), tmp);
  assert.ok(!existsSync(join(tmp, 'not-yet')), 'ダングリングの行き先ディレクトリが作られた（mkdir が辿った）');
});

test('[link] dataDir の親がシンボリックリンクなら拒否（realpath が親の実体 + 名前に一致しない）。実体側に作らない', async () => {
  const { tmp, outside } = layout();
  symlinkSync(outside, join(tmp, 'sub'));
  await assertRejected(createWithDataDir(join(tmp, 'sub', 'data')), tmp);
  assert.deepEqual(readdirSync(outside), [], '親リンクを辿って実体側に作られた');
});

test('[link] DB ファイルがシンボリックリンクなら拒否し、リンク先の既存ファイルを開かない・改変しない', async () => {
  const { dataDir, outside, tmp } = layout();
  mkdirSync(dataDir, { mode: 0o700 });
  const victim = join(outside, 'victim.db');
  const original = makeVictimDb(victim);
  symlinkSync(victim, join(dataDir, 'monitor.db'));
  await assertRejected(createWithDataDir(dataDir), tmp);
  assert.ok(sameBytes(victim, original), 'リンク先の既存 SQLite が開かれ、テーブル作成等で改変された');
  assert.deepEqual(readdirSync(outside), ['victim.db'], 'リンク先の隣に -wal / -journal 等が作られた');
});

test('[link] DB ファイルがダングリングリンクでも拒否し、リンク先を新規作成しない（「存在しない」と誤判定して書かない）', async () => {
  const { dataDir, outside, tmp } = layout();
  mkdirSync(dataDir, { mode: 0o700 });
  const target = join(outside, 'created-by-attacker.db');
  symlinkSync(target, join(dataDir, 'monitor.db'));
  await assertRejected(createWithDataDir(dataDir), tmp);
  assert.ok(!existsSync(target), 'ダングリングの行き先に DB が作られた');
  assert.deepEqual(readdirSync(outside), []);
});

test('[link] -wal / -shm / -journal がリンクでも拒否（行き先は DB 本体だけではない）', async () => {
  for (const suffix of ['-wal', '-shm', '-journal']) {
    const { dataDir, outside, tmp } = layout();
    mkdirSync(dataDir, { mode: 0o700 });
    const victim = join(outside, `victim${suffix}`);
    writeFileSync(victim, KEEP);
    symlinkSync(victim, join(dataDir, `monitor.db${suffix}`));
    await assertRejected(createWithDataDir(dataDir), tmp);
    assert.equal(readFileSync(victim, 'utf8'), KEEP, `${suffix} のリンク先が改変された`);
  }
});

// ---------- 明示指定（dbPath / MONITOR_DB）も同じく拒否（fail closed。契約で決定） ----------

test('[link] 明示 dbPath でも、DB ファイルがリンク（実在・ダングリング）なら拒否し、リンク先を触らない', async () => {
  const { tmp, outside } = layout();
  const { createServer } = await load('server.mjs');
  const victim = join(outside, 'victim.db');
  const original = makeVictimDb(victim);
  symlinkSync(victim, join(tmp, 'link.db'));
  symlinkSync(join(outside, 'new.db'), join(tmp, 'dangling.db'));
  for (const name of ['link.db', 'dangling.db']) {
    await assertRejected(createServer({ port: 0, bind: '127.0.0.1', dbPath: join(tmp, name) }), tmp);
  }
  assert.ok(sameBytes(victim, original), 'リンク先の既存 SQLite が改変された');
  assert.deepEqual(readdirSync(outside), ['victim.db']);
});

test('[link] 明示 dbPath でも、直接の親ディレクトリがリンクなら拒否し、実体側に作らない', async () => {
  const { tmp, outside } = layout();
  const { createServer } = await load('server.mjs');
  symlinkSync(outside, join(tmp, 'linkdir'));
  await assertRejected(createServer({ port: 0, bind: '127.0.0.1', dbPath: join(tmp, 'linkdir', 'monitor.db') }), tmp);
  assert.deepEqual(readdirSync(outside), []);
});

for (const kind of ['file', 'dangling', 'dir']) {
  test(`[link CLI] MONITOR_DB が ${kind} のリンクなら非0で終了し、listen せず、固定文言だけを出す（パスを載せない）`, async () => {
    const { tmp, outside } = layout();
    let dbEnv;
    let original = null;
    if (kind === 'file') {
      original = makeVictimDb(join(outside, 'victim.db'));
      symlinkSync(join(outside, 'victim.db'), join(tmp, 'l.db'));
      dbEnv = join(tmp, 'l.db');
    } else if (kind === 'dangling') {
      symlinkSync(join(outside, 'new.db'), join(tmp, 'l.db'));
      dbEnv = join(tmp, 'l.db');
    } else {
      symlinkSync(outside, join(tmp, 'linkdir'));
      dbEnv = join(tmp, 'linkdir', 'monitor.db');
    }
    const r = await runCliExpectExit({ MONITOR_DB: dbEnv });
    assert.equal(r.listening, false, 'リンクを辿って listen した');
    assert.notEqual(r.code, 0, `終了コード ${r.code}`);
    assert.equal(r.out.stdout, '', `stdout に出力: ${r.out.stdout}`);
    assert.equal(r.out.stderr.trim(), 'monitor server failed to start', `stderr: ${r.out.stderr}`);
    assert.ok(!r.out.stderr.includes(tmp));
    assert.ok(!existsSync(join(outside, 'new.db')));
    if (kind === 'file') assert.ok(sameBytes(join(outside, 'victim.db'), original), 'リンク先の既存 SQLite が改変された');
  });
}

// ---------- パーミッション ----------

test('[mode] dataDir を新規作成するとき 0700、DB ファイルは 0600（-wal / -shm があればそれも group / other 不可）', async () => {
  const { dataDir } = layout();
  const h = await createWithDataDir(dataDir);
  try {
    assert.equal((await postEvent(h.port, fixture('SessionStart'))).status, 201);
    assert.equal(mode(dataDir).toString(8), '700', 'dataDir');
    assert.equal(mode(join(dataDir, 'monitor.db')).toString(8), '600', 'monitor.db');
    for (const f of readdirSync(dataDir)) {
      assert.equal(mode(join(dataDir, f)) & 0o077, 0, `${f} が group / other に開いている: ${mode(join(dataDir, f)).toString(8)}`);
    }
  } finally { await h.close(); }
});

test('[mode] 親が無い dataDir（再帰作成）でも作成したディレクトリは 0700', async () => {
  const { tmp } = layout();
  const dataDir = join(tmp, 'a', 'b', 'data');
  const h = await createWithDataDir(dataDir);
  try {
    for (const d of [join(tmp, 'a'), join(tmp, 'a', 'b'), dataDir]) assert.equal(mode(d).toString(8), '700', d);
  } finally { await h.close(); }
});

test('[mode] 明示 dbPath でも DB ファイルは 0600', async () => {
  const s = await startServer();
  try {
    await postEvent(s.port, fixture('SessionStart'));
    assert.equal(mode(s.dbPath).toString(8), '600');
    for (const f of readdirSync(s.dir)) assert.equal(mode(join(s.dir, f)) & 0o077, 0, f);
  } finally { await s.close(); }
});
