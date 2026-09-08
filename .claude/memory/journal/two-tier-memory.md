---
epic: two-tier-memory
title: "外部記憶の2層化"
started: 2026-09-08
status: active
---

# インナーループ記録: two-tier-memory

> **このファイルはアウターループ完了時に Vault へ書き写され、削除される。**
> 恒久的な教訓は `.claude/memory/lessons.md` に書け。ここは「何をやって、なぜそうしたか」の経緯。
> 別端末・別作業者が続きを引き継ぐための記録なので、必ずコミットする。

<!-- LOOP-JOURNAL:ENTRIES -->

## 2026-09-08T11:28Z / #0 / impl — loop-journal.sh の実装

- **やったこと**: `.claude/scripts/loop-journal.sh`（init/context/start/inner/outer/flush/status/where）を追加。
  `loop-state.sh init` に第3引数 `epic` を追加し、ジャーナルの宛先解決に使えるようにした。
  `issue-flow` / `epic-flow` / `loop-retro` / `loop-status` と Codex 側の対応コマンドに読み書きを組み込んだ
- **なぜ**:
  - 読む先の判定（内部か Vault か）を AI の判断に委ねると必ずブレる。`context` サブコマンドに機械判定させた
  - エピック slug の解決を「引数→env→loop-state.json→.active→ブランチ名→唯一のジャーナル」の
    多段フォールバックにした。別端末で `.active` が無くても復帰できるようにするため
- **捨てた選択肢**:
  - Vault パスを `settings.json` に書く案 → テンプレートなので機械依存のパスをコミットしたくない。
    env 変数 + gitignore 済みローカルポインタにした
  - Vault 側を「エピック1本＝1ファイル」にする案 → マスターの指定で `projects/<project>.md` 1枚に追記

## 2026-09-08T11:28Z / #0 / gates — 自己検証

- **結果**: このリポジトリに npm のテスト基盤は無いため、G1 相当はシェルの構文検査と手動シナリオで代替した
- **見つけた不具合と修正**:
  1. `die` を `$(...)` の中で呼んでも親シェルは死なない。Vault 未接続で `flush` した際、
     エラーを出したまま `rm` まで到達して**内部ジャーナルを削除した**（データ損失）。
     → Vault の判定を親シェルに出し、Vault への着地を `grep` で確認するまで削除しない構造に変更
  2. 全角括弧の直前の `$vf` を bash が変数名の一部として解釈し `unbound variable` で落ちた。
     → 多バイト文字に隣接する変数展開を全て `${var}` に修正
- **なぜ 1 が起きたか**: 「検証関数の中で die すれば安全」という前提が、コマンド置換では成立しないため
