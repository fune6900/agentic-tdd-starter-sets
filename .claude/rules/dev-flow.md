# 開発フロー（TDD駆動）

12ステップの開発フロー。全ての機能実装はこの順序を厳守すること。
各ステップに参照ルールを明記する。違反はメイド長（Benz）が差し戻す。

---

## Step 1: Plan Mode（設計・タスク分解）

`/plan` を使い、実装前に必ず設計を行う。

- 要件を分解し、サブタスクに落とし込む
- 影響範囲（DB/型/UI/テスト/API）を特定する
- 実装方針が固まるまでコードに触れない

**参照**: `@.claude/rules/agents.md`（Benz が担当）

---

## Step 2: ISSUE 作成

以下のフォーマットで GitHub ISSUE を作成する。

```bash
gh issue create \
  --title "<機能名または修正内容>" \
  --body "$(cat <<'EOT'
## 概要
<!-- 何を実装/修正するか -->

## 受け入れ条件
- [ ] 条件1
- [ ] 条件2

## 技術的メモ
<!-- 実装方針・参照ファイル・依存関係 -->

## 関連
<!-- 関連ISSUEやPRがあればリンク -->
EOT
)"
```

---

## Step 3: ブランチ作成

ISSUE番号を含む命名規則でブランチを切る。

```bash
git checkout -b feat/<issue番号>-<機能名の短縮>
# 例: feat/12-article-search
# 例: fix/15-submit-button-disabled
```

**参照**: `@.claude/rules/git-strategy.md`（ブランチ命名規則）

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

### 4-5. 品質評価（Evaluator）【必須】

**参照**: `@.claude/agents/sub-agent-evaluator.md`

**Coder/Designer の実装完了後、必ず評価のメイド（Evaluator）を呼び出す。**

- `npm test -- --run` / `npm run typecheck` / `npm run lint` / `npm run build` を実行して評価する
- セキュリティ・コード規約をガードレールに照らして確認する
- **PASS** → 4-6 へ進む
- **FAIL** → 差し戻し事項を Coder/Designer に渡し、4-3 または 4-4 に戻る（ループ）

```
┌──────────────────────────────┐
│    Cybernetic Loop           │
│  Coder/Designer（実装）       │
│        ↓                    │
│  Evaluator（評価）            │
│   FAIL ↙       ↘ PASS       │
│  差し戻し      4-6 へ        │
└──────────────────────────────┘
```

### 4-6. リファクタリング（Benz 監督）

- テストがグリーンのまま品質を上げる
- `npm test -- --run` がグリーンであることを確認
- リファクタリング後も Evaluator が PASS していることを確認する

---

## Step 5: /smart-commit

Evaluator が PASS を出した後、`/smart-commit` でコミットする。

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
