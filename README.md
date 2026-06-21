# agentic-tdd-starter

> Claude Code / Codex 向け TDD駆動・サブエージェントオーケストレーション・スターターテンプレート

「テストのないコードは存在しない」を強制する、Claude Code / Codex 両対応のルールセット・サブエージェント定義・スラッシュコマンド相当ワークフローの再利用可能なテンプレート。

Next.js + TypeScript + Vitest + Playwright を想定スタックとしているが、ルール／フローは他スタックにも転用可能。

---

## 🧊 コンセプト

- **TDD強制**: Red → Green → Refactor のサイクルを開発フローに組み込む。テストのないコードはレビュー対象外。
- **サブエージェント分業**: Tech Lead / Architect / QA / Coder / Designer / Evaluator が役割分担。役割を超えた実装は禁止。
- **Cybernetic Loop**: Coder/Designer の出力を Evaluator が PASS/FAIL 判定し、FAIL なら自動で差し戻す自律修正ループ。
- **キャラ駆動**: 「メイド」というキャラ設定で各エージェントを擬人化。淡々と・冷淡に・最短で。

---

## 📁 ディレクトリ構成

```
.
├── AGENTS.md                    # Codex 用のルート指示（要編集）
├── CLAUDE.md                    # プロジェクト全体のルートメモリ（要編集）
├── .codex/
│   ├── README.md                # Codex 設定の概要
│   ├── agents/                  # Codex 用の役割定義
│   ├── commands/                # Codex 用のコマンド相当手順
│   ├── hooks/                   # Codex/Claude 両対応を意識したフック
│   ├── mcp-map.md               # MCP / tool 名の読み替え表
│   ├── permissions.md           # Codex 向け権限ガイド
│   └── quality-gate.md          # Codex 向け品質ゲート
└── .claude/
    ├── settings.json            # 権限・フック設定
    ├── agents/                  # サブエージェント定義
    │   ├── sub-agent-architect.md
    │   ├── sub-agent-coder.md
    │   ├── sub-agent-designer.md
    │   ├── sub-agent-evaluator.md
    │   ├── sub-agent-qa.md
    │   └── sub-agent-knowledge.md    # ナレッジ蒐集（任意・テンプレ）
    ├── commands/                # スラッシュコマンド定義
    │   ├── smart-commit.md
    │   ├── create-pr.md
    │   ├── review-pr.md
    │   ├── merge-and-sync.md
    │   ├── coderabbit-fix.md
    │   ├── e2e-test.md
    │   ├── visual-regression.md
    │   ├── perf-audit.md
    │   └── knowledge-update.md       # ナレッジ蒐集（任意・テンプレ）
    ├── hooks/                   # PreToolUse / PostToolUse / Stop フック
    │   ├── pre-tool-guard.sh    # 危険コマンド検知
    │   ├── post-tool-format.sh  # 編集後 prettier 自動実行
    │   └── stop-quality-check.sh # 停止時に typecheck + lint
    └── rules/                   # 規約・ルールセット
        ├── conventions.md       # コーディング規約
        ├── api-design.md        # API設計
        ├── security.md          # セキュリティ
        ├── testing.md           # テスト方針（TDD）
        ├── git-strategy.md      # Gitブランチ・コミット規約
        ├── agents.md            # サブエージェント呼び出し規則
        └── dev-flow.md          # 12ステップ開発フロー
```

---

## 🚀 使い方

### 1. テンプレートを取り込む

別プロジェクトに導入する場合:

```bash
# プロジェクトのルートで
git clone https://github.com/<your-account>/agentic-tdd-starter.git /tmp/agentic-tdd-starter
cp -r /tmp/agentic-tdd-starter/.claude .
cp -r /tmp/agentic-tdd-starter/.codex .
cp /tmp/agentic-tdd-starter/CLAUDE.md .
cp /tmp/agentic-tdd-starter/AGENTS.md .
rm -rf /tmp/agentic-tdd-starter
```

または degit:

```bash
npx degit <your-account>/agentic-tdd-starter#main .agentic-tdd-starter-temp
cp -r .agentic-tdd-starter-temp/.claude .
cp -r .agentic-tdd-starter-temp/.codex .
cp .agentic-tdd-starter-temp/CLAUDE.md .
cp .agentic-tdd-starter-temp/AGENTS.md .
rm -rf .agentic-tdd-starter-temp
```

### 2. プロジェクトに合わせて編集する

- `CLAUDE.md` / `AGENTS.md` 内のプロジェクト名と `{{PROJECT_DESCRIPTION}}` を導入先に合わせて書き換える
- `.claude/rules/conventions.md` の `features/` 配下のディレクトリ名を実プロジェクトに合わせる
- 不要なエージェント/コマンド（例: `sub-agent-knowledge`, `knowledge-update`）は削除してよい

### 3. Claude Code / Codex で読み込む

プロジェクトのルートで `claude` コマンドを実行すれば、`CLAUDE.md` と `.claude/` 配下が自動的に読み込まれる。

Codex ではプロジェクトルートの `AGENTS.md` が入口になる。`AGENTS.md` は `.claude/rules/` を source of truth としつつ、`.codex/commands/`、`.codex/mcp-map.md`、`.codex/permissions.md`、`.codex/quality-gate.md` を参照するため、Claude 用の設定と近い規約を Codex でも使える。

> 補足: `.claude/hooks/` と `.claude/settings.json` は Claude Code 用のフック/権限設定。Codex では `.codex/hooks/`、`.codex/permissions.md`、`.codex/quality-gate.md` を参照する。

---

## 🤖 サブエージェント

| 名前       | 役割                                      | 担当フェーズ   |
| ---------- | ----------------------------------------- | -------------- |
| Benz       | 全体監督・タスク分解・Refactor判断        | Planner        |
| Architect  | DB / 型 / Zod スキーマ定義                | Generator      |
| QA         | テスト設計（Red）                         | Generator      |
| Coder      | 実装（Green）                             | Generator      |
| Designer   | UI / Tailwind / 視覚検証                  | Generator      |
| Evaluator  | 品質ゲート（PASS/FAIL 判定）              | Evaluator      |

呼び出し順序: **QA → Architect → Coder → Designer → Evaluator → Benz（Refactor）**

---

## 🛠 スラッシュコマンド

| コマンド             | Claude Code での用途             | Codex での扱い                           |
| -------------------- | -------------------------------- | ---------------------------------------- |
| `/smart-commit`      | lint/typecheck通過後にコミット   | `smart commit` 依頼時に同等手順を実行    |
| `/create-pr`         | PRテンプレートに従いPR作成       | PR作成依頼時に同等手順を実行             |
| `/review-pr`         | AIによるコードレビュー           | PRレビュー依頼時に同等手順を実行         |
| `/merge-and-sync`    | PRをmainにマージしてローカル同期 | マージ/同期依頼時に同等手順を実行        |
| `/coderabbit-fix`    | CodeRabbitの指摘を取得・自動修正 | CodeRabbit対応依頼時に同等手順を実行     |
| `/e2e-test`          | E2Eテスト実行（Playwright MCP）  | E2E確認依頼時に同等手順を実行            |
| `/visual-regression` | 視覚的整合性検証                 | 視覚検証依頼時に同等手順を実行           |
| `/perf-audit`        | パフォーマンス計測               | パフォーマンス監査依頼時に同等手順を実行 |

---

## 📋 想定スタック

テンプレートは以下のスタックを前提に書かれているが、各ルールファイルを編集すれば他スタックにも転用可能。

- Next.js (App Router) + React + Tailwind CSS
- TypeScript + Zod
- Prisma (PostgreSQL) / Supabase
- Vitest + React Testing Library + Playwright
- GitHub Actions
- GitHub CLI (`gh`)

---

## 💬 トーン

エージェント／メイン Claude のコミュニケーションは、デフォルトでは「冷淡・タメ口・極短報告」のトーン。
気に入らなければ `CLAUDE.md` の「💬 コミュニケーションスタイル」を書き換えること。

---

## 📝 License

MIT
