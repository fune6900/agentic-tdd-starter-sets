# epic flow（アウターループ）

大きな要件を Issue に分解し、1本ずつインナーループに流し、セッションを跨いで学習させる。

詳細な定義は `.claude/rules/loop-engineering.md` と `.claude/commands/epic-flow.md` を参照する。

## 手順

0. **前回までの記録を読む（★最初の行動・必須）**:
   ```bash
   bash .claude/scripts/loop-journal.sh context
   ```
   内部ジャーナルが残っていれば前のエピックが未完了という意味。閉じるか継続可否を確認する。
   Vault 未接続の端末では `bash .claude/scripts/loop-journal.sh init <vault-path>` で先に繋ぐ。
1. `.claude/memory/lessons.md` を読む（必須）。
2. エピックを Issue に分解する。各 Issue に以下を**全て**定義する:
   - 目的 / 意図 / 受け入れ条件（機械判定可能）/ 依存関係 / 影響範囲 / セキュリティ確認の要否
   - ゴールが一行で言い切れない Issue は分解が足りていない。割り直す。
3. 分解結果を `.claude/memory/epics/<epic-slug>.md` に書く。
   エピックのジャーナルを開き、分解結果を Vault に記録する（アウターの節目）:
   ```bash
   bash .claude/scripts/loop-journal.sh start <epic-slug> "<エピック名>"
   bash .claude/scripts/loop-journal.sh outer plan "分解完了" <<'ENTRY'
   - **やったこと**: Issue N 本に分解
   - **なぜ**: <この切り方にした理由>
   ENTRY
   ```
4. **ユーザーの承認を得る（★必須の関門）**。承認前に実装へ進まない。
5. エピック用ブランチ `epic/<epic-slug>` を作り、承認された Issue を起票する。
6. 依存関係の順に、1 Issue ずつ `issue flow` を回す。
   **インナーの記録は Vault に送らない。** 内部ジャーナルに貯め、エピック完了時にまとめて送る。
   各 Issue の完了後に必ず:
   - `loop retro` で教訓を `lessons.md` に記録する（飛ばすとこのフロー全体が無意味になる）
   - ジャーナルをコミットする（別端末が続きを拾えるようにする）
   - `epic/<epic-slug>` へマージする
   - `epics/<epic-slug>.md` の進捗を更新する
7. 全 Issue 完了後、`main` 向けの統合 PR を作成し、**ユーザーの最終確認**を得る。
8. **マージ後、外部記憶へ書き写す（★必須）**:
   ```bash
   bash .claude/scripts/loop-journal.sh flush <<'ENTRY'
   - **ゴール**: <エピックのゴール>
   - **結果**: Issue N 本完了
   - **重要な設計判断**: <次のエピックが前提にすべきこと>
   ENTRY
   git add -A .claude/memory/journal && git commit -m "chore: flush inner-loop journal for epic <epic-slug>"
   ```
   内部ジャーナルは Vault へ書き写された後に削除される。
   Vault への着地が確認できない場合 `flush` は失敗しジャーナルを残す。**手で消すな。**

## ハードストップ時

- 後続 Issue に進まない（依存が壊れた状態で積み上げても無駄）
- 教訓を記録し、状況をユーザーに報告して指示を仰ぐ
- ユーザーが「スキップして続行」と判断した場合のみ、依存の無い Issue に限り続行する

## Codex 注意点

- 人間の承認ポイント（手順4と7）を省略しない。全自動化ではなく、介在場所の固定が設計。
- 依存のある Issue を並列で流さない。
- 1エピックの Issue が10本を超える場合は、エピック自体の分割を提案する。
- 途中で要件が変わった場合は、勝手に軌道修正せず再分解し、手順4の承認からやり直す。
- 手順0の記録読み込みと手順8の `flush` を飛ばさない。飛ばすと外部記憶が育たず、セッションを跨いだ瞬間に記憶を失う。
