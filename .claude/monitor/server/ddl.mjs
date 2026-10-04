// SQLite の DDL（Issue #19）。値は一切埋め込まない。挿入・検索は呼び出し側がプレースホルダで行う。
//
// 保存形式: 検索・順序に使う3値だけを列にし、イベント本体は JSON 1列（payload）に原文で持つ。
//   - 全キー列展開にしない理由: キーはイベントごとに有無が違い（任意キー多数）、usage は入れ子。
//     スキーマ追加（schema_version 上げ）のたびに ALTER が要る。list() は「ペイロード原文 + seq + received_at」を
//     返す契約なので、JSON 原文のほうが往復で欠落・型変換が起きない。
//   - 列にした理由: event / session_id はセッション別の絞り込みと索引に使う。received_at は保持期間削除に使う。
//   - 順序は seq のみで決まる。送信側の値は payload の中にあるだけで、列にも索引にもしない。
// seq は AUTOINCREMENT。sqlite_sequence が最大値を保持するので、全行を削除しても再利用されない。

export const CREATE_EVENTS_TABLE = `CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  received_at INTEGER NOT NULL,
  event TEXT NOT NULL,
  session_id TEXT NOT NULL,
  payload TEXT NOT NULL CHECK (json_valid(payload))
) STRICT`;

// 保持期間削除（received_at < ?）用
export const CREATE_RECEIVED_AT_INDEX = 'CREATE INDEX IF NOT EXISTS idx_events_received_at ON events (received_at)';

// セッション別の取得用
export const CREATE_SESSION_INDEX = 'CREATE INDEX IF NOT EXISTS idx_events_session_seq ON events (session_id, seq)';

/** 起動時に順に exec する。全て冪等。 */
export const DDL_STATEMENTS = Object.freeze([
  CREATE_EVENTS_TABLE,
  CREATE_RECEIVED_AT_INDEX,
  CREATE_SESSION_INDEX,
]);
