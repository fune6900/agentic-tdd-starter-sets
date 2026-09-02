# 開発フロー（TDD駆動）

12ステップの開発フロー。全ての機能実装はこの順序を厳守すること。
各ステップに参照ルールを明記する。違反はメイド長（Benz）が差し戻す。

> **このファイルは「1 Issue をどう作るか」を規定する（インナーループの中身）。**
> 「どう回してどこで止めるか」は `@.claude/rules/loop-engineering.md` を参照。
> `/issue-flow` はこのフローを、ゲートとハードストップ付きで自動実行するコマンド。
> エピック（複数 Issue）を扱う場合は Step 1 の前に `/epic-flow` を回す。

---

## Step 1: Plan Mode（設計・タスク分解）

`/plan` を使い、実装前に必ず設計を行う。

- **`.claude/memory/lessons.md` を読む（必須）**。過去の失敗を買い直さない
- 要件を分解し、サブタスクに落とし込む
- 影響範囲（DB/型/UI/テスト/API）を特定する
- 実装方針が固まるまでコードに触れない

エピック規模（Issue 2本以上）の場合は `/epic-flow` を使い、立案のメイド（`sub-agent-planner`）に分解させる。

**参照**: `@.claude/rules/agents.md`・`@.claude/rules/loop-engineering.md`（Benz / Planner が担当）

---

## Step 2: ISSUE 作成

以下のフォーマットで GitHub ISSUE を作成する。

ループを回すには、以下の項目が**全て**埋まっている必要がある。1つでも欠けたら AI は迷う。

```bash
gh issue create \
  --title "<一行で言い切れるゴール>" \
  --body "$(cat <<'EOT'
## 概要
<!-- 目的: なぜこれをやるか（ビジネス/ユーザー価値） -->

## 意図
<!-- どういう状態になれば正解か -->

## 受け入れ条件
<!-- 機械的に判定可能な粒度で書く。テストで表現できない条件は書き直す -->
- [ ] 条件1
- [ ] 条件2

## 影響範囲
<!-- 変更が波及するディレクトリ・型・API・画面 -->

## セキュリティ確認
<!-- 必須（理由）/ 不要（理由）。判定基準は loop-engineering.md の G5 起動条件 -->

## 技術的メモ
<!-- 実装方針・参照ファイル・依存関係・関連する過去の教訓 -->

## 関連
<!-- 依存する ISSUE / Epic -->
EOT
)"
```

> **ゴールが一行で言い切れないなら、分解が足りていない。** 割り直せ。

---

## Step 3: ブランチ作成

ISSUE番号を含む命名規則でブランチを切る。

```bash
git checkout -b feat/<issue番号>-<機能名の短縮>
# 例: feat/12-article-search
# 例: fix/15-submit-button-disabled
```

複数エージェントで並列作業する場合、または失敗の影響を隔離したい場合はワークツリーを使う:

```bash
bash .claude/scripts/worktree.sh create feat/<issue番号>-<機能名の短縮>
```

ブランチを切ったら**ループ状態を初期化する（ハードストップの前提）**:

```bash
bash .claude/scripts/loop-state.sh init <issue番号> feat/<issue番号>-<機能名の短縮>
```

**参照**: `@.claude/rules/git-strategy.md`（ブランチ命名規則）・`@.claude/commands/worktree.md`

---

## Step 4: TDD Cycle（Red → Green → Refactor）

### 4-1. テスト設計（QA）

**参照**: `@.claude/rules/testing.md`・`@.claude/rules/agents.md`

- 検閲のメイド（QA）がテストを書く
- `npm test -- --run` でテストが**失敗する**ことを確認してから次へ

### 4-2. 型・スキーマ定義（Architect）

**参照**: `@.claude/rules/conventions.md`・`@.claude/rules/api-design.md`

- 礎のメイド（Architect）が `types/` と Zod スキーマを定義する
- DB変更が必要な場合は `prisma/schema.prisma` を更新する

### 4-3. 実装（Coder）

**参照**: `@.claude/rules/conventions.md`・`@.claude/rules/security.md`・`@.claude/rules/api-design.md`

- 構築のメイド（Coder）がテストをグリーンにする最小限のコードを書く
- `any` 使用禁止。入力バリデーション必須

### 4-4. UIコンポーネント（Designer、必要な場合）

**参照**: `@.claude/rules/agents.md`

- 図案のメイド（Designer）が Tailwind CSS でスタイリングする

### 4-5. ゲート通過【必須】

**参照**: `@.claude/rules/loop-engineering.md`（ゲート定義・ハードストップ）

Coder/Designer の実装完了後、**5つのゲートを順に通す**。
前のゲートが FAIL なら後続は起動しない。壊れたコードをレビューさせるのはトークンの浪費。

| 順 | ゲート | 担当エージェント | 判定内容 | 起動条件 |
| --- | --- | --- | --- | --- |
| 1 | **G1 機械** | `sub-agent-evaluator` | `npm test -- --run` / `typecheck` / `lint` / `build` | 常時 |
| 2 | **G2 実証** | `sub-agent-tester` | 受け入れ条件を実画面（Playwright）で満たすか | 常時 |
| 3 | **G3 仕様** | `sub-agent-spec-reviewer` | 目的・意図の充足、影響範囲の逸脱 | 常時 |
| 4 | **G4 コード** | `sub-agent-code-reviewer` | 可読性・重複・命名・規約 | 常時 |
| 5 | **G5 セキュリティ** | `sub-agent-security-reviewer` | `security.md` の全項目 | Issue に「必須」と記載がある場合のみ |

各ゲートの結果は必ず記録する:

```bash
bash .claude/scripts/loop-state.sh gate G1 pass
bash .claude/scripts/loop-state.sh gate G2 fail "受け入れ条件 #2 が実画面で未達"
```

- **全 PASS** → 4-6 へ進む
- **1つでも FAIL** → 差し戻し先を特定して 4-3 / 4-4 に戻る。`loop-state.sh retry "<何を変えるか>"` を記録し、**ゲートは G1 からやり直す**
- **ハードストップ到達** → コミットも PR 作成もせず、`/loop-retro` で記録してマスターに報告する

```
┌──────────────────────────────────────┐
│         インナーループ                │
│  Coder/Designer（実装）               │
│        ↓                             │
│  G1 → G2 → G3 → G4 → G5              │
│   FAIL ↙              ↘ 全PASS       │
│  差し戻し(retry++)      4-6 へ        │
│   ↓ retry上限                        │
│  ハードストップ → 人間へ報告           │
└──────────────────────────────────────┘
```

**差し戻し先の判断:**

| FAIL の内容 | 差し戻し先 |
| --- | --- |
| 実装の誤り | `sub-agent-coder` |
| UI の崩れ | `sub-agent-designer` |
| テスト設計の漏れ | `sub-agent-qa` |
| 型設計の誤り | `sub-agent-architect` |
| **受け入れ条件そのものの不足** | `sub-agent-planner`（Issue の再定義） |

### 4-6. リファクタリング（Benz 監督）

- テストがグリーンのまま品質を上げる
- `npm test -- --run` がグリーンであることを確認
- リファクタリング後も**全ゲートが PASS のまま**であることを確認する（G1 は必ず再実行）

### 4-7. Reflection【必須】

**参照**: `@.claude/commands/loop-retro.md`

差し戻しが1回でも発生した場合、`/loop-retro` を実行して `.claude/memory/lessons.md` に教訓を記録する。

**これを飛ばすと、次の Issue で同じ失敗を繰り返す。** アウターループの学習は全てここに依存している。

```bash
bash .claude/scripts/loop-state.sh complete   # ループの正常終了を記録
```

---

## Step 5: /smart-commit

全ゲート（G1〜G5）が PASS した後、`/smart-commit` でコミットする。
ハードストップが発動している場合はコミットしない（`loop-guard.sh` がブロックする）。

- lint・typecheck・test を全て通過したもののみコミット可
- コミットメッセージは変更の「理由」（why）を書く

**参照**: `@.claude/rules/git-strategy.md`（コミット規約）

---

## Step 6: PR 作成

`/create-pr` でPRを作成する。

- タイトルは英語・70文字以内
- body は `.github/pull_request_template.md` に従う
- `Closes #<issue番号>` を必ず記載する

**参照**: `@.claude/rules/git-strategy.md`（PRルール）

---

## Step 7: ローカル動作確認

PR作成前後に必ずローカルで確認する。

```bash
npm run lint       # ESLint（conventions.md 準拠チェック）
npm run typecheck  # TypeScript（any禁止等）
npm run build      # ビルド成功確認
npm test -- --run  # ユニットテスト全件グリーン確認
```

UI変更がある場合は `/visual-regression` を実行する。
フロー全体に変更がある場合は `/e2e-test` を実行する。

### 7-1. スクショの後始末【必須】

検証目的で撮影したスクリーンショットは**作業完了直前に必ず削除する**。

- Playwright MCP / Chrome DevTools MCP / 手動撮影で生成された PNG・JPEG はリポジトリに残さない
- 削除対象の例:
  - リポジトリ直下の `*.png` / `*.jpeg`（`pc-*.png`、`sp-*.png`、`*-screenshot.png` 等）
  - 一時的な検証用画像（仕様参照画像 `image.png` も含む）
- `public/` 配下の本番アセットや `tests/**/__snapshots__/` の Vitest スナップショットは削除しない
- 撮影 → 確認 → 削除 までを1セットで完了させる。「あとで消す」は禁止

```bash
# 例: ルート直下の検証スクショを一掃
ls -1 *.png *.jpeg 2>/dev/null
rm *.png *.jpeg 2>/dev/null
```

`/smart-commit` 実行前に `git status` で残骸が無いことを確認する。

**参照**: `@.claude/rules/testing.md`

---

## Step 8: CI 確認（GitHub Actions）

push後、GitHub Actions の全ジョブがグリーンになることを確認する。

| ジョブ     | 確認内容         | 対応ルール       |
| ---------- | ---------------- | ---------------- |
| Lint       | ESLintエラーなし | `conventions.md` |
| Type Check | 型エラーなし     | `conventions.md` |
| Build      | ビルド成功       | —                |

**CI が red の場合はマージしない。** 原因を特定して修正する。

---

## Step 9: AI コードレビュー

`/review-pr` でAIによるコードレビューを実施する。
インナーループ内で G3/G4/G5 を通していれば、ここは PR 全体を俯瞰した最終確認になる。

レビュー時に照合するルール:

- `@.claude/rules/conventions.md` — コード品質
- `@.claude/rules/security.md` — セキュリティチェックリスト
- `@.claude/rules/testing.md` — テスト網羅性
- `@.claude/rules/api-design.md` — APIエンドポイントの規約
- `@.claude/rules/git-strategy.md` — コミット・PR規約

重要度「高」の指摘がある場合はマージしない。Step 4 に戻る。

---

## Step 10: LGTM

レビュー指摘が全て解消されたら LGTM。

- チェックリストが全て完了していることを確認する
- CI が全件グリーンであることを再確認する

---

## Step 11: マージ

```bash
gh pr merge <PR番号> --squash --delete-branch
```

- `--squash` でコミットを1つに圧縮
- `--delete-branch` でブランチを削除
- マージ後、ISSUE が自動クローズされることを確認

**参照**: `@.claude/rules/git-strategy.md`（マージ戦略）

---

## Step 12: リリース

main ブランチへのマージ = リリース。

現状は手動デプロイ。Vercel/Supabase の自動デプロイが設定されれば自動化される。
マージ後に本番環境での動作を確認すること。
