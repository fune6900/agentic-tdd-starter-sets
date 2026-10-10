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
- **トークン集計（Issue #23）は数値・真偽値・モデル ID のみ**。`UsageSnapshot` イベント（下記）で送る。transcript の本文・パス・プロンプト・`message.id` は送らない。モデル ID は `[A-Za-z0-9._-]` のみ許可の文字列として送り、外れたら `unknown` にする
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
  - 例外: `UsageSnapshot` の数値は「省略」ではなく**スナップショットごと `usage_status: "unknown"` にする**（部分合計を送らないため。下記）

## フィールド定義

| フィールド | 型 | 対象イベント | 必須/任意 | 最大バイト長・制約 |
| --- | --- | --- | --- | --- |
| `schema_version` | integer | 全イベント | 必須 | `UsageSnapshot` は `2`、それ以外の10イベントは `1`（イベントごとに固定。下記「`schema_version` のイベント別の値」） |
| `event` | string（enum） | 全イベント | 必須 | `SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse` `PostToolUse` `SubagentStart` `SubagentStop` `Stop` `Notification` `PreCompact` `UsageSnapshot` のいずれか。最大32バイト。`UsageSnapshot` は Claude Code のフックイベントではなく、`monitor-emit.sh` が合成する（`settings.json` の登録は増えない） |
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
| `usage_status` | string（enum） | UsageSnapshot | 必須 | `ok` `unknown` のいずれか |
| `unknown_reason` | string（enum） | UsageSnapshot | `usage_status` が `unknown` の時のみ必須（`ok` では存在不可） | 下記「集計できなかった時」の8種 |
| `models` | array | UsageSnapshot | `usage_status` が `ok` の時のみ必須（`unknown` では存在不可） | 要素はモデル別の合計。0〜8個。下記「`models` の要素」 |

> `model` / `usage` は #17 で Stop / SubagentStop 用に予約していたが、一度も送られていない。#23 で `UsageSnapshot` を採用したため**削除する**（下記「`UsageSnapshot` を新イベントにした理由」）。

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

## `UsageSnapshot`（Issue #23 確定）

Stop / SubagentStop 時に transcript の `message.usage` を集計した**数値だけ**を送る、独立したイベント。
合成イベントであり、Claude Code のフックイベントではない（`settings.json` の登録は増えない。`monitor-emit.sh` が Stop / SubagentStop を受けた時に、元のイベントとは別に1通足す）。

### `UsageSnapshot` を新イベントにした理由（Stop / SubagentStop の任意キーにしなかった理由）

| 観点 | 新イベント（採用） | Stop / SubagentStop に任意キー（不採用） |
| --- | --- | --- |
| 状態遷移への影響 | Stop（`waiting`）・SubagentStop（`done`）は transcript に関係なく即座に届く。集計が遅れても失敗しても状態は壊れない | 集計を待つか、集計失敗時に状態遷移ごと遅れる。ファイル読み取りの失敗が「完了が見えない」に直結する |
| 1 秒予算 | 集計・送信を丸ごと背景化できる。フック本体は今と同じ | Stop 自体の本文に載せるには集計を同期で終えるか、背景化して Stop の送信も遅らせる必要がある |
| 置き換え | 「最新の UsageSnapshot が勝つ」と1種類のイベントで言える | Stop は毎ターン来るため、Stop 全体を「置き換え」対象にはできず、キー単位の特例が要る |
| 受信側の検証 | イベント別の許可キー表（`EVENTS`）に1行足すだけ。既存10イベントの許可集合は変わらない | 既存イベントの許可集合が広がり、`usage` の入れ子を持つ Stop / SubagentStop の検証が複雑になる |
| 欠点 | イベントが11種になる。`derive` が状態遷移に使わないことを明記する必要がある | — |

### `schema_version` のイベント別の値

- `UsageSnapshot` は `schema_version: 2`、既存の10イベントは `1` のまま。**送信側はイベントごとにこの値を送り、受信側はイベントごとに一致する値だけを受理する**（`UsageSnapshot` に `1`、他のイベントに `2` は拒否）
- 全イベントを一斉に `2` にしない理由: 古いサーバ（`1` のみ受理・fail closed）に新しいフックが送っても、落ちるのは `UsageSnapshot` だけで、状態遷移・ツール表示は動き続ける。コンテナイメージはフックより更新が遅れうる
- 先頭の「型・制約の共通ルール」にある「イベント種別追加は `schema_version` を上げてから」を満たすのは、`UsageSnapshot` に固有の `2` による

### キー

| キー | 必須/任意 | 規則 |
| --- | --- | --- |
| `schema_version` | 必須 | `2` |
| `event` | 必須 | `UsageSnapshot` |
| `session_id` | 必須 | 既存の規則（`[A-Za-z0-9-]` 最大64バイト）。落ちたら**イベントごと送らない** |
| `agent_id` | 任意 | SubagentStop 由来の時だけ付く。メイン（Stop 由来）は**キーを持たない**。既存の規則（`[A-Za-z0-9]` 最大64バイト） |
| `usage_status` | 必須 | `ok` / `unknown` |
| `unknown_reason` | `unknown` の時のみ必須 | 下記8種 |
| `models` | `ok` の時のみ必須 | 0〜8個の配列（要素は下記）。`ok` で空配列は「assistant の usage 行が1件も無い」を表し、0 トークンが事実 |

以上の他のキーは受信側が拒否する。`agent_type` は載せない（ノードは SubagentStart が作る）。

**属人性の規則**:

- SubagentStop 由来で `agent_id` が検証に落ちたら、`agent_id` を省略して送るのではなく**`UsageSnapshot` ごと送らない**。省略すると、サブエージェントの使用量がメインに付いてしまう
- Stop 由来の `UsageSnapshot` は、stdin に `agent_id` があっても付けない（メインの Stop に `agent_id` は存在しないことを #17 で実測済み。万一あっても使用量の帰属を変えない）
- 読む transcript は Stop が `transcript_path`、SubagentStop が `agent_transcript_path`。もう片方は読まない

```json
{
  "schema_version": 2,
  "event": "UsageSnapshot",
  "session_id": "11111111-1111-4111-8111-111111111111",
  "agent_id": "aaaaaaaaaaaaaaaaa",
  "usage_status": "ok",
  "models": [
    {
      "model": "claude-haiku-4-5-20251001",
      "message_count": 3,
      "input_tokens": 8,
      "output_tokens": 61,
      "cache_creation_5m_input_tokens": 209,
      "cache_creation_1h_input_tokens": 0,
      "cache_read_input_tokens": 14242,
      "fast_mode": false,
      "us_inference": false,
      "variant_unknown": false,
      "cache_split_unknown": false
    }
  ]
}
```

```json
{
  "schema_version": 2,
  "event": "UsageSnapshot",
  "session_id": "11111111-1111-4111-8111-111111111111",
  "usage_status": "unknown",
  "unknown_reason": "too_large"
}
```

### 集計できなかった時（`usage_status: "unknown"`）

**部分合計は送らない。** 1つでも理由に該当したら、`models` を持たない `unknown` を1通だけ送る。

| `unknown_reason` | 条件 |
| --- | --- |
| `no_path` | 読むべきパスのキーが無い・文字列でない・空・絶対パス（先頭 `/`）でない・C0 制御文字 / DEL を含む・4096 バイト超 |
| `symlink` | パスの最終要素がシンボリックリンク（ダングリング含む）。`O_NOFOLLOW` で開くと ELOOP で失敗する |
| `not_regular_file` | 開いた fd 上の `stat` で通常ファイルでない（ディレクトリ・FIFO・ソケット・デバイス）。`O_NONBLOCK` で開くので FIFO でも待たず、1 バイトも読まない |
| `too_large` | サイズ上限（`MAX_TRANSCRIPT_BYTES`）を超える（fd 上の `stat` のサイズ、または上限 + 1 バイトまで読んで超過分が読めた） |
| `read_failed` | 存在しない・権限が無い・読み取り中のエラー・perl / Fcntl が無い（open の失敗のうち ELOOP 以外はすべてこれ） |
| `parse_failed` | 空行以外で、JSON として読めない行がある |
| `invalid_usage` | 集計対象の行の数値が不正（下記）。または usage を持つ行に `message.id` が無い |
| `too_many_models` | 異なるモデル ID（`unknown` を含む）が 8 種を超える |
| `out_of_range` | 合計値がキー別の上限（下記）を超える |

理由は**1つだけ**送る。判定の順序は、まずパス・ファイルの判定を `no_path` → （open 1 回: ELOOP なら `symlink`、他の失敗は `read_failed`）→ （fd 上の判定: `not_regular_file` → `too_large`）→ （読み取り中の失敗は `read_failed`・上限超過は `too_large`）の順に行い、全て通ったら**全行を見終えた後**に `parse_failed` → `invalid_usage` → `too_many_models` → `out_of_range` の優先で決める（同じ入力が常に同じ理由になる）。

`unknown` を受けたサーバは、同じ (session, agent) の直前の `ok` を**置き換える**（古い数値を残さない。残すと「今は不明」が見えなくなる）。次の Stop / SubagentStop で正しい値に戻る。

### `models` の要素

要素のキーは**全て必須**で、これ以外のキーは拒否する。要素間で `model` が重複していたら拒否する（送信側は `model` の昇順（バイト順）で並べる）。

| キー | 型 | 制約 |
| --- | --- | --- |
| `model` | string | 最大64バイト。`[A-Za-z0-9._-]` の全体一致（複数行不可）。**外れる・無い・文字列でない場合は `unknown`**（捨てずに合算する。同じ `unknown` に落ちた複数のモデルは1要素に合算） |
| `message_count` | integer | 重複排除後に数えた assistant メッセージ数。0〜1,000,000 |
| `input_tokens` | integer | 0〜`MAX_USAGE_TOKENS`（10^12） |
| `output_tokens` | integer | 同上（thinking を含む。内訳の `thinking_tokens` は送らない: コスト算出に不要） |
| `cache_creation_5m_input_tokens` | integer | 同上 |
| `cache_creation_1h_input_tokens` | integer | 同上 |
| `cache_read_input_tokens` | integer | 同上 |
| `fast_mode` | boolean | このモデルのメッセージに `usage.speed` が `fast` のものが1件でもあれば `true` |
| `us_inference` | boolean | `usage.inference_geo` が `us` のものが1件でもあれば `true` |
| `variant_unknown` | boolean | `speed` / `inference_geo` が既知の値（下記）以外のものが1件でもあれば `true` |
| `cache_split_unknown` | boolean | キャッシュ書き込みの 5 分 / 1 時間の内訳が欠ける・合計と合わないメッセージが1件でもあれば `true` |

- **上限 10^12 の理由**: 累積値なので長いセッションでは `cache_read_input_tokens` が容易に 10^7 を超える（旧予約の 10,000,000 は低すぎる）。10^12 は 2^53（約 9×10^15）未満なので、jq・JSON・JavaScript の数値で8モデル合算しても厳密に表せる
- `speed` の既知の値: キー無し・`null`・`standard`（実測値）= 通常、`fast` = `fast_mode`、それ以外 = `variant_unknown`
- `inference_geo` の既知の値: キー無し・`null`・`not_available`（実測値）・`global` = 通常、`us` = `us_inference`、それ以外 = `variant_unknown`。`global` も実測値（2026-10-10、実セッションの transcript で `global` と `not_available` の両方を確認。価格ページの「Global routing (the default) uses standard pricing」と一致）
- フラグは「そのモデルの全メッセージの OR」。モデル内のメッセージを分けて数えない（フラグが立てばそのモデルのコストは丸ごと「不明」になる。安全側）

### 集計規則（重複排除・数値の扱い）

入力は transcript の各行（1行1 JSON）。**`type` が文字列 `assistant` の行だけ**を見る（`cost-state` など他の種別は無視）。

1. 空行（空白のみを含む）は読み飛ばす。それ以外で JSON として読めない行が1つでもあれば `parse_failed`
2. 行に `message` オブジェクトと `message.usage` オブジェクトが無ければ、その行は**数えない**（トークン数を持たないので）
3. `message.id` が空でない文字列なら、`message.id` をキーに行を1つに畳む。**同じ id が複数あれば最後の行を採用**する（実測では同一 id の行は同一の `message.usage` を持つ。差がある場合は最後が最も完全。複数ブロックの水増しを防ぐのが目的で、同一なら first/last の差は出ない）
4. `usage` を持つが `message.id` が無い・文字列でない行: `input_tokens` / `output_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` の全てが 0 または無いなら数えず無視。1つでも 0 より大きければ `invalid_usage`（数え方が決められない行を黙って落とさない）
5. 数値4種（上記）と `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`: **キーが無い = 0**。キーがあって非負整数でない（`null`・文字列・負数・小数・真偽値・配列・オブジェクト）なら `invalid_usage`。`1.0` は整数として受理する（`duration_ms` と同じ判定）
6. キャッシュ書き込みの内訳: `cache_creation` オブジェクトに 5 分・1 時間の両方があり、合計が `cache_creation_input_tokens` と一致する時だけ内訳を使う。それ以外（オブジェクトが無い・片方欠ける・不一致）は `cache_creation_input_tokens` の全量を **5 分側に入れ**、`cache_split_unknown` を立てる（単価が違うので、このモデルのコストは「不明」になる）
7. 畳んだ後、トークン数4種（`input_tokens` / `output_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens`）が**全て 0 の行は数えない**（モデルの一覧にも載せない）。実測で、モデル ID が `<synthetic>` の行は usage が全て 0 で、`speed` / `inference_geo` も `null` だった（API を呼ばないローカル生成の行。数えるとモデル `unknown` が混ざり、コストが常に「不明を含む」になる）
8. モデル別に合算し、`message_count` は畳んだ後の件数。`thinking_tokens`・`server_tool_use`・`service_tier`・`iterations` は読まない（送らない）
9. 合計が上限を超えたら `out_of_range`、モデルが 8 種を超えたら `too_many_models`

### transcript を読む経路（送信側）

- パスは perl の `sysopen`（`O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_NOCTTY`）で**1 回だけ**開き、種別・サイズは開いた fd 上で判定する（名前での再判定・再オープンをしない）。`O_NOFOLLOW` は最終要素のみ（親ディレクトリがリンクでも辿る。OS 標準の `/var` → `/private/var` 等を拒否しないため。限界として `security.md` に書く）
- **読み取りは上限 + 1 バイトで打ち切る**（`sysread`）。確認の後にファイルが伸びても、読む量が上限を超えない。読み取りが途中で失敗したら部分合計は送らず `read_failed`。超過分が1バイトでも読めたら `too_large`
- パスは jq / curl / perl の argv に載せない（環境変数で perl に渡す）。送信ボディには数値・真偽値・列挙値・モデル ID だけが載る。transcript の文字列値が出力に到達するのは、`model` が許可文字の全体一致を通った場合だけ
- 一時ファイルは作らない

### 1 秒予算とサイズ上限

**判定: transcript の読み取り・集計・送信を丸ごと背景化する方針で問題ない。**

- フック本体（前景）がやるのは、既存どおり stdin を allowlist 抽出して元のイベントを背景送信し、`transcript_path` / `agent_transcript_path` を取り出して背景グループへ渡すことだけ。ファイルの判定・読み取り・jq の集計は全て背景グループの中
- `monitor-emit.sh` の既存契約と衝突しない: stdout / stderr 0 バイト・exit 0・`LOOP_MONITOR=0` は変わらない。背景グループは `{ ...; } >/dev/null 2>&1 </dev/null &` の形で fd を切り離す（実測: 切り離さない背景化は5秒待たれる。`hook-events.md`）。元のイベントの送信と `UsageSnapshot` の送信は**別の背景グループ**にする（片方の失敗・遅延が他方に波及しない）
- `security.md`「監視の限界（送信側）」に増えるもの（Coder が追記する）: (a) フックが**ローカルファイルを読む新経路**（`.gitignore` も権限設定も届かない外部由来のパス）。止める: symlink・通常ファイル以外・上限超過。止めない: 親ディレクトリのリンク、親ディレクトリの差し替え（最終要素は fd 方式で止まる。読み取り量の上限は守る）、perl が無い環境（`read_failed`）、同じユーザーが書ける任意の通常ファイルを `transcript_path` に仕込むこと（読まれるが、数値以外は送られない） (b) 背景処理なので、セッション終了間際の集計は黙って捨てられうる（fail open。最後のターンの `UsageSnapshot` が欠け、直前のものが表示される） (c) 同時に完了したサブエージェントの数だけ jq が並走する（上限なし）
- 「送らない項目」に変更なし（`transcript_path` / `agent_transcript_path` は引き続き送らない）

**サイズ上限（`MAX_TRANSCRIPT_BYTES`）は 16 MiB（16777216 バイト）。** 実測で決めた（epics 未確定事項 6。下記「実測結果」）。テストは定数を直書きせず、下記の絞り込み用の環境変数で小さいファイルから検証する。

- `LOOP_MONITOR_MAX_TRANSCRIPT_BYTES`（任意）: 10進の正の整数なら `min(既定値, この値)` を上限にする。**既定値より大きくはできない**（読み取り量を増やす向きには使えない）。不正値（空・符号・先頭ゼロ・数字以外・複数行）は無視して既定値
- Coder の実測条件（結果は Tech Lead 経由でマスターに渡し、値が決まったら本書の `MAX_TRANSCRIPT_BYTES` と `security.md` に書く）:
  1. fixture transcript を 1 / 5 / 10 / 20 / 50 MB で作る（assistant 行は本物と同じキー構成・同一 `message.id` の重複を含む。1 行あたり数 KB）
  2. **前景の所要時間**（フック起動から exit まで）が、上記全てのサイズで 1 秒未満（Issue の条件。10MB 級は必須）。LOOP_MONITOR=0 でない通常経路で、サーバ停止状態・稼働状態の両方で測る
  3. **背景の所要時間**（読み取り + 集計 + 送信）を別に測る。目安は、セッション終了で打ち切られても失う割合が小さい 5 秒以内に収まる最大サイズの約半分を上限にする（余裕を持たせる）
  4. 同時に 10 個の背景グループが走った時のピークメモリと完了時間を測り、実用上の問題が無いことを確認する
  5. 測定環境（OS・CPU・jq のバージョン）と生データを journal に残す
- 実装の順序: 絞り込み用の環境変数と `too_large` の経路を先に作ってテストし、上記の実測で `MAX_TRANSCRIPT_BYTES` の既定値を決めてから入れる。値が入るまで `ok` を送る経路を有効にしない

#### 実測結果（`MAX_TRANSCRIPT_BYTES` の根拠）

- 環境: Apple M3（8 コア）/ macOS 26.5 / bash 3.2.57 / jq 1.8.1。fixture は本物と同じキー構成の assistant 行（同一 `message.id` を 2 行ずつ・本文約 1.6KB・1 行約 1.9KB）に、5 行に 1 行の user 行を混ぜたもの。測定用に既定値を 1 GiB にしたフックのコピーで、実際の HTTP 受信（localhost）まで測った
- 前景 = フック起動から exit まで。背景 = 起動から `UsageSnapshot` の受信まで（読み取り + 集計 + 送信）。ピーク = 実行中の jq / head の RSS 合計の最大値（bash 自身の変数分は含まない）

| サイズ | 前景（単独） | 背景（単独） | 背景（10 本同時） | 前景（10 本同時の最大） | jq ピーク（単独 / 10 本） |
| --- | --- | --- | --- | --- | --- |
| 1MB | 0.08 秒 | 0.29 秒 | 1.57 秒 | 0.41 秒 | 0MB / 22MB |
| 5MB | 0.05 秒 | 0.47 秒 | 1.98 秒 | 0.38 秒 | 6MB / 60MB |
| 10MB | 0.05 秒 | 0.81 秒 | 2.94 秒 | 0.38 秒 | 10MB / 96MB |
| 16MB（15.99 MiB） | 0.07 秒 | 1.38 秒 | 4.21 秒 | 0.39 秒 | 14MB / 122MB |
| 20MB | 0.05 秒 | 1.63 秒 | 5.20 秒 | 0.38 秒 | 17MB / 145MB |
| 50MB | 0.05 秒 | 5.21 秒 | 21.32 秒 | 0.46 秒 | 40MB / 297MB |

- 前景は全サイズで 0.1 秒以下（10 本同時でも 0.5 秒未満）で、1 秒の予算に収まる（transcript に触れないため、サイズに依存しない）
- 単独で背景が 5 秒に収まる最大は約 48MB（50MB で 5.21 秒）。基準の「その約半分」は約 24MB だが、10 本同時の完了時間が 5 秒を超え始める（20MB で 5.20 秒）ことを見込み、さらに余裕を取って **16 MiB（10 本同時で 4.2 秒）** にした。実セッションのメイン transcript は約 6MB（Tech Lead の実測）で、約 2.7 倍の余裕がある
- 16 MiB を超えるセッションは `too_large`（使用量不明）になる。上限を上げるなら再測定の上で `monitor-emit.sh` の `MAX_TRANSCRIPT_BYTES` を書き換える（環境変数では上げられない）

## イベント別の必須キー早見表

| イベント | 必須キー | 任意キー |
| --- | --- | --- |
| SessionStart | `schema_version` `event` `session_id` | `source` |
| SessionEnd | `schema_version` `event` `session_id` | `reason` |
| UserPromptSubmit | `schema_version` `event` `session_id` | — |
| PreToolUse | `schema_version` `event` `session_id` `tool_name` `tool_use_id` | `agent_id` `agent_type` `subagent_type` `bash_command` `file_path` |
| PostToolUse | `schema_version` `event` `session_id` `tool_name` `tool_use_id` | `agent_id` `agent_type` `bash_command` `file_path` `duration_ms` |
| SubagentStart | `schema_version` `event` `session_id` `agent_id` `agent_type` | — |
| SubagentStop | `schema_version` `event` `session_id` `agent_id` `agent_type` | `stop_hook_active` |
| Stop | `schema_version` `event` `session_id` | `stop_hook_active` |
| Notification | `schema_version` `event` `session_id` | — |
| PreCompact | `schema_version` `event` `session_id` | `trigger` |
| UsageSnapshot | `schema_version`（`2`） `event` `session_id` `usage_status` | `agent_id` `unknown_reason`（`unknown` の時は必須） `models`（`ok` の時は必須） |

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
| transcript の本文・`message.id`・`message.content`・`thinking_tokens`・`server_tool_use`・`service_tier`・`iterations` | `UsageSnapshot` は数値・真偽値・モデル ID だけ。内容は一切送らない。`thinking_tokens` は `output_tokens` の内訳でコスト算出に不要 |
| `background_tasks` / `session_crons` | 実測時は常に空配列で意味のある値を確認できていない。将来必要になれば再検討 |

## 受信側の扱い（Issue #19・導出規則の補足）

受信側（`server/derive.mjs`）が保存済みイベントから状態を導出する際の規則のうち、送信側が知っておくべきもの。キー・型の仕様ではない。順序は受信側が付与する `seq` の昇順のみで決まる。

- メインスレッド（`agent_id` 無し）の状態: `SessionStart` は `waiting`、`UserPromptSubmit` は `running`、`Stop` と `Notification` は `waiting`、`SessionEnd` は `ended`。`SessionStart` だけを受けたセッションは `waiting`
- `Notification` は #18 の `monitor-emit.sh` からは送られないため、実運用で `waiting` へ遷移するのは `Stop` 由来
- サブエージェント: `agent_id` を持つイベントで初出のノードは `running` として作る。`SubagentStart` で `running`、`SubagentStop` で `done`
- 実行中ツールは `PreToolUse` の `tool_use_id` を登録し、同じ `tool_use_id` の `PostToolUse` で消す

### `UsageSnapshot` の受信・保存・導出（Issue #23）

- **検証（`schema.mjs` / `validate.mjs`）**: `EVENTS` に `UsageSnapshot: { required: ['usage_status'], optional: ['agent_id', 'unknown_reason', 'models'] }` を足す。`schema_version` は `SCHEMA_VERSION` の単一値から**イベント別の表**（`UsageSnapshot` → 2、他 → 1）にする。`models` のために配列の種別（`kind: 'array'`: `maxItems` 8・要素は全キー必須のオブジェクト・`model` の重複を拒否）を足す。排他条件を `CONDITIONS` の拡張で表す: `usage_status` が `ok` なら `models` 必須かつ `unknown_reason` 不可、`unknown` なら `unknown_reason` 必須かつ `models` 不可。`model` / `usage`（旧予約）は `FIELDS` と `Stop` / `SubagentStop` の `optional` から削除し、`MAX_USAGE_TOKENS` は 10^12 にする。拒否は従来どおり固定文言・fail closed（切り詰めも補正もしない）
- **保存（置き換え）**: `UsageSnapshot` も他のイベントと同じく `events` に追記する（DDL・保持期間の変更なし）。「置き換え」は**導出で最新だけを使う**ことで実現する。同じ (session, agent)（メインは `agent_id` 無しのキー）の `UsageSnapshot` は **`seq` が最大のもの1つだけ**が有効で、それ以前は無視する。同じスナップショットを2回送っても合計は倍にならない（合算せず、選ぶだけ）。`ok` の後に `unknown` が来たら `unknown` が有効
  - 順序は `seq`（受信順）だけで決まる。背景送信は到着順が前後しうるので、古いスナップショットが後から着けば古い方が勝つ。次の Stop / SubagentStop で直る。トークン数の大小で順序を補正しない（`unknown` を挟むと比べられない）
  - 理由: 専用テーブルを足すと DDL・保持期間・容量上限の規則が別に要る。events に載せれば保持（7 日 / 10 万行）と `seq` 順がそのまま使える
- **導出（`derive.mjs`）**: `UsageSnapshot` は**ツリーの状態・`running_tools`・セッションの `last_seq` / `last_received_at` を変えない**。ノードも作らない（`subNode` を通さない）。該当するセッション・ノードが無ければ、そのスナップショットは表示に出ない（後からノードが現れれば、再導出で出る）。各ノード（メイン・サブ）に `usage` を足す

```
usage: null                                  // 有効なスナップショット無し
     | { status: "unknown", reason: <unknown_reason> }
     | { status: "ok", models: [ { model, message_count, input_tokens, output_tokens,
                                   cache_creation_5m_input_tokens, cache_creation_1h_input_tokens,
                                   cache_read_input_tokens,
                                   cost: { status: "known", micro_usd: <整数> }
                                       | { status: "unknown", reason: <下記の理由> } } ] }
```

セッションには `usage_total` を足す（メイン + 全サブエージェントの有効なスナップショットの合算。`estimate: true` は常に付ける）:

```
usage_total: {
  estimate: true,
  tokens: { input, output, cache_creation, cache_read },   // status ok のスナップショットだけの合計。cache_creation は 5m + 1h
  unknown_snapshots: <number>,                              // status unknown のノード数（トークン数が合計に入っていない）
  cost: { known_micro_usd: <整数>, known_count: <number>, unknown_count: <number> }
}
```

- サブエージェントの transcript はメインとは別ファイルで、サブエージェントの使用量はメインの transcript の `message.usage` に含まれない、という前提で単純合算する。**この前提は #17 では実測していない**。G2 の実セッションで、メインとサブの両方が出て合計がメイン単独より増えることを確認し、二重計上が見つかれば本書を直す

### 推定コストの算出規則

- 単価表は `.claude/monitor/server/pricing.mjs`（純粋なデータ。検証・計算は `cost.mjs` に分け、`derive.mjs` が呼ぶ）。価格を **ハードコードで散らさない**。出典 URL と取得日を持つ。数値はマスターの決定（`.claude/memory/epics/ai-monitor.md`「マスターの決定（2026-10-10・#23 の単価表）」）をそのまま転記する。Coder は値を変えない・足さない（モデルを足す場合もマスターの決定）
- 形（疑似コード。実ファイルは Coder が作る）:

```js
export const PRICING_SOURCE_URL = 'https://platform.claude.com/docs/en/about-claude/pricing';
export const PRICING_FETCHED_AT = '2026-10-10';           // YYYY-MM-DD。単価を更新したら必ず更新する
export const PRICING_UNIT = 'USD per MTok';

// キー = transcript の message.model と完全一致するモデル ID（前方一致・日付の正規化はしない）
export const PRICING = Object.freeze({
  'claude-fable-5-1':          Object.freeze({ input: 10, cache_write_5m: 12.5, cache_write_1h: 20, cache_read: 0.25, output: 50 }),
  'claude-opus-5-5':           Object.freeze({ input: 4,  cache_write_5m: 5,    cache_write_1h: 8,  cache_read: 0.2,  output: 20 }),
  'claude-sonnet-5-5':         Object.freeze({ input: 2,  cache_write_5m: 2.5,  cache_write_1h: 4,  cache_read: 0.1,  output: 10 }),
  'claude-haiku-4-5-20251001': Object.freeze({ input: 1,  cache_write_5m: 1.25, cache_write_1h: 2,  cache_read: 0.1,  output: 5 }),
});

// 表に載せないと決めたモデル（理由を区別して「不明」にする）
export const UNPRICEABLE = Object.freeze({ 'claude-haiku-5-5': 'tiered_pricing' });
```

- モデル別コスト `estimateModelCost(entry)` は、次の**上から順**で最初に該当した理由の `{ status: "unknown", reason }` を返す。どれにも該当しなければ `known`

| 順 | `reason` | 条件 |
| --- | --- | --- |
| 1 | `tiered_pricing` | `UNPRICEABLE` にあるモデル（`claude-haiku-5-5`: プロンプト長で単価が変わり、合計値からは判定できない） |
| 2 | `model_not_in_table` | `PRICING` に無いモデル（`unknown` を含む） |
| 3 | `fast_mode` | `fast_mode` が `true` |
| 4 | `us_inference` | `us_inference` が `true`（1.1 倍になるため） |
| 5 | `variant_unknown` | `variant_unknown` が `true` |
| 6 | `cache_split_unknown` | `cache_split_unknown` が `true` |

- `known` の `micro_usd` = 次の5項の合計。**項ごとに `Math.round`** してから足す（`tokens × 単価（USD/MTok）` はそのままマイクロドル。小数の誤差を各項で整数に確定させる）:
  `input_tokens × input` + `output_tokens × output` + `cache_creation_5m_input_tokens × cache_write_5m` + `cache_creation_1h_input_tokens × cache_write_1h` + `cache_read_input_tokens × cache_read`
- スナップショットが `status: "unknown"` の時、そのノードのコストは `cost.unknown_count` に 1 を足す（理由は `usage.reason` に出ている）
- **「不明」を 0 円として扱わない**: `known_micro_usd` に足さない・0 を入れない・`null` や空で潰さない。`ok` で `models: []`（使用量ゼロが事実）の時だけ、コストは 0 が事実として許される
- **合計に不明が混ざった時**: 「わかる分の合計」と「不明を含む印」の両方を出す。`usage_total.cost` の `known_micro_usd` / `known_count` / `unknown_count` がその情報。ビューの出し分け（Designer / Coder）:
  - `unknown_count == 0` → 「推定 $X」
  - `known_count > 0` かつ `unknown_count > 0` → 「推定 $X 以上（不明を含む）」。**下限であって合計ではない**ことが読み取れる表示にする
  - `known_count == 0` かつ `unknown_count > 0` → 「不明」（`$0` と書かない）
  - `known_count == 0` かつ `unknown_count == 0` → 使用量ゼロ。`$0`
- 推定である理由（ビューの「推定」ラベルの根拠）: トークン課金のみで、ウェブ検索等のツール課金（`server_tool_use`）・割引・為替は含めない。単価は取得日時点

## 変更履歴

- `schema_version: 1`（Issue #17 で確定。以降のイベント種別・フィールド追加は `schema_version` を上げてから行う）
- 2026-09-30 マスター決定（#18 G5）: `bash_command` は切り詰めず、許可文字外・ベース名化後 32 バイト超過は `?` とする。あわせて共通ルールを実装（`monitor-emit.sh` の jq）に合わせて書き直した（識別子系は検証落ちで値ごと省略・必須キー落ちはイベントごと不送信、`source` `trigger` は未知なら省略、`model` / `usage` は #18 では未送信）。`schema_version` は **1 のまま**: キー集合・型は不変で、新しい記述で許される値の集合は旧記述の部分集合（切り詰めた断片は実装が一度も送っていない）。旧記述で作った検証も、実装が出す全ペイロードを受理できる
- 2026-10-04 #19 受信側の実装（`server/schema.mjs` / `validate.mjs` / `derive.mjs`）に合わせて追記: `usage: {}` の受理、`file_path` の拒否文字集合の列挙、`duration_ms` の整数判定（`1.0` 受理）、「受信側の扱い」節。挙動変更なし。`schema_version` は **1 のまま**（キー・型・許可値の変更なし）
- 2026-10-10 #23 の設計: 新イベント `UsageSnapshot`（`schema_version: 2`。他の10イベントは `1` のまま、イベント別に固定）を追加。キー `usage_status` `unknown_reason` `models` を追加し、#17 で予約して一度も送られていない `model` / `usage` を Stop / SubagentStop から**削除**（許可集合を狭める変更。どのフックも送っていない）。数値の上限を 10,000,000 から 10^12 に変更（累積値のため）。サイズ上限は実測で 16 MiB に確定。実装（schema.mjs / validate.mjs / derive.mjs / pricing.mjs / cost.mjs / monitor-emit.sh）は後続

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
- `usage_status`
- `unknown_reason`
- `models`
<!-- /SCHEMA:KEYS -->
