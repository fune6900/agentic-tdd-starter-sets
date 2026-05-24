CodeRabbitのレビューコメントを取得し、指摘内容を分析・修正案を提示し、実際にコードを修正する。以下の手順を厳守すること。

## 対象
- 引数 $ARGUMENTS にPR番号が指定される。未指定の場合は `gh pr list` で一覧を表示し確認する。

## 手順

### Phase 1: CodeRabbit コメントの収集

1. PR のコメントを全件取得する:
   ```bash
   gh api repos/{owner}/{repo}/pulls/<PR番号>/reviews --jq '.[] | select(.user.login == "coderabbitai") | {id, state, body, submitted_at}'
   ```

2. インラインコメント（行単位の指摘）も取得する:
   ```bash
   gh api repos/{owner}/{repo}/pulls/<PR番号>/comments --jq '.[] | select(.user.login == "coderabbitai") | {path, line, body}'
   ```

3. PR 全体コメントも取得する:
   ```bash
   gh api repos/{owner}/{repo}/issues/<PR番号>/comments --jq '.[] | select(.user.login == "coderabbitai") | {id, body, created_at}'
   ```

4. owner と repo は以下で取得する:
   ```bash
   gh repo view --json owner,name --jq '"repos/\(.owner.login)/\(.name)"'
   ```

### Phase 2: 指摘の分類と優先度付け

取得したコメントを以下の基準で分類する:

| 優先度 | 基準 |
|--------|------|
| 🔴 必須対応 | バグ・セキュリティ・型エラー・ルール違反 |
| 🟡 推奨対応 | 可読性・パフォーマンス・ベストプラクティス |
| 🟢 任意対応 | スタイル・命名・軽微な改善提案 |

マスターに分類結果を報告し、対応する優先度の確認を取る（デフォルト: 🔴 必須 + 🟡 推奨）。

### Phase 3: 修正案の提示

各指摘に対して:
1. 対象ファイルを Read ツールで読み込む
2. 問題箇所を特定する
3. 修正方針を日本語で説明する
4. 修正後のコードを提示する

以下の形式でまとめて報告する:
```
### 指摘 #N
- **ファイル**: path/to/file.ts:行番号
- **CodeRabbit の指摘**: （原文要約）
- **修正方針**: （何をどう直すか）
- **修正内容**: （コードスニペット）
```

全指摘の修正案を提示した後、マスターに「このまま修正を適用しますか？」と確認する。

### Phase 4: 修正の適用

マスターの承認後:
1. 各ファイルを Edit ツールで修正する
2. 修正後に `npm run lint` を実行する
3. `npm run typecheck` を実行する
4. テストが存在する場合は `npm test -- --run` を実行する
5. いずれかが失敗した場合は修正を中断し、マスターに報告する

### Phase 5: コミットとレポート

1. `/smart-commit` の手順に従いコミットする（コミットメッセージ例: `fix: address CodeRabbit review on PR #<番号>`）
2. `git push` する
3. 以下の形式で完了報告する:

```
## CodeRabbit 修正完了: PR #<番号>

### 対応した指摘
- ✅ （対応済み指摘一覧）

### スキップした指摘
- ⏭️ （スキップ理由付き）

### 品質チェック
- lint: ✅ / ❌
- typecheck: ✅ / ❌
- test: ✅ / ❌ / ⏭️（テストなし）
```

## 注意
- CodeRabbit のコメントが存在しない場合はその旨を報告して終了する
- 修正が大規模になる場合（5ファイル以上）はマスターに分割対応を提案する
- セキュリティ指摘は必ず対応する。スキップ不可
- `any` の指摘は conventions.md の規約違反のため必須対応
