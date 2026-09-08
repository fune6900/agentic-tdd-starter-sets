インナーループを1本回す。**1つの Issue を、人間を介さず「実装 → 検証 → 差し戻し」で合格まで持っていく。**

メイド長（Benz）がオーケストレーターとして実行する。以下の手順を厳守すること。

## 対象

- 引数 $ARGUMENTS に Issue 番号を指定する。未指定の場合は `gh issue list` を表示してマスターに確認する。

## 前提

- `@.claude/rules/loop-engineering.md` を読んでいること（ゲート定義・ハードストップ）
- Issue に **目的・意図・受け入れ条件・影響範囲・セキュリティ確認の要否** が書かれていること
  - 欠けている場合は実装に入らず、立案のメイド（`sub-agent-planner`）に差し戻す

---

## Phase 0: 準備

1. **前回までの記録を読む（★最初の行動・必須）**:
   ```bash
   bash .claude/scripts/loop-journal.sh context
   ```
   進行中のエピックがあれば内部ジャーナル、無ければ外部 Vault の直近エピックが出力される。
   **前のセッション・別の端末の AI が何をやって、なぜそうしたかを把握してから着手する。**
   読まずに始めるのは、他人の作業を上書きしに行く行為だ。

2. Issue の内容を取得する:
   ```bash
   gh issue view <番号>
   ```

3. **教訓を読む（必須）**: `.claude/memory/lessons.md` を Read し、この Issue に関係する教訓を抽出する。
   抽出した教訓は、後続の各サブエージェントへの指示に**必ず添えて渡す**。読むだけでは意味がない。
   ジャーナル（経緯）と lessons（教訓）は別物。両方読む。

4. **安全な作業環境を作る**:
   ```bash
   bash .claude/scripts/worktree.sh create feat/<番号>-<短縮名>
   ```
   単独作業で分離が不要な場合は通常のブランチ作成でもよい:
   ```bash
   git checkout -b feat/<番号>-<短縮名>
   ```

5. **ループ状態を初期化する（必須）**:
   ```bash
   bash .claude/scripts/loop-state.sh init <番号> feat/<番号>-<短縮名> <epic-slug>
   ```
   これを飛ばすとハードストップが機能しない。飛ばすな。
   第3引数の `<epic-slug>` はジャーナルの宛先。単独 Issue（エピック外）なら省略してよい。

6. **エピック外の単独 Issue の場合**は、ジャーナルを自分で開く:
   ```bash
   bash .claude/scripts/loop-journal.sh start <epic-slug または issue-<番号>>
   ```
   `/epic-flow` から来た場合は既に開かれているので不要。

7. **着手を記録する（節目1/4）**:
   ```bash
   bash .claude/scripts/loop-journal.sh inner <番号> start "<Issue の一行ゴール>" <<'ENTRY'
   - **やったこと**: #<番号> に着手
   - **なぜ**: <この Issue を今やる理由・依存関係>
   - **方針**: <実装方針と、その方針を選んだ理由>
   - **参照した教訓**: <lessons.md から拾った項目。無ければ「なし」>
   ENTRY
   ```

---

## Phase 1: 実装（Generator）

`@.claude/rules/agents.md` の責務境界に従い、順に起動する。各エージェントには
**Issue の受け入れ条件と Phase 0 で抽出した教訓を必ず添えて**渡すこと。

1. `sub-agent-qa` — 失敗するテストを書く（Red）。`npm test -- --run` で**失敗を確認**してから次へ
2. `sub-agent-architect` — 型・Zod スキーマ・DB スキーマを定義する（必要な場合）
3. `sub-agent-coder` — テストを通す最小限の実装を書く（Green）
4. `sub-agent-designer` — UI コンポーネント・Tailwind スタイリング（UI 変更がある場合のみ）

5. **実装完了を記録する（節目2/4）**:
   ```bash
   bash .claude/scripts/loop-journal.sh inner <番号> impl <<'ENTRY'
   - **やったこと**: <追加・変更したファイルと責務>
   - **なぜ**: <なぜその設計にしたか。型の置き場所・境界の切り方の判断理由>
   - **捨てた選択肢**: <検討して却下した案と、却下した理由>
   - **次**: G1 へ
   ENTRY
   ```
   **「なぜ」を省略するな。** 次のセッションが同じ設計判断をやり直さないための記録だ。

---

## Phase 2: ゲート通過（Validator）

**順番を守る。** 前のゲートが FAIL なら後続は起動しない。壊れたコードをレビューさせるのは浪費。

各ゲートの結果は担当エージェントが `loop-state.sh gate` で記録する。
記録が無い場合は Benz が代わりに記録すること。

| 順 | ゲート | 起動するエージェント | 起動条件 |
| --- | --- | --- | --- |
| 1 | **G1 機械** | `sub-agent-evaluator` | 常時 |
| 2 | **G2 実証** | `sub-agent-tester` | 常時 |
| 3 | **G3 仕様** | `sub-agent-spec-reviewer` | 常時 |
| 4 | **G4 コード** | `sub-agent-code-reviewer` | 常時 |
| 5 | **G5 セキュリティ** | `sub-agent-security-reviewer` | Issue に「セキュリティ確認: 必須」がある場合のみ |

```bash
# 各ゲートの後に必ず実行される想定
bash .claude/scripts/loop-state.sh gate G1 pass
bash .claude/scripts/loop-state.sh gate G2 fail "受け入れ条件 #2 が実画面で未達"
```

**ゲートを一巡したら記録する（節目3/4）**。ゲート1つごとには書かない。一巡で1エントリ。

```bash
bash .claude/scripts/loop-journal.sh inner <番号> gates <<'ENTRY'
- **結果**: G1 ✅ / G2 ❌ / G3〜G5 未実行
- **落ちた内容**: <どのゲートで何が落ちたか。原文の要点>
- **差し戻し先**: <どのエージェントへ戻すか>
- **なぜそう判断したか**: <差し戻し先を選んだ理由>
ENTRY
```

---

## Phase 3: 差し戻しループ（Reflection）

**いずれかのゲートが FAIL の場合:**

1. 差し戻し事項を整理し、**差し戻し先を特定する**:
   - 実装の誤り → `sub-agent-coder`
   - UI の崩れ → `sub-agent-designer`
   - テスト設計の漏れ → `sub-agent-qa`
   - 型設計の誤り → `sub-agent-architect`
   - **受け入れ条件そのものの不足** → `sub-agent-planner`（Issue の再定義が必要）

2. リトライを記録する:
   ```bash
   bash .claude/scripts/loop-state.sh retry "<今回何を変えるか>"
   ```

3. **`check` が exit 1 を返したら即座に停止する**（ハードストップ）。Phase 5 へ。

4. 停止していなければ Phase 1 の該当エージェントへ戻り、**Phase 2 を最初のゲートからやり直す**。
   途中のゲートから再開しない。修正が別の場所を壊している可能性があるため。

**同じ修正を繰り返さない。** 前回のリトライで何を変えたかを `loop-state.sh show` の history で確認し、
同じアプローチを再試行しようとしている場合は、その時点で人間に報告する。

---

## Phase 4: 完了（全ゲート PASS）

1. 検証用スクリーンショットの後始末を確認する:
   ```bash
   git status --short
   ls -1 *.png *.jpeg 2>/dev/null
   ```
2. `/smart-commit` でコミットする
3. `/create-pr` で PR を作成する（body に `Closes #<番号>` を必ず記載）
4. ループを完了させる:
   ```bash
   bash .claude/scripts/loop-state.sh complete
   ```
5. **完了を記録する（節目4/4）**:
   ```bash
   bash .claude/scripts/loop-journal.sh inner <番号> done <<'ENTRY'
   - **やったこと**: PR #<番号> を作成。全ゲート PASS
   - **なぜ**: <最終的に効いた修正と、その理由>
   - **残課題**: <このIssueで拾わなかったもの。無ければ「なし」>
   - **次**: <次の Issue への申し送り>
   ENTRY
   ```
   ジャーナルはコミットする（別端末への引き継ぎ資産）:
   ```bash
   git add .claude/memory/journal && git commit -m "chore: record inner-loop journal for #<番号>"
   ```
6. **`/loop-retro` を実行して教訓を記録する（必須）**。差し戻しが1回でも発生した場合は特に必須。
   ジャーナル（経緯）と lessons.md（教訓）は別物。**両方書く。**
7. 完了報告を出す（下記フォーマット）

---

## Phase 5: ハードストップ時

**コミットも PR 作成もしない。** 中途半端な成果物を main に近づけない。

1. **停止を記録する（節目4/4）**:
   ```bash
   bash .claude/scripts/loop-journal.sh inner <番号> halt <<'ENTRY'
   - **やったこと**: retry <N>回 / <ゲート名> で停止
   - **各リトライで変えたこと**: <history をそのまま>
   - **推定原因**: <確認できた事実と、未確定の区別を明記>
   - **次**: マスターの判断待ち
   ENTRY
   git add .claude/memory/journal && git commit -m "chore: record hard stop for #<番号>"
   ```
   **停止した事実こそ引き継ぐ価値がある。** 次の端末の AI が同じ壁に頭から突っ込むのを防ぐ。
2. `/loop-retro` で「解決できなかった事実」を `lessons.md` に記録する
3. 以下をマスターに報告して**指示を仰ぐ**:
   - 何回目のリトライで、どのゲートで、何が落ちたか
   - 各リトライで何を変えたか（history をそのまま提示する）
   - 現時点の推定原因と、判断を仰ぎたい選択肢（最低2案）
4. マスターの指示があるまでループを再開しない。勝手に別アプローチを試さない。

---

## 完了報告フォーマット

```
## インナーループ完了: Issue #<番号>

### 結果: 全ゲート PASS / ハードストップ

### ループ統計
- リトライ回数: X / 上限 Y
- 所要時間: X分
- 起動したエージェント: QA, Architect, Coder, Evaluator, Tester, Spec, Code, (Security)

### ゲート結果
| ゲート | 担当 | 結果 | 備考 |
|--------|------|------|------|
| G1 機械 | Evaluator | ✅ | |
| G2 実証 | 実証のメイド | ✅ | 初回 FAIL → 1回で回復 |
| G3 仕様 | 照合のメイド | ✅ | |
| G4 コード | 校閲のメイド | ✅ | |
| G5 セキュリティ | 守衛のメイド | ✅ / ⏭️ 起動条件外 | |

### 差し戻しの経緯
1. <何回目・どのゲート・何が落ちて・何を直したか>

### 成果物
- PR: <URL>
- 記録した教訓: <lessons.md の項目名>
```

## 注意

- **インナーループの途中で人間に確認を取らない。** ゲートを信じるか、ゲートを直すか。不安で覗くのは設計ではない。
- ゲートを通すためにテストを削除・`.skip` 化・`--no-verify` を使うのは**禁止**。発覚時点でハードストップ扱い。
- `loop-state.sh init` を忘れるとハードストップが働かず、無限リトライでコストが死ぬ。必ず実行する。
- 教訓を読まずに実装を始めるのは、過去の失敗を買い直す行為。Phase 0 を飛ばすな。
- **記録を読まずに着手するな。** 別端末・別セッションの続きかもしれない。最初の行動は `loop-journal.sh context`。
- ジャーナルは**経緯**、`lessons.md` は**教訓**。ジャーナルはエピック完了時に Vault へ移って消えるので、
  次回ルールをジャーナルに書くと消える。書き分けろ。
