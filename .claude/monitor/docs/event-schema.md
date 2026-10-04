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

- 文字列の扱いは**フィールドの種別で3通り**に分かれる。「全文字列を切り詰める」ではない
  - **自由テキスト系（`file_path` のみ）**: ベース名化した後、C0 制御文字・DEL（0x7F）・C1 制御文字・双方向制御文字（U+202A-U+202E, U+2066-U+2069 等）を除去し、最大バイト長で切り詰める（`loop-journal.sh` の `safe_display` と同方針。多バイト文字は途中で割らない）。除去・切り詰めの結果が空ならキーを省略
  - **識別子系（`session_id` `agent_id` `agent_type` `tool_name` `tool_use_id` `subagent_type`）**: 制御文字の除去も切り詰めもしない。許可文字の完全一致（文字列全体。複数行の値は不可）かつ最大バイト長以内の場合のみ採用し、**1つでも外れたら値ごと捨てる**（切り詰めた断片は送らない）。捨てたキーは省略する。ただしイベント別の必須キー（下記早見表）が捨てられた場合は**イベントごと送らない**
  - **`bash_command`**: 切り詰めない。許可文字・長さのどちらかを外れたら固定値 `?` に置き換える（詳細は下記フィールド定義）
- 列挙値は完全一致でのみ許可する。未知の値の扱いはフィールドごとに異なる
  - `event`: 未知なら**イベントごと送らない**
  - `reason`（キーが存在する場合）: `other` 以外は `unknown` に丸めて送る
  - `source` `trigger`: 未知ならキーを**省略**する（`unknown` には丸めない）
- 真偽値は JSON の `true`/`false` のみ
- 数値は非負整数のみ。上限を超える値・整数でない値・数値でない値は送らない（フィールドごと省略。丸めない）

## フィールド定義

| フィールド | 型 | 対象イベント | 必須/任意 | 最大バイト長・制約 |
| --- | --- | --- | --- | --- |
| `schema_version` | integer | 全イベント | 必須 | 固定値 `1` |
| `event` | string（enum） | 全イベント | 必須 | `SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse` `PostToolUse` `SubagentStart` `SubagentStop` `Stop` `Notification` `PreCompact` のいずれか。最大32バイト |
| `session_id` | string | 全イベント | 必須 | 最大64バイト。`[A-Za-z0-9-]` のみ |
| `agent_id` | string | Pre/PostToolUse・SubagentStart・SubagentStop（サブエージェント内部のみ） | 任意 | 最大64バイト。`[A-Za-z0-9]` のみ。無ければキー自体を省略 |
| `agent_type` | string | 同上 | 任意 | 最大64バイト。`[A-Za-z0-9_-]` のみ |
| `source` | string（enum） | SessionStart | 任意 | `startup` `resume` `clear` `compact` `fork` のいずれか。他は省略（`unknown` に丸めない） |
| `reason` | string（enum） | SessionEnd | 任意 | 実測で確認できた値は `other` のみ。それ以外の値（文字列以外を含む）は `unknown` に丸めて送る。キーが無ければ省略。送る値は `other` か `unknown` の2種のみ |
| `trigger` | string（enum） | PreCompact | 任意 | `manual` `auto` のいずれか。他は省略（`unknown` に丸めない） |
| `tool_name` | string | Pre/PostToolUse | 必須（該当イベントで） | 最大64バイト。`[A-Za-z0-9_-]` のみ（例: `Bash` `Read` `Write` `Edit` `Glob` `Grep` `Agent`） |
| `tool_use_id` | string | Pre/PostToolUse | 必須（該当イベントで） | 最大64バイト。`[A-Za-z0-9_]` のみ |
| `subagent_type` | string | PreToolUse（`tool_name` が `Agent` の時のみ。`tool_input.subagent_type` 由来） | 任意 | 最大64バイト。`[A-Za-z0-9_-]` のみ |
| `bash_command` | string | Pre/PostToolUse（`tool_name` が `Bash` の時のみ） | 任意 | **先頭トークンのベース名のみ。切り詰めない**（2026-09-30 マスター決定（#18 G5））。判定順序は下記「`bash_command` の判定順序」。結果は `[A-Za-z0-9._-]{1,32}` または `?` のいずれか |
| `file_path` | string | Pre/PostToolUse（`tool_input.file_path` を持つツールの時のみ） | 任意 | **ベース名のみ**（ディレクトリ部分を除去）。制御文字除去後、最大128バイトで切り詰め。受信側が拒否する文字集合は下記「`file_path` の受信側検証」 |
| `duration_ms` | integer | PostToolUse | 任意 | 非負整数（小数不可）。0 以上 3,600,000（1時間）以下。範囲外・非整数・非数値は省略（丸めも切り詰めもしない）。受信側は**値が整数か**で判定するため、JSON の `1.0` や `1e3` は整数として受理する（表記は見ない） |
| `stop_hook_active` | boolean | Stop・SubagentStop | 任意 | — |
| `model` | string | Stop・SubagentStop（トークン集計と同時のみ） | 任意 | 最大64バイト。`[A-Za-z0-9._-]` のみ。不明な値は `unknown`。**`monitor-emit.sh`（#18）は未実装で送らない**（Issue #7 で追加。受信側は任意キーとして受理してよい） |
| `usage` | object | Stop・SubagentStop | 任意 | 下記「usage オブジェクト」参照。transcript 本文は送らず、集計済みの数値のみ。**`monitor-emit.sh`（#18）は未実装で送らない**（Issue #7 で追加） |

### `bash_command` の判定順序（`monitor-emit.sh` の jq `bashcmd` 定義の事実）

入力は `tool_input.command`（`tool_name` が `Bash` の時のみ）。上から順に評価し、最初に該当した時点で確定する。

1. 文字列でなければキーを省略
2. 先頭 4096 文字だけを見て、空白（スペース・タブ・CR・LF）区切りの**先頭トークン**を取る。空白のみ・空文字ならキーを省略
3. **許可文字検証**: 先頭トークン全体（パス区切り `/` を含む）が `[A-Za-z0-9._/-]` のみで構成されていなければ `?`。パス部分に許可外の文字（`~` `$` `"` `=` 非 ASCII 等）が1文字でもあれば、ベース名が無害でも `?`（`FOO=bar cmd` の先頭トークン `FOO=bar` も `?`。値は現れない）
4. **ベース名化**: `/` で分割した最後の要素を取る。空（トークンが `/` で終わる場合など）なら `?`
5. **長さ判定**: ベース名化後のバイト長が 32 を**超えたら切り詰めずに `?`**（切り詰めた断片は送らない）。32 バイトちょうどはそのまま送る

サーバ側検証（#19）はこの結果に対して `?` または `[A-Za-z0-9._-]{1,32}` の完全一致で判定する。`/` は出力に現れない。

### `file_path` の受信側検証（`server/schema.mjs` の事実）

送信側で除去済みのはずの文字が1文字でも残っていれば受信側は拒否する（値を直さない）。パターンは Unicode モード（`u`）で、次の文字を含まない文字列のみ受理する。空文字も不可。最大128バイト（UTF-8 のバイト長）。

- C0 制御文字: U+0000-U+001F
- DEL と C1 制御文字: U+007F-U+009F
- 双方向制御文字: U+200E, U+200F, U+202A-U+202E, U+2066-U+2069
- パス区切り: `/`

### `usage` オブジェクト（Issue #7 予約。実測した `message.usage` のキーに基づく）

| フィールド | 型 | 必須/任意 | 制約 |
| --- | --- | --- | --- |
| `input_tokens` | integer | 任意 | 非負整数。上限 10,000,000 |
| `output_tokens` | integer | 任意 | 同上 |
| `cache_creation_input_tokens` | integer | 任意 | 同上 |
| `cache_read_input_tokens` | integer | 任意 | 同上 |
| `thinking_tokens` | integer | 任意 | 同上（`output_tokens_details.thinking_tokens` 由来） |

受信側は `usage: {}`（キーが1つも無い空オブジェクト）を**受理する**（`allowEmpty`）。集計対象が無い場合の送信を許すため。上記5キー以外のキー・整数でない値・範囲外の値は拒否する。

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

## 受信側の扱い（Issue #19・導出規則の補足）

受信側（`server/derive.mjs`）が保存済みイベントから状態を導出する際の規則のうち、送信側が知っておくべきもの。キー・型の仕様ではない。順序は受信側が付与する `seq` の昇順のみで決まる。

- メインスレッド（`agent_id` 無し）の状態: `SessionStart` は `waiting`、`UserPromptSubmit` は `running`、`Stop` と `Notification` は `waiting`、`SessionEnd` は `ended`。`SessionStart` だけを受けたセッションは `waiting`
- `Notification` は #18 の `monitor-emit.sh` からは送られないため、実運用で `waiting` へ遷移するのは `Stop` 由来
- サブエージェント: `agent_id` を持つイベントで初出のノードは `running` として作る。`SubagentStart` で `running`、`SubagentStop` で `done`
- 実行中ツールは `PreToolUse` の `tool_use_id` を登録し、同じ `tool_use_id` の `PostToolUse` で消す

## 変更履歴

- `schema_version: 1`（Issue #17 で確定。以降のイベント種別・フィールド追加は `schema_version` を上げてから行う）
- 2026-09-30 マスター決定（#18 G5）: `bash_command` は切り詰めず、許可文字外・ベース名化後 32 バイト超過は `?` とする。あわせて共通ルールを実装（`monitor-emit.sh` の jq）に合わせて書き直した（識別子系は検証落ちで値ごと省略・必須キー落ちはイベントごと不送信、`source` `trigger` は未知なら省略、`model` / `usage` は #18 では未送信）。`schema_version` は **1 のまま**: キー集合・型は不変で、新しい記述で許される値の集合は旧記述の部分集合（切り詰めた断片は実装が一度も送っていない）。旧記述で作った検証も、実装が出す全ペイロードを受理できる
- 2026-10-04 #19 受信側の実装（`server/schema.mjs` / `validate.mjs` / `derive.mjs`）に合わせて追記: `usage: {}` の受理、`file_path` の拒否文字集合の列挙、`duration_ms` の整数判定（`1.0` 受理）、「受信側の扱い」節。挙動変更なし。`schema_version` は **1 のまま**（キー・型・許可値の変更なし）

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
