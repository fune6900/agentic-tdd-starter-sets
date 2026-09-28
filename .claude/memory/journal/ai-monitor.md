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
