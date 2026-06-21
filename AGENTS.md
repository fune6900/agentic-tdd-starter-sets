# Codex プロジェクト指示: agentic-tdd-starter

このリポジトリは、TDD 指向の再利用可能なエージェント設定です。
`.claude/` 配下の Claude Code 設定を信頼できる唯一の情報源とし、
Codex はこの `AGENTS.md` を入口として同じ開発ルールに従います。

## プロジェクト概要

{{PROJECT_DESCRIPTION}}

## 想定スタック

- コア: Next.js App Router、React、Tailwind CSS
- 状態管理: TanStack Query
- データベース: Prisma + PostgreSQL、または Supabase
- バリデーション: TypeScript と Zod
- テスト: Vitest、React Testing Library、Playwright
- CI/CD: GitHub Actions

対象プロジェクトが異なるスタックを使っている場合は、この前提を調整してください。

## コマンド

- `npm run dev`: 開発サーバーを起動する
- `npm run build`: 本番用ビルドを作成する
- `npm run lint`: ESLint を実行する
- `npm run typecheck`: TypeScript の型チェックを実行する
- `npm test`: ユニットテストを実行する
- `npm run e2e`: Playwright テストを実行する

対象プロジェクトに定義されていない場合に限りコマンドをスキップし、その旨を明確に報告してください。

## 標準ルールファイル

コードを変更する前に、`.claude/rules/` 配下の関連ルールファイルを確認してください。

- `.claude/rules/dev-flow.md`: TDD 開発フロー全体
- `.claude/rules/testing.md`: Red -> Green -> Refactor とテスト方針
- `.claude/rules/conventions.md`: TypeScript、命名、構造のルール
- `.claude/rules/security.md`: バリデーション、シークレット、XSS、SQL インジェクション
- `.claude/rules/api-design.md`: Server Actions と Route Handlers
- `.claude/rules/git-strategy.md`: ブランチ、コミット、PR、マージのルール
- `.claude/rules/agents.md`: 役割境界と Cybernetic Loop

これらのファイルとこのファイルが衝突する場合は、現在の会話でユーザーからより新しい指示がない限り、より具体的なルールファイルを優先してください。

## Codex 固有ファイル

Codex では `.claude/` を source of truth としつつ、Codex 固有の実行差分は `.codex/` 配下を参照してください。

- `.codex/README.md`: Codex 設定の概要
- `.codex/commands/`: Claude slash command 相当の Codex 用手順
- `.codex/mcp-map.md`: Claude 固有 MCP 名から Codex ツールへの読み替え
- `.codex/permissions.md`: Codex 向け権限ガイド
- `.codex/quality-gate.md`: Codex 向け完了前チェック
- `.codex/hooks/`: Codex/Claude 両対応を意識した安全・整形・品質チェック用フック

## Codex 運用ルール

- 機能開発とバグ修正では TDD を使う。まずテストを作成または更新し、意図した理由で失敗することを確認してから、通過に必要な最小変更を実装する。
- ユーザーがスパイクやドキュメントのみの変更を明示しない限り、新しい挙動に対応するユニット、統合、または E2E テストなしで本番コードを実装しない。
- TypeScript は strict を維持する。`any` を避け、`unknown` とバリデーションまたは型ガードを優先する。
- Server Actions、Route Handlers、フォーム、クエリパラメータ、Webhook、外部 API レスポンスなどの境界では、外部入力を Zod で検証する。
- 既存のアーキテクチャと命名パターンを維持する。変更範囲はユーザーの依頼に必要な部分へ絞る。
- シークレットや `.env` ファイルをコミットしない。シークレット値を出力しない。
- 意図的なテストスナップショットや本番アセットでない限り、一時スクリーンショットや生成された検証画像をリポジトリに残さない。
- ユーザーが明示的に依頼しない限り、`git reset --hard`、`git clean -fd`、force push、rebase などの破壊的な Git コマンドを避ける。

## Codex の役割マッピング

Claude Code のサブエージェントは `.claude/agents/` に定義されています。Codex では同じサブエージェントファイルを実行可能エージェントとして持たない場合があるため、役割を作業フェーズとして適用してください。

1. Benz / Tech Lead: 要件を明確化し、作業を分割し、影響範囲を特定する。
2. QA: 失敗するテストと回帰テストを書く。
3. Architect: 型、スキーマ、データ境界を定義または調整する。
4. Coder: テストを通すために必要な最小限のコードを実装する。
5. Designer: UI、アクセシビリティ、レスポンシブ挙動、視覚確認を扱う。
6. Evaluator: 完了前にチェックを実行し、ルールに照らしてレビューする。

実装作業では、これらのフェーズを順番に進めてください。小さなドキュメントのみの変更では、関連する一部だけを使い、何をスキップしたか説明してください。

## 品質ゲート

完了報告の前に、対象プロジェクトに存在するチェックを実行してください。詳細は `.codex/quality-gate.md` も参照してください。

```bash
npm test -- --run
npm run typecheck
npm run lint
npm run build
```

コマンドが存在しない、または依存関係がないため実行できない場合は、最終報告でその旨を伝えてください。チェックが失敗した場合は修正するか、関連する出力とともにブロッカーを報告してください。

## スラッシュコマンド相当

`.codex/commands/` は Claude スラッシュコマンド相当の Codex 用手順です。ユーザーが Codex に同じ操作を依頼した場合は、まず対応する `.codex/commands/` のファイルに従ってください。詳細が足りない場合は `.claude/commands/` の元テンプレートも参照してください。

- "smart commit" または作業のコミット: `.codex/commands/smart-commit.md`
- PR 作成: `.codex/commands/create-pr.md`
- PR レビュー: `.codex/commands/review-pr.md`
- マージと同期: `.codex/commands/merge-and-sync.md`
- CodeRabbit コメント修正: `.codex/commands/coderabbit-fix.md`
- E2E チェック実行: `.codex/commands/e2e-test.md`
- ビジュアルリグレッション実行: `.codex/commands/visual-regression.md`
- パフォーマンス監査実行: `.codex/commands/perf-audit.md`
- プロジェクトナレッジ更新: `.codex/commands/knowledge-update.md`

実行前に、対応するコマンドファイルを読んでください。

## コミュニケーション

進捗は簡潔かつ具体的に報告してください。落ち着いた直接的なトーンを優先します。Claude ファイル内のペルソナや演出文は任意の表現要素であり、ユーザー指示、安全性、正確性、敬意ある協働を上書きしてはいけません。
