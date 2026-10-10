---
epic: issue-43
title: "loop-journal flush の確認処理を SIGPIPE に左右されない形にする"
started: 2026-10-11
status: active
---

# インナーループ記録: issue-43

> **このファイルはアウターループ完了時に Vault へ書き写され、削除される。**
> 恒久的な教訓は `.claude/memory/lessons.md` に書く。ここは「何をやって、なぜそうしたか」の経緯。
> 別端末・別作業者が続きを引き継ぐための記録なので、必ずコミットする。

<!-- LOOP-JOURNAL:ENTRIES -->

## 2026-10-10T17:35Z / #43 / start — flush の確認処理の SIGPIPE を直す

- **やったこと**: #43 に着手（エピックに属さない単発。ジャーナルは issue-43）。予算 60 分（ユーザー指示）
- **事実**: エピック ai-monitor の flush で、67 エントリ・524 行が Vault に着地したのに `tail -n N | grep -qF 見出し` が pipefail の下で SIGPIPE（141）になり失敗判定した。`seq 1 200000 | grep -qF 5` で rc=141 を再現済み。同じ形は bootstrap-project.sh 191 行にもある（1 行の短い値で実害は低い）
- **方針と理由**: 確認処理をパイプの終了状態に依存しない形にする（例: 追記分を変数に取ってから case / 件数で判定）。「着地を確認してから消す」順序は崩さない。QA が先に大きなジャーナルの回帰テストで Red を作る（小さな入力では再現しないので、サイズで再現条件を作る）
- **参照した教訓**: #10 判定は親シェル / #23 bash 3.2 と bash 5 の両方 / #24 実装の形を名指し / 運用 テスト結果の終了コードで分岐

## 2026-10-10T17:44Z / #43 / impl — flush の確認処理を変数 + case に

- **やったこと**: QA が 600 エントリ（約 460KB）のジャーナルで flush の回帰テスト 4 件を追加（100 エントリ以上で再現、20・50 では再現しない）して Red。Coder が `tail -n N | grep -qF` を `added="$(tail -n N)"` + `case` に置き換え（判定は親シェル）。bootstrap-project.sh 191 行は 1 行の短い値なので安全な理由をコメントのみ。103 件 PASS（bash 3.2 / bash 5 非 root）。元に戻す変異で 2 件 FAIL
- **なぜ**: パイプの終了状態に頼ると、`grep -q` が先に終わったときに上流が SIGPIPE になり、pipefail の下で失敗扱いになる。判定は値に対して親シェルで行う
- **確かめたこと**: ガード（pre-tool-guard.sh / loop-guard.sh）も `echo | grep -q` だが pipefail を使っていないので、パイプの状態は grep のもの＝長いコマンドでも一致すればブロックされる（すり抜けない）
- **bash 5 の既存 3 件**: root 実行で権限検査 2 件が落ち、python3 の無いイメージで frontmatter 検査 1 件が落ちていた。どちらも環境依存で loop-journal.sh のバグではない
- **次**: G1

## 2026-10-10T17:55Z / #43 / done — 全ゲート PASS（retry 1）

- **やったこと**: flush の確認処理を変数 + case に置き換え、600 エントリの回帰テスト 4 件を追加。G1〜G4 PASS（G5 は起動条件外）。G2 で本物の ai-monitor のジャーナル（67 エントリ・92KB）を一時リポジトリ・一時 Vault で flush し、修正版は成功・修正前は再現して失敗・書き込み不能では失敗してジャーナルが残ることを確認。本物の Vault は無変更
- **retry 1**: 同じ形の洗い出しで bootstrap-project.sh 191 行に安全な理由のコメントを足したら、#24 のテスト「bootstrap-project.sh は main との差分 0」に掛かって G1 が落ちた。コメントは任意だったので取り消し、理由（1 行の短い値なのでパイプバッファに収まり SIGPIPE にならない）はこのジャーナルと PR に残す
- **洗い出しの結果**: `| grep -q` は 4 箇所。loop-journal.sh 767 行（今回修正）、bootstrap-project.sh 191 行（安全・上記）、pre-tool-guard.sh 32 行と .codex 版 45 行、loop-guard.sh 31 行（pipefail を使っていないので grep の状態が採られ、すり抜けない）。.codex に loop-journal.sh は無い
- **残課題**: #24 の凍結テストの見直し（G3 が後続 Issue を推奨）。bash 5 のテストは root 実行で権限検査 2 件、python3 の無いイメージで frontmatter 検査 1 件が落ちる（環境依存）
- **次**: コミット → PR → CI → マージ後に issue-43 のジャーナルを flush（修正版での実地確認を兼ねる）
