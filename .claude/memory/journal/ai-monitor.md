---
epic: ai-monitor
title: "AIオーケストレーション監視ツール"
started: 2026-09-28
status: active
---

# インナーループ記録: ai-monitor

> **このファイルはアウターループ完了時に Vault へ書き写され、削除される。**
> 恒久的な教訓は `.claude/memory/lessons.md` に書け。ここは「何をやって、なぜそうしたか」の経緯。
> 別端末・別作業者が続きを引き継ぐための記録なので、必ずコミットする。

<!-- LOOP-JOURNAL:ENTRIES -->

## 2026-09-27T15:34Z / #17 / start — フック stdin と transcript の実フィールドを実測し fixtures とスキーマ文書に固定する

- **やったこと**: #17 に着手
- **なぜ**: 後続 8 本すべてがフック入力の形に依存する。推測で書けば全部が買い直しになる（lessons #6）
- **方針**: 隔離サンドボックスに stdin ダンプ用フックだけを置いた settings を作り、`claude -p`（2.1.283）をヘッドレスで回してサブエージェントを1体起動させ実データを採取する。本体の settings.local.json は触らない（受け入れ条件の「撤去」を構造的に不要にするため）
- **参照した教訓**: #6 推測禁止 / #5 変異テスト / #11 行き先の全数列挙（fixtures に個人情報を残さない）

## 2026-09-27T16:16Z / #17 / impl — 実測と fixtures・スキーマ確定

- **やったこと**: QA が `tests/scripts/monitor-fixtures.test.sh`（Red）、Architect が隔離サンドボックスで `claude -p`（2.1.283, haiku）を回して実測し、`.claude/monitor/docs/{hook-events,event-schema}.md` と fixtures（hook-stdin 18 / emitted 20）を作成
- **実測で確定した事実**: サブエージェント内ツール呼び出しに `agent_id`/`agent_type` あり（メインには無い）→ エピックの前提は維持。`agent_transcript_path` は SubagentStop のみ。Notification は -p で未発火。`async: true` は fire-and-forget で機能するがセッション終了時は打ち切られる。背景子プロセスは fd を切り離さないと Claude Code が EOF まで待つ（5秒待たされた）。transcript は同一 message.id がブロック数だけ複製され usage も複製 → dedup 必須
- **なぜこのスキーマか**: allowlist のみ。session_id / tool_use_id はエージェント木と実行中ツール判定に代替不可なので送る。cwd / transcript_path / prompt / tool_input / tool_response はパス・自由文字列で要件に不要なため送らない（行き先を増やさない＝lessons #11）。`schema_version` を必須にし非互換を機械検出
- **捨てた選択肢**: 本体 settings.local.json への一時登録（撤去漏れリスク。隔離サンドボックスで構造的に回避）
- **付随修正**: epics ファイルが未実装の bootstrap-monitor.sh をパス付きで参照し docs-consistency が FAIL していたため、テストは緩めず表記を修正
- **次**: G1 へ

## 2026-09-27T16:49Z / #17 / gates — 一巡目（再開後）

- **結果**: G1 ✅ / G2 ✅ / G3 ✅ / G4 ❌ / G5 起動条件外
- **落ちた内容**: G4 高 1件 — `hook-events.md` に実ユーザー名入りの CLI パスが2箇所残存。fixtures は匿名化済みだが漏洩検査 `check_no_leak` の対象が `fixtures/**/*.json` のみで docs が範囲外だったため機械検査を素通りした。中 2件 — `mktemp -d`+SANDBOXES 登録の3重複、スキーマ部分集合判定の3重複（自己診断側が本体と別実装）
- **差し戻し先**: 検査範囲の漏れ（テスト設計）→ QA、docs の匿名化と重複排除 → Coder
- **なぜそう判断したか**: 生パスを直すだけでは同じ漏れが次の docs 追記で再発する。「入力の行き先を全数列挙」（lessons #11）の再発であり、検査を docs まで広げるのが本体。G5 は起動しない: 変更は docs の文字列のみで G5 起動条件（境界・認証・SQL・シークレット・依存）に該当せず、個人情報の混入はテスト拡張で機械的に塞ぐ

## 2026-09-27T22:44Z / #17 / halt — 時間上限で2度目の停止（retry 1 の修正途中）

- **やったこと**: retry 1 / G4 差し戻し対応中に時間上限（90分）を超過して停止。検知時点で経過 368 分
- **各リトライで変えたこと**: retry 1「漏洩検査を docs/*.md まで拡張（QA）、hook-events.md の生パス匿名化と重複2種の共通化（Coder）」。QA の Red（docs 漏洩で1件 FAIL）は完了。Coder は起動直後に Benz が停止したため docs は未修正（生パス2箇所が残存）
- **推定原因**: QA サブエージェントの所要が約 5.9 時間（21,235 秒）と記録された。作業量（ツール 22 回）に対して異常に長い。端末のスリープ・エージェントの待機など何が起きたかは**未確定**。loop-state の時間上限は壁時計で測るため、停滞も経過に数えられる
- **成果物の状態**: `tests/scripts/monitor-fixtures.test.sh`（docs 検査追加済み・Red）、`.claude/monitor/`（docs に生パス2箇所残存）。全て未コミット
- **次**: マスターの判断待ち

## 2026-09-28T21:32Z / #17 / halt — 時間上限で3度目の停止（G2 PASS 後）

- **やったこと**: retry 1 の修正（docs 匿名化・テスト重複の共通化）→ G1 ✅ → G2 ✅（記録済み）。G2 のエージェントが報告前に 600 秒無応答で打ち切られ、その後セッションが翌日まで放置され経過 1365 分で停止
- **各リトライで変えたこと**: retry 1 のみ（前回停止時と同じ内容を継続）
- **推定原因**: 品質ではなく壁時計。マスター不在中に経過時間が積み上がった（2 回目と同じ構造）
- **次**: マスターの「続きをお願いします」で再開。変更は無いが clear でゲート記録が消えるため G1 から回し直す

## 2026-09-28T21:46Z / #17 / gates — 二巡目（retry 1 後）全 PASS

- **結果**: G1 ✅ / G2 ✅ / G3 ✅ / G4 ✅ / G5 起動条件外
- **前回指摘の解消**: docs の実パス残存（高）→ `check_doc_no_leak` で docs/*.md も検査し匿名化。重複2種 → `new_tmp_dir` / `extra_keys` に集約（G4 で確認）
- **残った低指摘（差し戻さない理由: 重要度低・PASS 条件外）**: G3「emitted の値制約が未検査」「Notification の emitted fixture が無い理由が未明記」「docs の実測結果は語の存在しか検査していない」→ Issue 2 起票時に Planner へ渡す。G4「`new_tmp_dir` と lib.sh の `new_sandbox` が同型」→ 次に lib.sh を触る Issue で統合
- **epics の1行修正の理由**: docs-consistency が未実装の bootstrap-monitor.sh をパス付き参照で FAIL させたため、テストを緩めず表記を散文にした。Issue 5 着手時にパス表記へ戻す

## 2026-09-28T21:46Z / #17 / done — #17 完了

- **結果**: 実測 fixtures（hook-stdin 18 / emitted 20）とスキーマ文書を確定。`agent_id` は実在するのでエピック前提は維持
- **次への申し送り**: 後続 Issue は `.claude/monitor/docs/event-schema.md` と fixtures を唯一の入力仕様にする。transcript の usage は message.id で dedup 必須。Notification は -p で未発火なので実測値なし

## 2026-09-28T22:37Z / #17 / start — PR #27 レビュー指摘（中3件）の修正

- **やること**: 独立レビュー（PR #27）の中3件を直す。(1) epics/ai-monitor.md:10 の実ユーザー名入り絶対パス除去＋漏洩検査を `.claude/memory/**` へ拡張 (2) check_no_leak をキー名にも適用 (3) stdin のダミー秘密値が対応 emitted に現れないことをテストで固定
- **なぜ**: (1) は main に実名が載る。検査範囲外で CI を素通りした＝lessons #11 の再々発。パスだけ直すと次の記録追記で再発するので検査範囲ごと直す。(2)(3) は検査が「見ているつもりで見ていない」穴（lessons #5）
- **方針**: QA が自己診断（変異注入）を先に書いて Red → Coder が検査と epics を修正。低3件はマスター指示で対象外

## 2026-09-28T22:39Z / #17 / impl — レビュー指摘の修正完了

- **やったこと**: QA が `.claude/memory` の追跡 md の漏洩検査・キー名の自己診断・stdin↔emitted の秘密値非出現とベース名一致の検査を追加（Red 2件）。Coder が epics 行10のパスを `~` 表記に、`check_no_leak` を値＋キー名の1経路に統合
- **なぜ**: パスだけ直すと次の記録で再発する。検査範囲を記録の置き場まで広げるのが本体
- **捨てた選択肢**: epics 行65（受け入れ条件の文中の ホーム配下を示す字面）の誤検知に除外を設ける案。除外は穴になる（lessons #9 の構図）ので文言の言い換えで回避
- **結果**: monitor-fixtures 175件 PASS / run.sh 全8スイート PASS
- **次**: G1 へ

## 2026-09-28T22:47Z / #17 / gates — レビュー修正のゲート一巡

- **結果**: G1 ❌→✅ / G2 ✅ / G3 ✅ / G4 ✅（中2件は Refactor で解消し G1 再実行 ✅）/ G5 起動条件外
- **FAIL 内容**: G1 — Benz 自身のジャーナル記述が新設の memory 検査に掛かった。検査は緩めず文言を言い換え（retry 1）
- **Refactor**: G4 中2件（同一の自己診断の重複、禁止パターンの二重列挙 → `LEAK_PATTERNS` に集約）。規約違反ではないが今回書いたコードの重複なので同じ PR で消した
- **次 Issue への申し送り**: whoami の部分一致が記録の一般語に誤検知しうる（G3）、`secret_words_in_emitted` の jq 再実行・短語の誤一致・名指し fixture の存在確認（G4 低）。PR レビューの低3件も未対応

## 2026-09-28T22:47Z / #17 / done — PR #27 レビュー指摘（中3件）修正完了

- **結果**: 中3件を解消。monitor-fixtures 174件 / run.sh 全8スイート PASS。lessons に #11 の再発と「検査語を字面で書かない」を記録
- **次**: push して PR #27 を再レビュー

## 2026-09-29T18:44Z / #18 / start — monitor-emit フックが allowlist 抽出したイベントだけを 1 秒以内・常に exit 0 で 127.0.0.1 へ送る

- **やったこと**: #18 に着手。時間予算は Issue に無かったため、教訓に従い 120 分で init（受け入れ条件 15 件 + G5 必須。実セッションは回さない）
- **なぜ**: #17 で入力仕様が確定し、送信側がエピックの最初の実装。サーバ（#19）の契約テストはここの実データを使う
- **方針**: QA が node 製スタブ受信器と `tests/scripts/monitor-emit.test.sh` を先に書く（Red）→ Coder が `.claude/hooks/monitor-emit.sh` と settings 登録、security.md の限界節。送信は jq で allowlist 抽出 → curl に stdin で渡し `--noproxy '*' --max-time` 付きで `>/dev/null 2>&1 &` 背景化（#17 実測: 切り離さない背景化は実質同期）。値の検証は `case`。fail open はネットワーク失敗のみ、検証できない値は `?`・空へ倒す
- **参照した教訓**: #11 行き先の全数列挙（送信ボディ / curl argv / stderr / 一時ファイル）/ #10 case で検証・fail open と fail closed の区別・`$( )` 内 die / #5 変異テスト・多バイト隣接 / #15 限界は止まる範囲で書き既知の限界テストで固定 / #9 入力を書き換えてから走査しない / #17 検査語を記録に字面で書かない

## 2026-09-29T19:10Z / #18 / impl — monitor-emit 実装完了

- **やったこと**: QA が `tests/scripts/monitor-emit.test.sh`（259件）・node スタブ `tests/scripts/fixtures/monitor-stub.mjs`・settings の基準 fixture を作成（Red 229件）。Coder が `.claude/hooks/monitor-emit.sh`、settings.json への9イベント登録（既存定義は無変更）、security.md「監視の限界（送信側）」節を追加（Green 259件 / run.sh 全9スイート）
- **なぜこの設計か**: 抽出と検証を静的な jq プログラム1回に集約し、ペイロードは stdin でのみ渡す → jq・curl の argv に値が載らず、basename/sed 等も起動しない（行き先を増やさない＝lessons #11）。jq の正規表現は `\A`…`\z`（Oniguruma の `^$` は行単位＝lessons #10 の複数行すり抜けと同型）。先頭トークンは許可文字検証 → ベース名 → 32 バイトの順（`x=/a/b` がベース名化で漏れるのを防ぐ）。curl は `--noproxy '*' --connect-timeout 1 --max-time 3` で `{ …; } >/dev/null 2>&1 &`。`async` は不要（#17 実測: fd 切り離しで待たされない）
- **捨てた選択肢**: grep/sed/basename 抽出・`jq --arg`（argv に値が載る）、一時ファイル経由（行き先が増える）、`reason` 実値の素通し（スキーマ違反。`clear`/`logout` 等は `unknown` に丸まる → #19 の表示で要確認）
- **変異テスト**: allowlist→116件 FAIL / 制御文字除去→6 / 長さ制限→3 / 背景化→2 / stdout切り離し→3 / `--max-time`→1 / `--noproxy`→9 / ポート検証→13 / `LOOP_MONITOR=0`→2。全防御で対応テストが FAIL
- **次**: G1 へ

## 2026-09-29T22:11Z / #18 / halt — 時間上限で停止（G5 FAIL 直後）

- **やったこと**: retry 0 / G5 で停止。G1〜G4 PASS（G4 中2件は Refactor で解消し G1 再実行 PASS）→ G5 FAIL と同時に時間上限（経過 205 分 / 120 分）
- **各リトライで変えたこと**: なし（retry 0）
- **G5 FAIL の内容**: 高1 — curl に `-q` が無く `.curlrc`（`CURL_HOME`/`XDG_CONFIG_HOME`/`HOME`）で宛先追加・付け替え・ボディのファイル書き出しができる（AC10 と security.md の主張に反する。PoC 再現済み）。中2 — jq が `~/.jq` を自動読込し組み込み関数（`test`/`with_entries` 等）を上書きされ allowlist 迂回・環境変数混入。中3 — `bash_command` は 32 バイト超で切り詰めて先頭 32 バイトを送る（security.md の限界の書き方が挙動と不一致）。低 — `file_path` に U+2028/ALM/ゼロ幅が残る、settings.json の `$CLAUDE_PROJECT_DIR` 非クォート
- **推定原因（時間）**: G5 サブエージェント1体の所要が約 157 分（9,395 秒・ツール 16 回）。G1〜G4 と Refactor は 19:34Z までに完了（経過約 49 分）。作業量に対し異常に長い。何が起きたかは**未確定**（#17 の QA 5.9 時間と同じ形）
- **推定原因（G5）**: 確定。外部ツールが HOME 配下の設定ファイルを暗黙に読むことを、入口の列挙に数えていなかった
- **成果物の状態**: 全て未コミット（monitor-emit.sh / settings.json / security.md / テスト / スタブ）。ジャーナルのコミットも loop-guard にブロックされたため未コミット
- **次**: マスターの判断待ち

## 2026-09-29T22:44Z / #18 / impl — G5 差し戻し（retry 1）の修正

- **やったこと**: QA が G5 の3件を固定するテストを追加（259→331件、Red 26件）。Coder が curl 第1引数に `-q`、jq を `HOME=/dev/null` で起動、`bash_command` はベース名化後 32 バイト超で `?`。security.md の送る項目・止める仕組み・既知の限界を更新
- **なぜ**: `.curlrc` は `CURL_HOME`/`XDG_CONFIG_HOME`/`HOME` の3経路があり HOME 差し替えだけでは塞げない → `-q` 必須。jq には `~/.jq` 自動読込を止めるスイッチが無い（`-L` を付けても効いた、実機確認）→ HOME 差し替え。`/dev/null` は両 OS に必ずあり、`/dev/null/.jq` は ENOTDIR で読めない。実在しないパスは攻撃者に作られる余地がある。32 バイト超を `?` にするのはマスター決定（切り詰めは長い秘密の大半を送る）
- **捨てた選択肢**: `HOME=/var/empty`（macOS で実在保証なし）、`HOME=/nonexistent/x`（作られうる）、`jq -L`（効かない）、32 バイト切り詰めのまま限界として書く案
- **変異テスト**: `-q` 除去→18件 FAIL / jq HOME 差し替え除去→2 / `?` 化を切り詰めに戻す→4
- **次**: G1 から回し直す

## 2026-10-04T07:19Z / #18 / gates — retry 1〜2 後のゲート一巡（全 PASS）

- **結果**: G1 ✅ / G2 ✅ / G3 ❌→✅ / G4 ✅ / G5 ✅（retry 2）
- **落ちた内容**: retry 1 後の G3 — `event-schema.md` の `bash_command`（最大32バイト＝切り詰めと読める）が、マスター決定後の実装（32 バイト超は `?`）とずれていた。#19 の契約になる文書なので差し戻し
- **差し戻し先**: Architect（スキーマ文書の担当）。実装はマスター決定に従っているので文書側を直す判断。あわせて共通ルールを識別子系／自由テキスト系／bash_command の3分類に書き直した
- **G5 再検証**: 前回の3件は PoC 再実行で塞がりを確認。別経路（`-q` でも効く env、`JQ_LIBRARY_PATH` 等、ロケール）も無し。`BASH_ENV` は全フック共通の既存・範囲外（低）
- **その他**: retry 2 後の G3 エージェントが 600 秒無応答で打ち切られ、同じ指示を絞って再起動して PASS
- **申し送り（低）**: `duration_ms` の `1.0` 表記は整数として通る → #19 は値の整数性で判定。README のフック一覧に monitor-emit 未記載。`.codex/hooks.json` は対象外。同期 jq のレイテンシ・stdin サイズ上限が条件に無い。`$CLAUDE_PROJECT_DIR` 非クォートと `BASH_ENV` は全フック共通の別 Issue 候補。G4 低3件（テストの `new_tmp_dir` 重複、固定 sleep の理由、jq の不要な `// "?"`）

## 2026-10-04T07:21Z / #18 / done — #18 完了（PR #28）

- **やったこと**: PR #28 を作成。全ゲート PASS（retry 2、時間上限のハードストップ1回をマスター指示で上限なし再開）
- **なぜ**: 最終的に効いたのは curl `-q` と jq の `HOME=/dev/null`。宛先固定は argv と env を塞ぐだけでは足りず、ツール自身が読む設定ファイルまで塞ぐ必要があった。32 バイト超の `?` 化はマスター決定
- **残課題**: README のフック一覧未記載、同期 jq のレイテンシ・stdin 上限、全フック共通の `$CLAUDE_PROJECT_DIR` 非クォートと `BASH_ENV`、G4 低3件
- **次**: #19（受信サーバ）。契約は `event-schema.md`（retry 2 で実装に一致させた）。`duration_ms` は値の整数性で判定（`1.0` 表記が来る）。`reason` は `other`/`unknown` の2値。`model`/`usage` は #18 では未送信（#23 で追加）
