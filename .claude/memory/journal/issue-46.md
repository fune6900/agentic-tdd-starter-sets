---
epic: issue-46
title: "issue-46"
started: 2026-10-11
status: active
---

# インナーループ記録: issue-46

> **このファイルはアウターループ完了時に Vault へ書き写され、削除される。**
> 恒久的な教訓は `.claude/memory/lessons.md` に書く。ここは「何をやって、なぜそうしたか」の経緯。
> 別端末・別作業者が続きを引き継ぐための記録なので、必ずコミットする。

<!-- LOOP-JOURNAL:ENTRIES -->

## 2026-10-11T01:20Z / #46 / start — bootstrap-project.sh の凍結テストを振る舞いのテストに置き換える

- **やること**: #24 の bootstrap-monitor テストのうち、`bootstrap-project.sh` の HEAD / main との差分 0 を要求する 2 件を置き換える
- **なぜ**: #43 でコメントを 2 行足しただけで G1 が落ちた。main との差分 0 は #24 の範囲を超えた恒久的な凍結で、今後このファイルを正当に直す Issue を必ず落とす
- **方針**: 案 (a)。#24 の意図「bootstrap-monitor の追加が bootstrap-project を壊さない」を、差分ではなく振る舞いで固定する。同じ導入先で両方を流し、bootstrap-project 単独の場合と ci.yml が同一であることと、bootstrap-monitor が `.github` に触れないことを確かめる。bootstrap-project 自体の振る舞いは `bootstrap.test.sh`（60 件超）が既に守る。登録順は settings.json のテストが守る
- **捨てた選択肢**: (b) #24 のマージコミットとの差分。#24 で触っていないことは履歴で既に確定しており、テストとして守る価値が無い
- **参照した教訓**: #43「既存を壊さない」を固定するテストはその Issue の範囲で書く / #5 変異注入で落ちることを確認 / #23 bash 3.2 の G1 は CI の bash 5 を代替しない

## 2026-10-11T01:30Z / #46 / impl — 凍結テスト 2 件を共存の振る舞いテスト 7 件に置き換えた

- **やったこと**: `bootstrap-monitor.test.sh` から差分 0 を要求する 2 件を削除し、suite「bootstrap-project との共存」に 7 件を追加（466 → 471 件）。単独 / project→monitor / monitor→project で ci.yml がバイト一致、両順序で exit 0、monitor が `.github` に何も作らない、既存 ci.yml のバイトと mtime を変えない。前提確認 2 件（単独で ci.yml が出る・monitor が実際に動いた）で比較の空振りを防ぐ
- **なぜ**: #24 の意図は「monitor の追加が project を壊さない」で、壊し方として現実にあるのは「monitor が CI 生成に影響する」「monitor が `.github` に触る」の 2 つ。ファイル内容の固定ではなくこの 2 つを振る舞いで見れば、project を直す後続 Issue を落とさずに意図を守れる
- **確認**: project.sh にコメント 1 行を足して `tests/run.sh` 14 スイート PASS（凍結解除）。変異（monitor が ci.yml を書き換える / workflows に別ファイルを作る）で新テストが 4 件 / 2 件 FAIL。bash 5（非 root）で新 suite 7 件 PASS。shellcheck -S warning 0
- **次**: G1 へ

## 2026-10-11T01:58Z / #46 / gates — G1〜G4 一巡で全 PASS（retry 0）

- **結果**: G1 ✅（13 スイート・監視イメージ 68 件・bash 5 非 root で 464/465、落ちたのはコンテナ内に docker が無い 1 件のみ）/ G2 ✅（コメント追記と `:` 挿入の両方で全 PASS、手動サンドボックスで両順序の ci.yml が cmp 一致、変異で新テスト 4 件 FAIL）/ G3 ✅ / G4 ✅（高0・中1・低3）/ G5 ⏭️ 起動条件外
- **G3 の判断**: 「ゲートを通すためのテスト削除」に当たらない。#24 の「差分 0」が守ろうとしたのはバイト列ではなく「monitor の追加が project の動作を壊さない」で、共存 7 件と settings.json suite（同ファイル 1065〜1087 行）が守る。project.sh 自体の誤りは bootstrap.test.sh の担当
- **Refactor**: G4 中「monitor が早期離脱しても .github 系の 2 件が PASS する」→ 合格条件に compose.monitor.yml の存在を追加し、`exit 0` を差し込む変異で FAIL を確認。低: co_project も `--quiet`（本番フックと同じ）、`CI` → `CI_FILE`、コメント補足。再 G1 で 13 スイート PASS・shellcheck 0
- **次**: PR

## 2026-10-11T01:59Z / #46 / done — PR #48 作成・全ゲート PASS

- **やったこと**: PR #48 を作成。G1〜G4 PASS（G5 は起動条件外）、retry 0。Refactor（空振り防止・--quiet 統一・CI_FILE 改名）後に G1 を再実行して PASS
- **なぜ**: 凍結を解く鍵は「#24 の差分 0 が何を守ろうとしていたか」を壊し方 2 つ（CI 生成への影響・.github への接触）に言い換えたこと。そうすればファイル内容を固定せずに意図を守れる
- **残課題**: なし。マージ後に issue-46 のジャーナルを Vault へ flush する
- **次**: マージ判断（ユーザー）
