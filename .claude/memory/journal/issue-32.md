---
epic: issue-32
title: "経過時間からスリープを除く"
started: 2026-10-10
status: active
---

# インナーループ記録: issue-32

> **このファイルはアウターループ完了時に Vault へ書き写され、削除される。**
> 恒久的な教訓は `.claude/memory/lessons.md` に書く。ここは「何をやって、なぜそうしたか」の経緯。
> 別端末・別作業者が続きを引き継ぐための記録なので、必ずコミットする。

<!-- LOOP-JOURNAL:ENTRIES -->

## 2026-10-10T04:34Z / #32 / start — ハードストップの経過時間からスリープを除く

- **やったこと**: #32 に着手（エピック外の単独 Issue。ジャーナルは issue-32）
- **なぜ**: #21 で Mac のスリープが時間上限に数えられ、作業量と無関係に 2 回ハードストップした（lessons の時間予算の教訓・通算 5 回目）。マスターが「経過時間からスリープを除く」と決定（2026-10-10）。#22 以降も同じ罠を踏むので先に直す
- **方針**: init で「起きていた時間」の基準値と起動 ID を記録し、check/show は差分で数える。取得源は macOS 標準の `/usr/bin/perl` + Time::HiRes の `CLOCK_UPTIME_RAW`（実測でスリープを含まない）、Linux は `CLOCK_MONOTONIC`。測れない・再起動（起動 ID 変化 or 値の減少）・起きていた時間 > 壁時計（異常値）は壁時計に倒す。node の hrtime と macOS の CLOCK_MONOTONIC はスリープを含むので使わない（実測）
- **参照した教訓**: #10 壊れた状態は止まる側に倒す / 戻り値を捨てて止めたつもりが止まらない / `$( )` 内の exit で親は止まらない / シェル検証は case で / 多バイト隣の展開は `${var}` / #5 変異注入で落ちることを確認 / #19 Issue のコマンドは実測してから書く / #18 G1 は CI の全段を回す

## 2026-10-10T04:39Z / #32 / impl — 起きていた時間で経過を数える

- **やったこと**: `loop-state.sh` に `awake_now`（perl の Time::HiRes。Darwin は CLOCK_UPTIME_RAW、他は CLOCK_MONOTONIC）・`boot_id_now`（Darwin は kern.boottime、Linux は boot_id）・`compute_elapsed`（show / check 共有）を追加。init は `awake_start` / `boot_id` を個別に記録（取れなければ null）。show は `elapsed_source` / `wall_elapsed_minutes` を追加。テスト 23 件追加（計 95 件）。`loop-engineering.md` の停止条件に数え方と倒す向きを追記
- **なぜ**: macOS 標準の perl なら追加依存なしでスリープを含まない時計が取れる（実測）。node の hrtime と macOS の CLOCK_MONOTONIC はスリープを含む（実測）ので使わない。測れない・再起動・起動 ID 変化・awake > 壁時計+60 秒は壁時計に倒し、上限が緩む方向には倒さない
- **捨てた選択肢**: 値を差し替える環境変数（テストは楽だが本番でハードストップを無効化できる抜け道になる。テストは PATH に偽 perl / sysctl / uname を置いて注入）／python3（macOS 標準ではない）／`caffeinate -i`（マスターが除外方式を選択）
- **途中の修正**: 異常値ケースのテストが、実行中に壁時計が 1 秒進むと awake に反転する不安定さがあった（Coder が指摘）。差分を +61 秒 → +600 秒にして余裕を持たせ、判定行を外した変異で 2 件 FAIL を確認
- **次**: G1 へ

## 2026-10-10T05:04Z / #32 / gates — G1〜G4 一巡（retry 1 で全 PASS）

- **結果**: 1 巡目 G1 ✅ / G2 ❌。retry 1 後 G1 ✅ / G2 ✅ / G3 ✅ / G4 ✅（高0・中2・低4）/ G5 ⏭️ 起動条件外
- **落ちた内容**: G2 が macOS 実機で、起動 ID に使った `kern.boottime` が同じ起動中でも時刻補正で usec を変える（53346 → 118052）ことを発見。数分で起動 ID が不一致になり壁時計に倒れ、目的を果たせなかった。単体テストは偽の起動 ID だったため拾えなかった
- **差し戻し先**: QA（usec が呼ぶたびに変わる偽 sysctl で回帰テスト）→ Coder（`kern.bootsessionuuid` に変更）
- **なぜそう判断したか**: `kern.bootsessionuuid` は起動ごとの UUID で同じ起動中は不変（実測）。boottime の sec 部分だけにする案は、時刻補正が秒をまたげばやはり変わるので捨てた。再 G2 で init から 5 分 16 秒後も awake のままを実機確認
- **G3 の判断**: 実際のスリープは挟まず、起動からの実測（壁時計 1197332 秒 / CLOCK_UPTIME_RAW 436749 秒＝スリープ約 8.8 日分を除外）で代替して意図充足。Linux は Docker の perl:5-slim で awake を確認（CI 上ではなく、CI は loop-state テストの実機 perl 検査で代える）。差し替えを環境変数でなく PATH の偽コマンドにしたのは意図の範囲内
- **次**: Refactor（G4 中2: グローバル返却の明記と ELAPSED_LABEL 化／偽 sysctl のヒアドキュメント化）→ G1 再実行

## 2026-10-10T05:09Z / #32 / done — PR #34 作成・全ゲート PASS

- **やったこと**: PR #34 を作成。G1〜G4 PASS（G5 は起動条件外）、retry 1（G2: macOS の起動 ID）。Refactor（compute_elapsed が ELAPSED_LABEL も返す・偽 sysctl をヒアドキュメント化）後に G1 を再実行して PASS
- **なぜ**: 起動 ID を `kern.bootsessionuuid` にしたのが最終的に効いた。`kern.boottime` は時刻補正で usec が変わり、数分で壁時計に倒れていた
- **実機の記録**: macOS は起動からの壁時計 1197332 秒に対し CLOCK_UPTIME_RAW 436749 秒（スリープ約 8.8 日分を除外）。init から 5 分 16 秒後も awake。Linux は Docker の perl:5-slim で awake。Debian slim の perl-base は Time::HiRes が無く壁時計に倒れる。実際のスリープを挟む確認はしていない
- **残課題**: 実際にスリープを挟む確認（`pmset sleepnow` を使う手動確認）／CI の ubuntu で awake になるかは CI の実機 perl 検査の結果で確かめる
- **次**: エピック ai-monitor の #22（ループ状態パネル）。この PR がマージされるまで、ループの経過時間は従来どおり壁時計
