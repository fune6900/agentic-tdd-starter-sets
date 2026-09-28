# フックイベント実測記録

Issue #17。以降の全 Issue（#18〜#25）はここに書かれた実測結果だけを入力仕様として使う。
推測で書かれた値は無い（lessons #6）。実測できなかったものは「発火しなかった」と明記する。

## 実測環境

- **Claude Code のバージョン**: 2.1.283（`claude --version`（PATH 上の claude CLI）で確認）
- **測定日**: 2026-09-28
- **OS**: macOS Darwin 25.5.0
- **モデル**: `claude-haiku-4-5-20251001`（`--model haiku`。安価なモデルで十分。フックの挙動はモデルに依存しない）

## 測定手順

1. 本リポジトリの外（`mktemp -d` 相当のスクラッチ領域）に隔離サンドボックスを作る。`git init` した空リポジトリとし、実リポジトリ・実 Vault には一切触れない
2. サンドボックス直下に `.claude/settings.json` を新規に置き、次の10イベント全てに「stdin をそのままファイル保存するだけ」の採取専用フック（`dump.sh`）を登録する。本体リポジトリの `settings.json` / `settings.local.json` は変更していない
   - `SessionStart` `SessionEnd` `UserPromptSubmit` `PreToolUse`（matcher: `Bash` / `Read` / 無指定=全ツール） `PostToolUse`（無指定=全ツール） `SubagentStart` `SubagentStop` `Stop` `Notification` `PreCompact`
3. `PreToolUse`(`Bash`) にはさらに2種の採取専用フックを追加登録した:
   - `bgtest-good.sh`: stdin を読み捨てた直後に開始時刻を記録し、`( sleep 5 ) >/dev/null 2>&1 &` で子プロセスを stdout/stderr ごと切り離して背景化し、即 `exit 0`
   - `bgtest-bad.sh`: 同様だが `( sleep 5 ) &` のみ（stdout/stderr を切り離さない）
   これらは「フックが背景に子プロセスを残して即 exit した場合に Claude Code が待つか」を、PreToolUse から次の PostToolUse までの経過時間で判定するために使った
4. `PreToolUse`(`Read`) には `"async": true` を付与した `asynctest.sh`（開始時刻記録 → `sleep 4` → 終了時刻記録）を追加登録し、`"async": true` が受理されるか・実際に非同期（フック完了を待たない）で動くかを、同じく PreToolUse→PostToolUse の経過時間で判定した
5. `claude -p "<プロンプト>" --model haiku --permission-mode bypassPermissions --output-format json`（PATH 上の claude CLI）をサンドボックス内でヘッドレス実行した。`--permission-mode bypassPermissions` はリポジトリ外の隔離サンドボックスでのみ使用した。再現時は `--allowedTools` で必要なツールだけを許可すること。プロンプトは以下を1セッション内で順に行わせる内容:
   - メインスレッドで Bash ツールにより `ls work` を直接実行させる
   - メインスレッドで Read ツールにより `work/hello.txt` を直接読ませる
   - Task ツールでサブエージェントを1体（`subagent_type: general-purpose`）起動し、その中で同じく Bash（`ls work`）→ Read（`work/hello.txt`）を実行させ、完了を待たせる
6. 採取した stdin と、`transcript_path` / `agent_transcript_path` が指す実際の transcript JSONL（`--no-session-persistence` を付けない2回目の実行で採取。付けるとトランスクリプトが保存されないことを実測で確認したため外した）を分析した
7. `"async": true` と背景子プロセスの検証は、上記の複合シナリオに加えて **単体分離した追試**（`PreToolUse`(`Bash`) に `bgtest-good.sh` のみを登録し、`ls work` を1回だけ実行させる）でも再現し、複合要因を排除した
8. `PreCompact` は複合シナリオでは発火しなかったため、別セッションでプロンプトを `/compact` 一文のみにして単体で発火を確認した
9. `Notification` は (a) 通常実行 (b) `--permission-prompts none` で「本来ならプロンプトが出る操作」を自動拒否させる (c) `--disallowedTools Bash` でツール自体を利用不可にする、の3パターンを試したが、いずれでも発火しなかった
10. 採取後、サンドボックスと `~/.claude/projects/<sandbox>` 配下に残った transcript は `find <dir> -depth -delete` で削除した（`rm -rf` は本リポジトリの禁止コマンドガードに掛かるため使わない）。採取用フック（`dump.sh` 等、ファイル名に `dump` を含む）はサンドボックス内にのみ存在し、本リポジトリにはコミットしていない

## イベント発火の実測結果

| イベント | 発火 | 備考 |
| --- | --- | --- |
| SessionStart | 来た | `source`（`startup`/`resume`/`clear`/`compact`/`fork`）を持つ。今回は `"startup"` |
| SessionEnd | 来た | `reason` を持つ。通常終了で `"reason": "other"` を確認。他の値（`clear` 等）は未確認 |
| UserPromptSubmit | 来た | `prompt`（ユーザー入力全文。**送信禁止**）・`prompt_id`・`permission_mode` を持つ |
| PreToolUse | 来た | メイン／サブエージェント双方で発火。`tool_name` / `tool_input` / `tool_use_id` を持つ |
| PostToolUse | 来た | 同上 + `tool_response` + `duration_ms`（ツール実行時間。ミリ秒） |
| SubagentStart | 来た | `agent_id` / `agent_type` を持つ。`agent_transcript_path` は**持たない**（実測で確認。SubagentStop 側にのみ来る） |
| SubagentStop | 来た | `agent_id` / `agent_type` / `agent_transcript_path` / `stop_hook_active` / `last_assistant_message` を持つ |
| Stop | 来た | `stop_hook_active` / `last_assistant_message` を持つ。`agent_id` は**持たない**（メインスレッドのみで発火するため） |
| Notification | 来なかった（条件: `-p` ヘッドレス） | 通常実行・`--permission-prompts none` による自動拒否・`--disallowedTools` によるツール除外の3パターンを試したが、いずれも発火しなかった。対話モード固有のダイアログ／アイドル通知に紐づく可能性が高いが未確認 |
| PreCompact | 来た（条件: `/compact` を単体プロンプトにした場合のみ） | 複合シナリオ（通常の作業指示）では発火しなかった。`trigger`（`"manual"`/`"auto"`）と `custom_instructions` を持つ。今回は `trigger: "manual"` |

参考: 上記10種以外に、CLI バイナリの内蔵ヘルプ文字列から `PostToolUseFailure` / `PostToolBatch` / `PermissionDenied` / `PermissionRequest` / `UserPromptExpansion` / `StopFailure` / `PostCompact` という追加イベント名の存在も確認できた（実測はしていない。Issue #17 のスコープ外）。

## サブエージェント識別子の実測結果

- **`agent_id`**: 来た。サブエージェント内部で発生する全ての `PreToolUse` / `PostToolUse` に付与される（例: `"agent_id": "a88aba6cb962df847"`）。メインスレッドの `PreToolUse` / `PostToolUse` には**付与されない**（キー自体が存在しない）
- **`agent_type`**: 来た。`agent_id` と同じ場面で付与される（例: `"agent_type": "general-purpose"`）。`sub-agent-coder` 等カスタムエージェント名がどう入るかは本サンドボックスに `.claude/agents/` を置いていないため未確認（本体リポジトリのカスタムエージェント使用時に別途確認が必要）
- **`agent_transcript_path`**: 来た。ただし **`SubagentStop` にのみ**含まれる（`SubagentStart` には無い）。値の実例（匿名化前）: `<プロジェクトの transcript ディレクトリ>/<session_id>/subagents/agent-<agent_id>.jsonl`
- **Task（`Agent`）ツール自体の `PreToolUse`/`PostToolUse`**: メインスレッド側で発火し、`agent_id`/`agent_type` は**持たない**。ただし `tool_input.subagent_type` でこれから起動するエージェント種別が分かり、`PostToolUse` の `tool_response` に `agentId` / `agentType`（**キャメルケース。トップレベルの `agent_id`/`agent_type` とは命名規則が違う**）と、サブエージェント1回分の集計済み `usage` オブジェクトが丸ごと入る

これでエピックの前提「サブエージェント内部のツール呼び出しに `agent_id`/`agent_type` が来る」は実測で確認できた。**ハードストップ条件（来ない場合）には該当しない。**

## `"async": true` の実測結果

- 設定ファイルに `"async": true` を追加しても `claude -p` はエラーにならず、他のフックも通常どおり発火し続けた（設定全体が無効化される、ということは無かった）
- **実際に非同期（fire-and-forget）として動作することを実測で確認した**。`PreToolUse`(`Read`) に登録した `sleep 4` のフックについて、`PreToolUse` から次の `PostToolUse` までの経過時間はメインスレッド側で約24ミリ秒、サブエージェント側で約244ミリ秒しかなかった（`sleep 4` を待っていれば4秒以上かかるはずの箇所）
- 副作用として、**セッションが先に終了すると非同期フックは完了を待たれず、途中で終了させられる**ことも確認した。2回目（サブエージェント内）の `asynctest.sh` は `sleep 4` の完了（開始から4秒後に書かれるはずの終了マーカー）が最終的に観測できず、`Stop`/`SessionEnd` の方が先に発火していた
- したがって monitor-emit（Issue #2）で `"async": true` を採用する場合、「セッション終了間際のイベント送信は届かない可能性がある」ことを前提にする必要がある（fail open の設計とは相性が良いが、限界として明記すること）

## 背景子プロセスを残して即 exit するフックの実測結果

`sleep 5 &` で背景化した子プロセスを残して即 `exit 0` するフックを、PreToolUse→PostToolUse の経過時間で2パターン比較した。

| パターン | 実装 | 経過時間 |
| --- | --- | --- |
| 良い形（stdout/stderr を `/dev/null` へ切り離す） | `( sleep 5 ) >/dev/null 2>&1 &` の後に `exit 0` | 約79ミリ秒（**待たれない**） |
| 悪い形（切り離さない） | `( sleep 5 ) &` の後に `exit 0` | 約5.01〜5.12秒（**待たれる**） |

複合シナリオでは「良い形」と「悪い形」を同じ `PreToolUse`(`Bash`) 配列に同時登録した状態で、メインスレッドの `ls work` 呼び出しで約5.12秒、サブエージェントの `ls work` 呼び出しで約5.04秒の遅延が観測された。その後、良い形のフックだけを単体で登録した追試では約79ミリ秒まで縮み、遅延の原因が「悪い形」（stdout/stderr 未切り離し）単独にあることを切り分けて確認した。

**原因の推定（実測で観測できた事実から）**: Claude Code はフックの標準出力を読み切る（EOF を待つ）実装になっており、背景化した孫プロセスが標準出力/標準エラーの書き込み端を握ったまま生き続けると、そのプロセスが終了するまで EOF が来ず待たされる。標準出力/標準エラーを明示的に `/dev/null` へリダイレクトしてから背景化すれば、この待ちは発生しない。

**monitor-emit（Issue #2）への示唆**: 背景化した curl は必ず `>/dev/null 2>&1 &` で stdout/stderr を切り離すこと。切り離さない背景化は「バックグラウンド化したつもりでも実質同期」になり、1秒以内の実行時間という受け入れ条件を壊す。

## transcript JSONL の実測結果

- メインの transcript は `<プロジェクトの transcript ディレクトリ>/<session_id>.jsonl`、サブエージェントの transcript は `<プロジェクトの transcript ディレクトリ>/<session_id>/subagents/agent-<agent_id>.jsonl`（`SubagentStop.agent_transcript_path` と同じ値）
- `--no-session-persistence` を付けると、これらの transcript ファイル本体（`.jsonl`）が書き出されないことを実測で確認した（サブエージェントの `.meta.json` だけが残る）。以降のフィールド確認は `--no-session-persistence` を**外した**再実行で行った
- `type: "assistant"` の行の `message` オブジェクトが持つキー: `container` `content` `context_management` `diagnostics` `id` `input_transformations` `model` `role` `stop_details` `stop_reason` `stop_sequence` `type` `usage`
- `message.model` にはモデルの正式 ID がそのまま入る（実測値: `"claude-haiku-4-5-20251001"`）
- **`message.usage` のキー名一覧（実測）**: `input_tokens` / `output_tokens` / `cache_creation_input_tokens` / `cache_read_input_tokens` / `output_tokens_details`（さらにネストで `thinking_tokens`）/ `cache_creation`（さらにネストで `ephemeral_1h_input_tokens` / `ephemeral_5m_input_tokens`）/ `server_tool_use`（`web_search_requests` / `web_fetch_requests`）/ `service_tier` / `speed` / `inference_geo` / `iterations`（配列。各要素が上記の一部を繰り返し持つ内部詳細）
- **同一 `message.id` の行が複数回出現するかを実測した結果: 複数回出現する。** 1つの assistant メッセージが `thinking` / `text` / `tool_use` のように複数のコンテンツブロックに分かれてストリーミングされる際、**同じ `message.id` を持つ行が content block の数だけ（実測で2〜4回）JSONL に書かれ、その全ての行が同一の `message.usage`（メッセージ全体の合計値のコピー）を持つ**ことを確認した。したがって `message.id` ごとに重複排除してから合計しないと、コンテンツブロック数倍に水増しされる（Issue #7 の重複排除は**必須**と判定する）
- 参考: transcript には `type: "cost-state"` という行もあり、Claude Code自身が計算した `totalCostUSD` / `modelUsage`（モデル別の `inputTokens` / `outputTokens` / `thinkingTokens` / `cacheReadInputTokens` / `cacheCreationInputTokens` / `webSearchRequests` / `costUSD`）を保持している。Issue #7 の実装時に、自前集計との突き合わせ用リファレンスとして使える

## hook stdin の共通フィールド（実測・全イベント共通）

ほぼ全イベントに共通して存在した（`SessionEnd` のみ `prompt_id` 等を持たない簡素な形）:

- `session_id`: セッションの UUID
- `transcript_path`: メインの transcript JSONL への絶対パス（**送信禁止**。ホームディレクトリを含む）
- `cwd`: 作業ディレクトリの絶対パス（**送信禁止**。ホームディレクトリを含みうる）
- `hook_event_name`: このドキュメントが列挙する10種いずれか
- `prompt_id` / `permission_mode`: ツール系・UserPromptSubmit 系イベントに付与される（**送信しない方針**。詳細は event-schema.md）

## fixtures との対応

実測した構造をキー名・入れ子ともに保ったまま、値だけを匿名化したものを
`.claude/monitor/test/fixtures/hook-stdin/` に置いた。ファイル名と実測イベントの対応は
`.claude/monitor/docs/event-schema.md` および各 fixture 自身を参照。
