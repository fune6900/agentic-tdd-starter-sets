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
- `.claude/rules/loop-engineering.md`: ループ設計（インナー/アウター、5＋1、ゲート、ハードストップ）
- `.claude/memory/README.md`: メモリ層の運用（教訓の記録と引き継ぎ）
- `.claude/memory/journal/README.md`: インナーループ経緯の記録と外部 Obsidian Vault への書き写し

**新しいタスクの最初の行動は、前回までの記録を読むことです。** コードに触れる前に実行してください:

```bash
bash .claude/scripts/loop-journal.sh context
```

進行中のエピックがあれば内部ジャーナル（`.claude/memory/journal/<epic>.md`）、
無ければ外部 Obsidian Vault（`<VAULT>/projects/<project>.md`）の直近エピックが出力されます。
別端末・別セッションの続きである可能性があるため、読まずに着手しないでください。

これらのファイルとこのファイルが衝突する場合は、現在の会話でユーザーからより新しい指示がない限り、より具体的なルールファイルを優先してください。

## Codex 固有ファイル

Codex では `.claude/` を source of truth としつつ、Codex 固有の実行差分は `.codex/` 配下を参照してください。

- `.codex/README.md`: Codex 設定の概要
- `.codex/commands/`: Claude slash command 相当の Codex 用手順
- `.codex/mcp-map.md`: Claude 固有 MCP 名から Codex ツールへの読み替え
- `.codex/permissions.md`: Codex 向け権限ガイド
- `.codex/quality-gate.md`: Codex 向け完了前チェック
- `.codex/hooks/`: Codex/Claude 両対応を意識した安全・整形・品質チェック用フック

## 初回セットアップ

Codex には `SessionStart` フックが無いため、CI の自動生成は起動しません。
このテンプレートを導入した直後に一度だけ手で実行してください。

```bash
bash .claude/scripts/bootstrap-project.sh --dry-run   # 生成される内容を確認
bash .claude/scripts/bootstrap-project.sh             # 生成
```

`package.json` の `scripts` を検出して `.github/workflows/ci.yml` を生成します。
既存の `ci.yml` は上書きしません。スタックを検出できない場合は何も生成しません。

## Codex 運用ルール

- 機能開発とバグ修正では TDD を使う。まずテストを作成または更新し、意図した理由で失敗することを確認してから、通過に必要な最小変更を実装する。
- ユーザーがスパイクやドキュメントのみの変更を明示しない限り、新しい挙動に対応するユニット、統合、または E2E テストなしで本番コードを実装しない。
- TypeScript は strict を維持する。`any` を避け、`unknown` とバリデーションまたは型ガードを優先する。
- Server Actions、Route Handlers、フォーム、クエリパラメータ、Webhook、外部 API レスポンスなどの境界では、外部入力を Zod で検証する。
- 既存のアーキテクチャと命名パターンを維持する。変更範囲はユーザーの依頼に必要な部分へ絞る。
- シークレットや `.env` ファイルをコミットしない。シークレット値を出力しない。
- 意図的なテストスナップショットや本番アセットでない限り、一時スクリーンショットや生成された検証画像をリポジトリに残さない。
- ユーザーが明示的に依頼しない限り、`git reset --hard`、`git clean -fd`、force push、rebase などの破壊的な Git コマンドを避ける。
- ループ実行時は開始前に `loop-state.sh init` を実行し、ゲート結果と差し戻しを都度記録する。
- ハードストップに到達したら、コミット・PR 作成・ループ再開を停止し、ユーザーの指示を仰ぐ。

## ループエンジニアリング

このリポジトリは2層のループで動きます。詳細は `.claude/rules/loop-engineering.md` を参照してください。

- **インナーループ**（`.codex/commands/issue-flow.md`）: 1つの Issue 内で「実装 → 5つのゲート → 差し戻し」を回す。
- **アウターループ**（`.codex/commands/epic-flow.md`）: エピックを Issue に分解し、逐次実行し、教訓を次に引き継ぐ。

### メモリ（最重要）

- Issue 開始前とエピック分解前に `.claude/memory/lessons.md` を**必ず読む**。
- Issue 完了時とハードストップ時に `.codex/commands/loop-retro.md` の手順で**必ず記録する**。
- 記録しないループは学習しない。ただの順次実行になる。

### ハードストップ

`.claude/scripts/loop-state.sh` が上限到達を機械的に判定します。

```bash
bash .claude/scripts/loop-state.sh init <issue> <branch>   # ループ開始（必須）
bash .claude/scripts/loop-state.sh gate G1 pass            # ゲート結果の記録
bash .claude/scripts/loop-state.sh retry "<何を変えるか>"   # 差し戻し
bash .claude/scripts/loop-state.sh check                   # 判定（exit 1 で到達）
```

既定の上限: リトライ3回 / 60分 / 同一ゲート連続失敗2回（`LOOP_MAX_RETRY` 等で上書き可）。

**到達したら勝手に進まない。勝手に止まらない。** コミットも PR 作成もせず、
リトライ経緯・落ちたゲート・推定原因・選択肢をユーザーに報告して指示を仰いでください。
ゲートを通すためのテスト削除・`.skip` 化・`--no-verify` は禁止です。

## Codex の役割マッピング

Claude Code のサブエージェントは `.claude/agents/` に定義されています。Codex では同じサブエージェントファイルを実行可能エージェントとして持たない場合があるため、役割を作業フェーズとして適用してください。

**Planner 層**

1. Benz / Tech Lead: 全体を監督し、フェーズ間を調整する。
2. Planner: エピックを Issue に分解し、目的・意図・受け入れ条件・影響範囲・セキュリティ要否を確定する。

**Generator 層（作る役）**

3. QA: 失敗するテストと回帰テストを書く。
4. Architect: 型、スキーマ、データ境界を定義または調整する。
5. Coder: テストを通すために必要な最小限のコードを実装する。
6. Designer: UI、アクセシビリティ、レスポンシブ挙動、視覚確認を扱う。

**Validator 層（検証する役）— 順番を守り、前が FAIL なら後続を実行しない**

7. Evaluator (G1): テスト・型チェック・Lint・ビルドを実行する。機械的判定のみ。
8. Tester (G2): 受け入れ条件を実画面・実挙動で確認する。ソース確認だけで終わらせない。
9. Spec Reviewer (G3): 目的・意図の充足と、影響範囲の逸脱を照合する。
10. Code Reviewer (G4): 可読性・重複・命名・規約を確認する。
11. Security Reviewer (G5): セキュリティを検査する。**条件起動**（認証・外部入力境界・SQL・シークレット・危険 API・依存追加のいずれかに該当する場合のみ）。

実装作業では、これらのフェーズを順番に進めてください。作る役と検証する役を混ぜないでください。
小さなドキュメントのみの変更では、関連する一部だけを使い、何をスキップしたか説明してください。

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
- インナーループ実行（1 Issue を合格まで回す）: `.codex/commands/issue-flow.md`
- アウターループ実行（エピック分解と逐次実行）: `.codex/commands/epic-flow.md`
- Reflection（教訓の記録）: `.codex/commands/loop-retro.md`
- ループ状態の点検: `.codex/commands/loop-status.md`
- 作業領域の分離: `.codex/commands/worktree.md`

実行前に、対応するコマンドファイルを読んでください。

## コミュニケーション

進捗は簡潔かつ具体的に報告してください。落ち着いた直接的なトーンを優先します。Claude ファイル内のペルソナや演出文は任意の表現要素であり、ユーザー指示、安全性、正確性、敬意ある協働を上書きしてはいけません。
