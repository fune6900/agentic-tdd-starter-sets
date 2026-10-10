# 🧊 Project: agentic-tdd-starter

## 📝 プロジェクト概要

<!--
ここにプロジェクトの概要を1〜3段落で記述する。
例:
- ターゲットユーザー
- 提供する主要な体験 / 機能
- プロダクトの軸（〇〇 × △△ × □□）
-->

{{PROJECT_DESCRIPTION}}

## 🛠 技術スタック

<!--
プロジェクトで実際に採用するスタックに書き換えること。
ここはあくまでテンプレートの初期値（フルスタックWebアプリ想定）。
-->

- **Core**: Next.js (App Router), React, Tailwind CSS
- **State**: TanStack Query (React Query)
- **Database**: Prisma (PostgreSQL) / Supabase
- **Validation**: TypeScript, Zod
- **Testing**: Vitest, React Testing Library, Playwright (TDD Mandatory)
- **CI/CD**: GitHub Actions

## 💻 主要コマンド

- `npm run dev` — 開発サーバー起動
- `npm run build` — 本番用ビルド
- `npm run lint` — ESLint
- `npm run typecheck` — 型チェック
- `npm test` — ユニットテスト（Vitest）
- `npm run e2e` — E2Eテスト（Playwright）

## 📁 ディレクトリ構造

<!-- プロジェクトの実態に合わせて編集すること -->

- `app/` — ルーティング、Server Actions
- `components/ui/` — 汎用UIコンポーネント
- `components/features/` — 機能別コンポーネント
- `hooks/` — カスタムフック
- `lib/` / `services/` — ユーティリティ・外部APIアクセス
- `types/` — 型定義・Zodスキーマ
- `tests/unit/` — Vitestユニットテスト
- `tests/e2e/` — Playwright E2Eテスト
- `.claude/memory/` — ループの外部メモリ（教訓・経緯・エピック分解・実行状態）
- `.claude/memory/journal/` — インナーループの経緯。エピック完了時に外部 Vault へ書き写して削除
- `.claude/scripts/` — ループ制御スクリプト（ハードストップ・ワークツリー・外部記憶・初期セットアップ）
- `.claude/monitor/` — 監視サーバ・ビュー・compose の原本（導入手順は README の「監視」）
- `tests/` — テンプレート自身のシェルテスト（`bash tests/run.sh`）。導入先プロジェクトには持ち込まない

## 🔄 開発フロー

**全ての実装はこの順序を厳守する。**

```
Plan Mode → ISSUE作成 → ブランチ作成
  → TDD(Red→Green→Refactor) → ゲート通過(G1〜G5) → /smart-commit
  → /create-pr → CI確認 → /review-pr
  → LGTM → マージ → /loop-retro → リリース
```

詳細: @.claude/rules/dev-flow.md

### 🔁 ループ構造（インナー / アウター）

```
アウターループ（/epic-flow）… エピック → Issue 分解 → 逐次実行 → セッション跨ぎの学習
  └ インナーループ（/issue-flow）… 実装 → G1〜G5 → 差し戻し → 全PASS で PR
       └ ハードストップ … retry上限 / 時間上限 / 同一ゲート連続失敗で強制停止 → 人間へ
```

**人間が介在するのは3箇所だけ**: エピックの要件定義 / Planner の分解結果の承認 / ハードストップ発動時。
インナーループの途中では介在しない。ゲートの判定を信頼し、判定に問題があればゲート自体を修正する。

### 🧠 外部記憶（2層）

```
外部（Obsidian Vault）  <VAULT>/projects/<project>.md
  … アウターループの節目 + 完了エピックの全記録。永続・追記のみ
        ↑ flush（アウターループ完了時に1回だけ）
内部（Git 管理）        .claude/memory/journal/<epic-slug>.md
  … インナーループの節目4点（着手・実装完了・ゲート一巡・完了/停止）。flush 後に削除
```

**新しいタスクの最初の行動は、記録を読むこと。** コードに触れる前に必ず実行する:

```bash
bash .claude/scripts/loop-journal.sh context
```

進行中のエピックがあれば内部ジャーナル、無ければ Vault の直近エピックが出力される。
前のセッション・別の端末が何をやって**なぜそうしたか**を把握してから着手する。

詳細: @.claude/rules/loop-engineering.md

## 📋 ルール一覧

| ファイル                       | 内容                                                |
| ------------------------------ | --------------------------------------------------- |
| @.claude/rules/conventions.md  | コーディング規約（命名・TS・ディレクトリ）          |
| @.claude/rules/security.md     | セキュリティルール（バリデーション・XSS・機密情報） |
| @.claude/rules/testing.md      | テスト方針（TDD・種別・モック）                     |
| @.claude/rules/git-strategy.md | Git/ブランチ戦略（命名・コミット・マージ）          |
| @.claude/rules/api-design.md   | API設計ルール（Server Actions・Route Handlers）     |
| @.claude/rules/agents.md       | サブエージェント呼び出し規則（責務・順序）          |
| @.claude/rules/loop-engineering.md | ループ設計（2層構造・5＋1・ゲート・ハードストップ） |
| @.claude/memory/README.md      | メモリ層の運用（教訓の記録と引き継ぎ）              |
| @.claude/memory/journal/README.md | インナーループ経緯の記録と外部 Vault への書き写し |

## 🤖 エージェント・オーケストレーション

責務を分けた11のエージェントで構成する。役割を超えた実装は禁止。

**Planner 層**

1. **Tech Lead**: 全体監督・オーケストレーション・Refactor判断。
2. **Planner**: エピックを Issue に分解。目的・意図・受け入れ条件・影響範囲を確定させる。`Opus`

**Generator 層（作る役）**

3. **QA**: TDD Enforcer. Redフェーズ担当・テスト設計。
4. **Architect**: DB・型・Zodスキーマ定義。
5. **Coder**: Greenフェーズ担当・実装。
6. **Designer**: UI/UX・Tailwind実装・視覚検証。

**Validator 層（検証する役）**

7. **Evaluator**: G1 機械ゲート。test / typecheck / lint / build。
8. **Tester**: G2 実証ゲート。Playwright で実画面まで動作確認。
9. **Spec Reviewer**: G3 仕様ゲート。目的・意図の充足、影響範囲の逸脱。
10. **Code Reviewer**: G4 コードゲート。可読性・重複・命名・規約。
11. **Security Reviewer**: G5 セキュリティゲート。**条件起動**（常駐しない）。`Opus`

呼び出し順序:
**Planner → QA → Architect → Coder → Designer → G1 → G2 → G3 → G4 → (G5) → Tech Lead（Refactor）**

**作る役と検証する役は分ける。** 1体に全部やらせるより、分けたほうが品質が上がる。

## 🧰 初回セットアップ（導入先プロジェクト）

このテンプレートを導入したプロジェクトでは、初回起動時に `SessionStart` フックが
`.claude/scripts/bootstrap-project.sh` を実行し、`package.json` を検出して
`.github/workflows/ci.yml` を1本だけ生成する。

- **既存の `ci.yml` は絶対に上書きしない**
- スタックを検出できなければ**何も生成しない**
- 冪等。`LOOP_BOOTSTRAP=0` で無効化できる

生成された CI は以後手で管理してよい。内容を確認してからコミットすること。

同じく `SessionStart` で `.claude/scripts/bootstrap-monitor.sh` が、監視サーバ用の `compose.monitor.yml` を生成する。
compose ファイルが（直下・祖先とも）1つも無い場合のみ `include` だけの `compose.yaml` も作る。

- **既存の compose ファイルは絶対に触らない**（`include` の追記方法を案内するだけ）
- 直下に `package.json` も compose ファイルも無ければ**何も生成しない**
- 冪等。`LOOP_BOOTSTRAP=0` で無効化できる

## 🛠 スラッシュコマンド

| コマンド             | 用途                                                            |
| -------------------- | --------------------------------------------------------------- |
| `/smart-commit`      | lint/typecheck通過後にコミット                                  |
| `/create-pr`         | PRテンプレートに従いPR作成                                      |
| `/review-pr`         | AIによるコードレビュー                                          |
| `/merge-and-sync`    | PRをmainにマージしてローカルをmainに同期                        |
| `/coderabbit-fix`    | CodeRabbitの指摘を取得・分析して自動修正                        |
| `/e2e-test`          | E2Eテスト実行（QAエージェント）                                 |
| `/visual-regression` | 視覚的整合性検証（Designerエージェント）                        |
| `/perf-audit`        | パフォーマンス計測                                              |
| `/epic-flow`         | **アウターループ**: エピック分解 → Issue 逐次実行 → 学習         |
| `/issue-flow`        | **インナーループ**: 1 Issue を実装→G1〜G5→差し戻しで合格まで回す |
| `/loop-retro`        | Reflection。教訓を `.claude/memory/lessons.md` に記録            |
| `/loop-status`       | ループ状態・ハードストップまでの余力・外部記憶の状態を確認        |
| `/worktree`          | 安全な作業環境（git worktree）の作成・撤収                       |

## 🧠 行動原則

- **No Test, No Code**: テストのないコードは存在しない。
- **型安全の強制**: `any` は使わない。`unknown` と型ガードで扱う。
- **計画優先**: Planモードを使い、設計を固めてから着手する。
- **PR至上主義**: 全ての変更はブランチを切り、PRを通す。
- **指示ではなくループを設計する**: 単発の指示ではなく、AI が自律的に回る仕組みを組む。
- **ハードストップ厳守**: 上限に達したら、独断で先に進むことも作業を放棄することもせず、ユーザーに報告して指示を仰ぐ。
- **まず記録を読む**: 新しいタスクの最初の行動は `loop-journal.sh context`。前のセッションの経緯を把握してから続きに着手する。
- **記憶する**: 失敗は `.claude/memory/lessons.md` に言語化して残す。同じミスを繰り返さない。
- **節目ごとに記録する**: 「何をやったか」ではなく「**なぜそうしたか**」を残す。理由の無い記録は次のセッションで役に立たない。
- **経緯と教訓を分ける**: 経緯は `journal/`（消える）、次回ルールは `lessons.md`（残る）。混在させると、教訓が経緯と一緒に削除される。
- **後片付け強制**: 検証用スクショ（PNG・JPEG）は撮影 → 確認 → 削除を1セット。リポジトリに残骸を残さない。

## 👥 役割

- **ユーザー**: プロジェクトのオーナー。要件定義・分解結果の承認・ハードストップ時の判断を行う。
- **Tech Lead**: 実務上の最高責任者。オーケストレーションと Refactor 判断を担う。

## 💬 コミュニケーションスタイル

- 丁寧語（です・ます調）で話す。
- 報告は簡潔に。結論を先に述べ、根拠を添える。
