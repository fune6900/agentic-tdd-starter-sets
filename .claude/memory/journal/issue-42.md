---
epic: issue-42
title: "issue-42"
started: 2026-10-11
status: active
---

# インナーループ記録: issue-42

> **このファイルはアウターループ完了時に Vault へ書き写され、削除される。**
> 恒久的な教訓は `.claude/memory/lessons.md` に書く。ここは「何をやって、なぜそうしたか」の経緯。
> 別端末・別作業者が続きを引き継ぐための記録なので、必ずコミットする。

<!-- LOOP-JOURNAL:ENTRIES -->

## 2026-10-11T12:18Z / #42 / start — 祖先にだけ compose がある導入先の案内文を分ける

- **やること**: #42。bootstrap-monitor.sh の案内文 GUIDE_TEXT は、既存 compose が祖先にだけある場合も直下用の include 例（path: compose.monitor.yml / project_directory: .）を出す。その例どおりに祖先の compose へ追記すると docker compose config が失敗する
- **方針**: 探索は既に DIRECT_CAND / ANCESTOR_CAND を分けて持っている。直下に候補があれば従来の GUIDE_TEXT（不変）。直下に無く祖先にだけあれば、祖先用の固定文言（追記先は直下ではないので path と project_directory を「その compose から見た導入先の相対パス」に合わせる、形の例は `sub` のような仮の名前、詳細は README「既存の compose ファイルがある場合」）を出す。直下用の例の行は載せない。直下と祖先の両方にあれば直下を優先（直下の compose が導入先で読まれるため）
- **なぜ固定文言か**: 実パスを載せると外部由来の値がセッションのコンテキストに入る経路になり G5 が要る。案内は README の節へ誘導すれば足り、正しい形（sub・a/b で実測済み）は README に既にある。ユーザーと合意（時間上限 60 分・G5 不要）
- **参照した教訓**: #24 探索の結果を抑止と起動に分けて使う / #25 文書の手順は分岐ごとに実行して確かめる / 出力はコンテキストに入る（固定文言のみ）/ #46 振る舞いで固定し、ファイル内容を凍結しない

## 2026-10-11T12:50Z / #42 / impl — 祖先用の固定案内 GUIDE_TEXT_ANCESTOR を足し、案内の選択を 1 箇所にした

- **やったこと**: bootstrap-monitor.sh に GUIDE_TEXT_ANCESTOR（固定文字列。祖先にある旨・path と project_directory を相対パスに合わせる旨・仮の名前 sub の例・README の節名・Compose v2.20.0・名前衝突の注意）を追加。探索の直後で GUIDE を 1 回だけ決め、dry-run / 生成時 / 非生成時の 3 箇所で使う。GUIDE_TEXT は不変。テスト: 新 suite「案内文の出し分け」（572 件に）、docs-consistency に README の節名の実在と案内文が節名を含むことの検査 2 件
- **なぜ**: 選択を 3 箇所に散らすと分岐の取り違えが起きうるので 1 箇所に集めた。例の名前を sub に固定したのは、実パスを載せると外部由来の値がコンテキストに入る経路になるため。README の節名を文書整合の検査に入れたのは、節名を変えたら案内が宙に浮くため
- **変異**: 直下・祖先の判定を入れ替えると FAIL、祖先用文言に直下用の例を混ぜると 25 件 FAIL
- **次**: G1 へ

## 2026-10-11T13:02Z / #42 / gates — G1〜G4 一巡で全 PASS（retry 0）

- **結果**: G1 ✅（13 スイート・bash 5.2 で 565/566、落ちたのはコンテナ内に docker が無い 1 件）/ G2 ✅（祖先の compose に案内の例どおり追記して docker compose config rc=0、直下用の例では rc=1。ZZUNIQ42 のディレクトリ名は出力に 0 件）/ G3 ✅（判定の入れ替えで約 119 件 FAIL を確認）/ G4 ✅（高0・中1・低3）/ G5 ⏭️ 固定文言のみのため不要（ユーザー合意）
- **Refactor**: G4 中「fixed_out の両分岐で mkproj が重複」→ mkproj を if の外へ。低 3 件（suite の setup の重なり・GUIDE_TEXT の複製は契約テストとして意図的・awk の終端判定）は対応せず。再 G1 で 13 スイート PASS・shellcheck 0
- **次**: PR

## 2026-10-11T13:02Z / #42 / done — PR 作成・全ゲート PASS

- **やったこと**: G1〜G4 PASS、retry 0。祖先にだけ compose がある導入先には、sub の仮の例と README の節名を示す固定の案内を出す
- **なぜ**: 実パスを載せずに README へ誘導すれば、外部由来の値をコンテキストに入れずに正しい形（#25 で実測済み）へ導ける
- **残課題**: なし。マージ後に issue-42 のジャーナルを flush
- **次**: マージ判断（ユーザー）
