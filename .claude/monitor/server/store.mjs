// SQLite 保存層（node:sqlite）。SQL は全てプリペアドステートメント＋プレースホルダ。値を SQL 文字列に埋め込まない。
// 時刻（received_at）と連番（seq）は受信側が付ける。順序は seq のみ。

import { DatabaseSync } from 'node:sqlite';
import { DDL_STATEMENTS } from './ddl.mjs';

export const DEFAULT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const DEFAULT_MAX_ROWS = 100_000;

const NO_LIMIT = -1; // SQLite: 負の LIMIT は無制限

/** @param {{dbPath: string, now?: () => number, retentionMs?: number, maxRows?: number}} opts */
export function openStore({ dbPath, now = Date.now, retentionMs = DEFAULT_RETENTION_MS, maxRows = DEFAULT_MAX_ROWS }) {
  const db = new DatabaseSync(dbPath);
  for (const ddl of DDL_STATEMENTS) db.exec(ddl);

  const insert = db.prepare('INSERT INTO events (received_at, event, session_id, payload) VALUES (?, ?, ?, ?)');
  const select = db.prepare('SELECT seq, received_at, payload FROM events WHERE seq > ? ORDER BY seq ASC LIMIT ?');
  const maxSeq = db.prepare('SELECT COALESCE(MAX(seq), 0) AS n FROM events');
  const countAll = db.prepare('SELECT COUNT(*) AS n FROM events');
  const deleteOld = db.prepare('DELETE FROM events WHERE received_at < ?');
  const deleteOverflow = db.prepare('DELETE FROM events WHERE seq <= (SELECT seq FROM events ORDER BY seq DESC LIMIT 1 OFFSET ?)');

  return {
    append(event) {
      const received_at = now();
      const { lastInsertRowid } = insert.run(received_at, event.event, event.session_id, JSON.stringify(event));
      return { seq: Number(lastInsertRowid), received_at };
    },
    list({ afterSeq = 0, limit = NO_LIMIT } = {}) {
      return select.all(afterSeq, limit).map((row) => ({ seq: row.seq, received_at: row.received_at, ...JSON.parse(row.payload) }));
    },
    count: () => countAll.get().n,
    lastSeq: () => Number(maxSeq.get().n),
    prune() {
      const aged = deleteOld.run(now() - retentionMs).changes;
      const overflow = deleteOverflow.run(maxRows).changes;
      return Number(aged) + Number(overflow);
    },
    close: () => db.close(),
  };
}
