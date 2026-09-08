アウターループを回す。**大きな要件（エピック）を Issue に分解し、1本ずつインナーループに流し、セッションを跨いで学習させる。**

メイド長（Benz）がオーケストレーターとして実行する。以下の手順を厳守すること。

## 対象

- 引数 $ARGUMENTS にエピックの要件を指定する。未指定の場合はマスターに確認する。

## 前提

- `@.claude/rules/loop-engineering.md` を読んでいること
- **人間の承認ポイントは Phase 2 と Phase 5 の2箇所のみ**。それ以外では人間を待たせない

---

## Phase 0: 記録の読み込み（★最初の行動・必須）

新しいエピックを始める前に、**このプロジェクトで過去に何をやったかを外部記憶から読む**。

```bash
bash .claude/scripts/loop-journal.sh context
```

- 内部ジャーナルが残っていれば、**前のエピックが未完了**という意味だ。新規エピックを始める前に
  そのエピックを閉じる（`flush`）か、マスターに継続の可否を確認する
- 内部ジャーナルが無ければ、Vault の `projects/<project>.md` から直近エピックの記録が出力される

Vault が未接続の端末では先に繋ぐ:

```bash
bash .claude/scripts/loop-journal.sh init <vault-path>   # 省略で自動検出
```

`lessons.md` も併せて読む。**経緯（ジャーナル/Vault）と教訓（lessons）は別の資産。両方読む。**

---

## Phase 1: 分解（立案のメイド）

1. `sub-agent-planner` を起動し、エピックを Issue に分解させる。
   Planner には以下を渡す:
   - マスターから受け取ったエピックの要件（原文のまま。要約しない）
   - `.claude/memory/lessons.md` を読むよう明示的に指示する

2. Planner は `.claude/memory/epics/<epic-slug>.md` に分解結果を出力する。
   各 Issue に以下が**全て**揃っていることを Benz が確認する。1つでも欠けたら Planner に差し戻す:
   - 目的 / 意図 / 受け入れ条件（機械判定可能）/ 依存関係 / 影響範囲 / セキュリティ確認の要否

3. ゴールが一行で言い切れない Issue が混ざっていたら、その時点で差し戻す。
   **曖昧なタスク定義は、下流の全メイドを無駄に燃やす。**

4. **エピックのジャーナルを開き、分解結果を Vault に記録する（アウターの節目）**:
   ```bash
   bash .claude/scripts/loop-journal.sh start <epic-slug> "<エピック名>"
   bash .claude/scripts/loop-journal.sh outer plan "分解完了" <<'ENTRY'
   - **やったこと**: エピックを Issue N 本に分解
   - **なぜ**: <この切り方にした理由。依存の張り方の判断>
   - **参照した教訓**: <lessons.md から反映した項目>
   - **G5 判定**: <セキュリティ確認が必要な Issue と、その理由>
   ENTRY
   ```

---

## Phase 2: 人間の承認（★必須の関門）

分解結果をマスターに提示し、**承認を得るまで先に進まない**。

提示するもの:
- Issue 一覧（一行ゴール + 受け入れ条件の要約）
- 実行順序と依存関係
- 参照した過去の教訓と、それを分解にどう反映したか
- 未確定事項（Planner が判断を保留した項目）

マスターの指示で Issue の追加・削除・分割をした場合は、`epics/<epic-slug>.md` を更新する。

承認が下りたら Vault に記録する（アウターの節目）:

```bash
bash .claude/scripts/loop-journal.sh outer approve "承認" <<'ENTRY'
- **やったこと**: 分解結果が承認された
- **マスターの指示で変えた点**: <追加・削除・分割。無ければ「変更なし」>
ENTRY
```

---

## Phase 3: Issue 化とエピックブランチ

1. エピック統合用のブランチを作る:
   ```bash
   git checkout main && git pull origin main
   git checkout -b epic/<epic-slug>
   git push -u origin epic/<epic-slug>
   ```

2. 承認された各 Issue を GitHub に起票する:
   ```bash
   gh issue create --title "<一行ゴール>" --body "$(cat <<'EOT'
   ## 概要
   <目的>

   ## 意図
   <どういう状態になれば正解か>

   ## 受け入れ条件
   - [ ] 条件1
   - [ ] 条件2

   ## 影響範囲
   <ディレクトリ・型・API・画面>

   ## セキュリティ確認
   必須（理由: ...） / 不要（理由: ...）

   ## 関連
   Epic: <epic-slug> / 依存: #<番号>
   EOT
   )"
   ```

3. 起票した Issue 番号を `epics/<epic-slug>.md` に追記する。

---

## Phase 4: 逐次実行（インナーループの連鎖）

依存関係の順に、**1 Issue ずつ** `/issue-flow` を回す。

```
for Issue in 実行順序:
    1. loop-journal.sh context を読む（前の Issue の経緯が内部ジャーナルに入っている）
    2. .claude/memory/lessons.md を読む（前の Issue の教訓が入っている）
    3. /issue-flow <Issue番号>  ← インナーループ（節目4点を内部ジャーナルへ記録する）
    4. 完了 → /loop-retro で教訓を lessons.md に追記
    5. ジャーナルをコミット（別端末が続きを拾えるようにする）
    6. epic/<epic-slug> ブランチへマージ
    7. 次の Issue へ
```

**インナーループの記録は Vault に送らない。** 内部ジャーナルに貯め続け、エピック完了時にまとめて送る。
セッションが途中で切れても、次の AI は `loop-journal.sh context` で内部ジャーナルから復帰できる。

### 各 Issue 完了後の必須処理

1. **教訓の記録**: `/loop-retro`。これを飛ばすとアウターループが学習しない。**飛ばした時点でこのフローは無意味になる。**
2. **エピックブランチへの統合**:
   ```bash
   gh pr merge <PR番号> --squash --delete-branch
   ```
   （PR のベースブランチは `epic/<epic-slug>`）
3. **進捗の更新**: `epics/<epic-slug>.md` の該当 Issue にチェックを入れる
4. **ジャーナルのコミット**: `git add .claude/memory/journal && git commit -m "chore: ..."`
   これを飛ばすと、別端末・別作業者が続きを引き継げない

### ハードストップが出た場合

該当 Issue で `/issue-flow` がハードストップした場合:

1. **後続 Issue に進まない**（依存関係が壊れた状態で積み上げても無駄）
2. 教訓を記録し、マスターに報告して指示を仰ぐ
3. マスターの判断で「その Issue をスキップして後続を進める」場合のみ、依存の無い Issue に限り続行する

---

## Phase 5: エピック統合（★人間の最終確認）

全 Issue 完了後:

1. エピック全体の統合 PR を作成する:
   ```bash
   gh pr create --base main --head epic/<epic-slug> --title "<エピック名>" --body "..."
   ```
   body には以下を含める:
   - エピックのゴール
   - 含まれる Issue 一覧（`Closes #N` を全件記載）
   - 今回のループで得た教訓の要約

2. CI が全件グリーンであることを確認する
3. `/review-pr` で最終レビューを実行する

4. 統合 PR の作成を Vault に記録する（アウターの節目）:
   ```bash
   bash .claude/scripts/loop-journal.sh outer integrate "統合 PR" <<'ENTRY'
   - **やったこと**: epic/<epic-slug> → main の統合 PR を作成
   - **含む Issue**: #N, #N, ...
   ENTRY
   ```

5. **マスターに最終確認を求める**。マージ判断は人間が行う

6. **マージ後、外部記憶へ書き写す（★エピック完了の必須処理）**:
   ```bash
   bash .claude/scripts/loop-journal.sh flush <<'ENTRY'
   - **ゴール**: <エピックのゴール>
   - **結果**: Issue N 本完了 / スキップ N 本
   - **重要な設計判断**: <このエピックで決めたこと。次のエピックが前提にすべきこと>
   - **学習**: <蓄積した教訓の要約。効かなかった場合はその事実>
   ENTRY
   ```
   内部ジャーナルの全記録が Vault の `projects/<project>.md` へ書き写され、
   **プロジェクト内部のジャーナルは削除される**。削除をコミットする:
   ```bash
   git add -A .claude/memory/journal && git commit -m "chore: flush inner-loop journal for epic <epic-slug>"
   ```
   Vault への着地が確認できない場合、`flush` は失敗してジャーナルを残す。**記録は落とさない。**
   その場合は Vault の接続を直してからやり直す。**手でジャーナルを消すな。**

---

## 完了報告フォーマット

```
## アウターループ完了: <エピック名>

### 結果: 完了 / 中断（理由）

### Issue 消化
| # | Issue | 結果 | リトライ | 所要 |
|---|-------|------|---------|------|
| 1 | #42 記事検索の実装 | ✅ | 1回 | 22分 |
| 2 | #43 検索結果のページング | ✅ | 0回 | 14分 |

### 学習の効果
- Issue #42 で記録した教訓「<次回ルール>」により、#43 では同種の失敗が発生しなかった
（学習が効かなかった場合はその事実を書く。取り繕わない）

### 蓄積された教訓
- <lessons.md に追加された項目一覧>

### 統合 PR
- <URL>

### 残課題
- <未着手・スキップした Issue とその理由>
```

## 注意

- **Phase 0 の記録読み込みを飛ばさない。** 別端末で回した続きかもしれない。最初の行動は `loop-journal.sh context`。
- **Phase 2 の承認を飛ばさない。** 人間が介在する場所を固定するのがループ設計であり、全自動化ではない。
- **Phase 5 の `flush` を飛ばさない。** 飛ばすとインナーの経緯がリポジトリに溜まり続け、
  Vault には何も残らない。外部記憶が育たないループは、セッションを跨いだ瞬間に記憶を失う。
- **各 Issue 完了時の `/loop-retro` を飛ばさない。** メモリの無いアウターループは、ただの順次実行であってループではない。
- 依存のある Issue を並列で流さない。ワークツリーで分離しても、依存関係の破綻は防げない。
- 1エピックの Issue が10本を超える場合は、エピック自体の分割をマスターに提案する。
- 途中で要件が変わった場合は、勝手に軌道修正せず Planner に再分解させ、Phase 2 の承認からやり直す。
