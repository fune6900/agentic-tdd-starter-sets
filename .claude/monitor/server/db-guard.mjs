// DB の置き場の検査と作成。順序は「検査 → 作成」（lessons #10: 作成系の判定は作成より前、ダングリングを「無い」と見なさない）。
// 行き先は DB 本体・-wal・-shm・-journal・ディレクトリの全部（lessons #11）。リンクは追わず、見つけたら拒否する（fail closed）。
// 拒否の文言にパスを載せない。
//
// 止まらない範囲（TOCTOU）: 検査と mkdir / open の間に、同じ権限を持つ別プロセスがリンクへ差し替えれば辿る。
// 狭める手段は2つだけ: DB の新規作成は O_EXCL（'wx'）で行い、既存リンクの上には作らない / ディレクトリは作成直後に chmod で確定する。
// 同一ユーザーのプロセスが競合して書き換える攻撃は止めない（監視はセキュリティ境界ではない）。

import { chmodSync, existsSync, lstatSync, mkdirSync, realpathSync, writeFileSync } from 'node:fs';
import { basename, dirname, join } from 'node:path';

const DIR_MODE = 0o700;
const FILE_MODE = 0o600;
const SIDECAR_SUFFIXES = ['', '-wal', '-shm', '-journal'];

export class DbPathRejectedError extends Error {
  constructor() {
    super('monitor storage path rejected');
    this.name = 'DbPathRejectedError';
  }
}

const reject = () => { throw new DbPathRejectedError(); };

/** chmod。失敗は生の EPERM/EACCES（メッセージにパスを含む）を出さず、固定文言の拒否に倒す */
function chmodOrReject(path, mode) {
  try {
    chmodSync(path, mode);
  } catch {
    reject();
  }
}

/** lstat。無ければ null（ENOENT 以外は拒否側に倒す） */
function lstatOrNull(path) {
  try {
    return lstatSync(path);
  } catch (err) {
    if (err?.code === 'ENOENT') return null;
    return reject();
  }
}

/** 存在するならリンクでなく、実体のパスが「親の実体 + 名前」と一致すること */
function assertPlainDir(path) {
  const stat = lstatOrNull(path);
  if (stat === null) return;
  if (stat.isSymbolicLink()) reject();
  try {
    if (realpathSync(path) !== join(realpathSync(dirname(path)), basename(path))) reject();
  } catch (err) {
    if (err instanceof DbPathRejectedError) throw err;
    reject();
  }
}

/** まだ無いディレクトリを、深い方から存在する最も近い祖先の手前まで返す */
function missingDirs(dir) {
  const missing = [];
  for (let cur = dir; lstatOrNull(cur) === null; cur = dirname(cur)) {
    if (dirname(cur) === cur) break;
    missing.push(cur);
  }
  return missing;
}

/**
 * 検査してから作成する。通ったら DB の絶対パスを返す
 * @param {string} dbPath
 * @returns {string}
 */
export function prepareDbPath(dbPath) {
  const dir = dirname(dbPath);
  const missing = missingDirs(dir);

  // 1. 検査（何も作らない）
  for (const suffix of SIDECAR_SUFFIXES) {
    const stat = lstatOrNull(`${dbPath}${suffix}`);
    if (stat?.isSymbolicLink()) reject();
  }
  assertPlainDir(dir);
  assertPlainDir(dirname(dir));
  // 親も無い（再帰作成する）場合は、作成の起点になる最も近い既存の祖先を見る
  const anchor = missing.length > 0 ? dirname(missing.at(-1)) : dir;
  assertPlainDir(anchor);

  // 2. 作成。mkdir の mode は umask に削られるので chmod で確定する（作成した分だけ）
  if (missing.length > 0) {
    mkdirSync(dir, { recursive: true, mode: DIR_MODE });
    for (const created of missing) chmodOrReject(created, DIR_MODE);
  }
  if (!existsSync(dbPath)) {
    try {
      // 検査後に別プロセスが先に作った（EEXIST）場合も含め、作成失敗は全て fail closed（TOCTOU の限界は security.md 参照）
      writeFileSync(dbPath, '', { flag: 'wx', mode: FILE_MODE }); // 空ファイルは有効な SQLite DB。O_EXCL でリンクの上に作らない
    } catch {
      reject();
    }
  }
  chmodOrReject(dbPath, FILE_MODE);
  return dbPath;
}
