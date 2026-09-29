# monitor-emit 送信ペイロード スキーマ（Issue #17 確定 / Issue #2・#3 契約）

`.claude/hooks/monitor-emit.sh`（Issue #2）が `POST /api/events`（Issue #3）へ送る JSON の唯一の仕様。
実測結果（`hook-events.md`）に基づく。**ここに無いキーは送らない。ここに無いキーを受信サーバは拒否する（fail closed）。**

## 設計方針（何を送り、何を送らないか）

- **送るのは allowlist のみ**。`tool_input` / `tool_response` / `prompt` の中身、`cwd` / `transcript_path` / `agent_transcript_path` はどのイベントでも送らない
  - 理由: これらは絶対パス（ホームディレクトリ・ユーザー名を含みうる）か、任意長の自由テキスト（ファイル内容・プロンプト全文・コマンド全文）そのもの。監視の目的（誰が・どのメイドが・何のツールを・いつ・どれだけ）を満たすのに内容までは要らない
- **`session_id` は送る**。理由: セッション一覧・エージェント木を組み立てる一意キーが無いと Issue #3 の中核機能が成立しない。ランダムな UUID であり、ファイルパスや個人情報を含まない
- **`tool_use_id` は送る**。理由: Issue #3 の「実行中ツール」判定（PreToolUse はあるが対応する PostToolUse が無い）は `tool_use_id` の突合せでしか実現できない
- **`agent_id` / `agent_type` は送る**（存在する場合のみ）。理由: エージェント木の構築そのものに必須。実測でメインスレッドには存在しないことを確認済みなので、無い場合はキーごと省略する（`null` を送らない）
- **`prompt_id` / `permission_mode` は送らない**。理由: セッション一覧・エージェント木・ループ状態・トークン集計のいずれの表示要件にも使わない。値を増やすほど allowlist 側の検査漏れリスクが増える（lessons #11: 行き先を絞る）
- **`prompt`（ユーザー入力全文）は絶対に送らない**。UserPromptSubmit はイベント発生の記録（`event`・`session_id`・`ts` 相当）のみを送る
- **Bash コマンドは先頭トークンのベース名のみ**（マスター決定事項）。`export API_KEY=xxx` の先頭トークンは `export` であり、値は一切現れない
- **`file_path` はベース名のみ**。ディレクトリ構造・ホームディレクトリを含めない
- **トークン集計（Issue #7）は数値のみ**。`message.usage` の実測キーから、意味のある数値4種 + thinking の内訳だけを予約する。モデル ID は `[A-Za-z0-9._-]` のみ許可の文字列として送る（transcript 本文は送らない）
- **サーバへは HTTP 経由でのみ届く**ため、`schema_version` を先頭に持たせ、将来の非互換変更を機械的に検出できるようにする

## 型・制約の共通ルール

- 文字列は全て C0 制御文字・DEL（0x7F）・C1 制御文字・双方向制御文字（U+202A-U+202E, U+2066-U+2069 等）を除去してから最大バイト長で切り詰める（`loop-journal.sh` の `safe_display` と同方針）
- 列挙値は `case` 相当の完全一致でのみ許可する。未知の値は既定へ倒す（`event` は例外的に拒否＝該当イベントごと送らない。他は「unknown」等の安全値に丸める）
- 真偽値は JSON の `true`/`false` のみ
- 数値は非負整数のみ。上限を超える値は送らない（フィールドごと省略）

## フィールド定義

| フィールド | 型 | 対象イベント | 必須/任意 | 最大バイト長・制約 |
| --- | --- | --- | --- | --- |
| `schema_version` | integer | 全イベント | 必須 | 固定値 `1` |
| `event` | string（enum） | 全イベント | 必須 | `SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse` `PostToolUse` `SubagentStart` `SubagentStop` `Stop` `Notification` `PreCompact` のいずれか。最大32バイト |
| `session_id` | string | 全イベント | 必須 | 最大64バイト。`[A-Za-z0-9-]` のみ |
| `agent_id` | string | Pre/PostToolUse・SubagentStart・SubagentStop（サブエージェント内部のみ） | 任意 | 最大64バイト。`[A-Za-z0-9]` のみ。無ければキー自体を省略 |
| `agent_type` | string | 同上 | 任意 | 最大64バイト。`[A-Za-z0-9_-]` のみ |
| `source` | string（enum） | SessionStart | 任意 | `startup` `resume` `clear` `compact` `fork` のいずれか。他は省略 |
| `reason` | string（enum） | SessionEnd | 任意 | 実測で確認できた値は `other` のみ。未知の値は `unknown` に丸めて送る。最大32バイト |
| `trigger` | string（enum） | PreCompact | 任意 | `manual` `auto` のいずれか |
| `tool_name` | string | Pre/PostToolUse | 必須（該当イベントで） | 最大64バイト。`[A-Za-z0-9_-]` のみ（例: `Bash` `Read` `Write` `Edit` `Glob` `Grep` `Agent`） |
| `tool_use_id` | string | Pre/PostToolUse | 必須（該当イベントで） | 最大64バイト。`[A-Za-z0-9_]` のみ |
| `subagent_type` | string | PreToolUse（`tool_name` が `Agent` の時のみ。`tool_input.subagent_type` 由来） | 任意 | 最大64バイト。`[A-Za-z0-9_-]` のみ |
| `bash_command` | string | Pre/PostToolUse（`tool_name` が `Bash` の時のみ） | 任意 | **先頭トークンのベース名のみ。`[A-Za-z0-9._-]` 以外を含めば `?` に置換。最大32バイト**（マスター決定） |
| `file_path` | string | Pre/PostToolUse（`tool_input.file_path` を持つツールの時のみ） | 任意 | **ベース名のみ**（ディレクトリ部分を除去）。制御文字除去後、最大128バイトで切り詰め |
| `duration_ms` | integer | PostToolUse | 任意 | 非負整数。上限 3,600,000（1時間）。超過時は省略 |
| `stop_hook_active` | boolean | Stop・SubagentStop | 任意 | — |
| `model` | string | Stop・SubagentStop（トークン集計と同時のみ） | 任意 | 最大64バイト。`[A-Za-z0-9._-]` のみ。不明な値は `unknown` |
| `usage` | object | Stop・SubagentStop | 任意 | 下記「usage オブジェクト」参照。transcript 本文は送らず、集計済みの数値のみ |

### `usage` オブジェクト（Issue #7 予約。実測した `message.usage` のキーに基づく）

| フィールド | 型 | 必須/任意 | 制約 |
| --- | --- | --- | --- |
| `input_tokens` | integer | 任意 | 非負整数。上限 10,000,000 |
| `output_tokens` | integer | 任意 | 同上 |
| `cache_creation_input_tokens` | integer | 任意 | 同上 |
| `cache_read_input_tokens` | integer | 任意 | 同上 |
| `thinking_tokens` | integer | 任意 | 同上（`output_tokens_details.thinking_tokens` 由来） |

`message.id` 単位で重複排除した後の合計値のみを送る（実測で同一 `message.id` の行が
content block 数だけ複製され、複製のたびに同一の `message.usage` を持つことを確認済み。
重複排除せずに全行を合計すると水増しになる。詳細は `hook-events.md`）。

## イベント別の必須キー早見表

| イベント | 必須キー | 任意キー |
| --- | --- | --- |
| SessionStart | `schema_version` `event` `session_id` | `source` |
| SessionEnd | `schema_version` `event` `session_id` | `reason` |
| UserPromptSubmit | `schema_version` `event` `session_id` | — |
| PreToolUse | `schema_version` `event` `session_id` `tool_name` `tool_use_id` | `agent_id` `agent_type` `subagent_type` `bash_command` `file_path` |
| PostToolUse | `schema_version` `event` `session_id` `tool_name` `tool_use_id` | `agent_id` `agent_type` `bash_command` `file_path` `duration_ms` |
| SubagentStart | `schema_version` `event` `session_id` `agent_id` `agent_type` | — |
| SubagentStop | `schema_version` `event` `session_id` `agent_id` `agent_type` | `stop_hook_active` `model` `usage` |
| Stop | `schema_version` `event` `session_id` | `stop_hook_active` `model` `usage` |
| Notification | `schema_version` `event` `session_id` | — |
| PreCompact | `schema_version` `event` `session_id` | `trigger` |

## 送らないと決めたフィールド（捨てた選択肢）

| フィールド | 送らない理由 |
| --- | --- |
| `cwd` / `transcript_path` / `agent_transcript_path` | 絶対パス。ホームディレクトリ・ユーザー名を含みうる。表示要件に不要 |
| `tool_input`（丸ごと） | ファイル内容・プロンプト・コマンド全文を含みうる。allowlist 抽出済みの `bash_command`/`file_path`/`subagent_type` だけで足りる |
| `tool_response`（丸ごと） | ツール出力の内容そのもの。`duration_ms` だけで「実行中/完了」の判定は足りる |
| `prompt`（UserPromptSubmit本文） | ユーザー入力そのもの。監視の目的に不要 |
| `prompt_id` | どの表示要件にも使わない。値を増やすほど検査対象が増える |
| `permission_mode` | 同上 |
| `last_assistant_message` | モデルの応答全文。内容を外に出す必要が無い |
| `background_tasks` / `session_crons` | 実測時は常に空配列で意味のある値を確認できていない。将来必要になれば再検討 |

## 変更履歴

- `schema_version: 1`（Issue #17 で確定。以降のイベント種別・フィールド追加は `schema_version` を上げてから行う）

<!-- SCHEMA:KEYS -->
- `schema_version`
- `event`
- `session_id`
- `agent_id`
- `agent_type`
- `source`
- `reason`
- `trigger`
- `tool_name`
- `tool_use_id`
- `subagent_type`
- `bash_command`
- `file_path`
- `duration_ms`
- `stop_hook_active`
- `model`
- `usage`
<!-- /SCHEMA:KEYS -->
