# agentic-tdd-starter

> Claude Code / Codex 向け TDD駆動・ループエンジニアリング・スターターテンプレート

「テストのないコードは存在しない」を強制する、Claude Code / Codex 両対応のルールセット・サブエージェント定義・スラッシュコマンド相当ワークフローの再利用可能なテンプレート。

Next.js + TypeScript + Vitest + Playwright を想定スタックとしているが、ルール／フローは他スタックにも転用可能。

---

## 🧊 コンセプト

- **ループエンジニアリング**: 人間が指示を打つのではなく、**AI が AI に指示を出し続ける仕組み**を設計する。
- **TDD強制**: Red → Green → Refactor のサイクルを開発フローに組み込む。テストのないコードはレビュー対象外。
- **サブエージェント分業**: 「作る役」と「検証する役」を明確に分離した11体。役割を超えた実装は禁止。
- **多軸ゲート**: 機械 → 実証 → 仕様 → コード → セキュリティの5ゲートを順に通す。1つでも FAIL なら差し戻し。
- **ハードストップ**: リトライ上限・時間上限・同一ゲート連続失敗で強制停止。無限リトライでコストを燃やさない。
- **外部メモリ**: 失敗を言語化して永続化し、セッションを跨いで学習させる。同じミスを二度繰り返さない。
- **キャラ駆動**: 「メイド」というキャラ設定で各エージェントを擬人化。淡々と・冷淡に・最短で。

---

## 🔁 ループ構造

```
アウターループ（/epic-flow）
  エピック → Planner が Issue に分解 → 人間が承認
       ↓
  ┌─ インナーループ（/issue-flow）── Issue 1本ごと ──────────┐
  │  実装（QA → Architect → Coder → Designer）              │
  │       ↓                                                │
  │  G1 機械 → G2 実証 → G3 仕様 → G4 コード → G5 セキュリティ │
  │       ↓ FAIL → 差し戻し（retry++）                       │
  │       ↓ retry上限 → ハードストップ → 人間へ報告            │
  │       ↓ 全PASS → PR                                     │
  └────────────────────────────────────────────────────────┘
       ↓ /loop-retro で教訓を .claude/memory/lessons.md へ
  次の Issue（前回の教訓を読んで開始）
       ↓
  エピック統合 PR → 人間が最終確認
```

**人間が介在するのは3箇所だけ**: エピックの要件定義 / 分解結果の承認 / ハードストップ発動時。

### ループを構成する 5＋1 の部品

| # | 部品 | 実体 |
| --- | --- | --- |
| ① | 自動化 | `.github/workflows/loop-automation.yml` |
| ② | ワークツリー | `.claude/scripts/worktree.sh` / `/worktree` |
| ③ | スキル（ハーネス） | `.claude/rules/` + `.claude/hooks/` |
| ④ | プラグイン / コネクター | `gh` CLI, Playwright MCP, Chrome DevTools MCP, Context7 MCP |
| ⑤ | サブエージェント | `.claude/agents/` 11体 |
| ＋1 | **メモリ** | `.claude/memory/` + 外部 Obsidian Vault（`.claude/scripts/loop-journal.sh`） |

詳細: `.claude/rules/loop-engineering.md`

---

## 📁 ディレクトリ構成

```
.
├── AGENTS.md                    # Codex 用のルート指示（要編集）
├── CLAUDE.md                    # プロジェクト全体のルートメモリ（要編集）
├── .github/
│   └── workflows/
│       └── loop-automation.yml  # ①自動化: ラベル/手動/定期でループを起動
├── .codex/
│   ├── README.md                # Codex 設定の概要
│   ├── agents/                  # Codex 用の役割定義（11体）
│   ├── commands/                # Codex 用のコマンド相当手順
│   ├── hooks/                   # Codex/Claude 両対応を意識したフック
│   ├── mcp-map.md               # MCP / tool 名の読み替え表
│   ├── permissions.md           # Codex 向け権限ガイド
│   └── quality-gate.md          # Codex 向け品質ゲート
└── .claude/
    ├── settings.json            # 権限・フック設定
    ├── agents/                  # サブエージェント定義（11体）
    │   ├── sub-agent-planner.md          # 立案（エピック分解・Opus）
    │   ├── sub-agent-qa.md               # 検閲（Red フェーズ）
    │   ├── sub-agent-architect.md        # 礎（型・スキーマ）
    │   ├── sub-agent-coder.md            # 構築（Green フェーズ）
    │   ├── sub-agent-designer.md         # 図案（UI/Tailwind）
    │   ├── sub-agent-evaluator.md        # 評価（G1 機械ゲート）
    │   ├── sub-agent-tester.md           # 実証（G2 実動作）
    │   ├── sub-agent-spec-reviewer.md    # 照合（G3 仕様）
    │   ├── sub-agent-code-reviewer.md    # 校閲（G4 コード）
    │   ├── sub-agent-security-reviewer.md # 守衛（G5 セキュリティ・Opus）
    │   └── sub-agent-knowledge.md        # 蒐集（任意・テンプレ）
    ├── commands/                # スラッシュコマンド定義
    │   ├── epic-flow.md         # アウターループ
    │   ├── issue-flow.md        # インナーループ
    │   ├── loop-retro.md        # Reflection（教訓の記録）
    │   ├── loop-status.md       # ループ状態の点検
    │   ├── worktree.md          # 安全な作業環境
    │   ├── smart-commit.md
    │   ├── create-pr.md
    │   ├── review-pr.md
    │   ├── merge-and-sync.md
    │   ├── coderabbit-fix.md
    │   ├── e2e-test.md
    │   ├── visual-regression.md
    │   ├── perf-audit.md
    │   └── knowledge-update.md
    ├── memory/                  # ＋1: 外部メモリ（ループの学習）
    │   ├── README.md            # メモリ層の運用ルール
    │   ├── lessons.md           # 教訓ログ（コミットする）
    │   ├── journal/             # インナーループの経緯（コミットする・flush 後に削除）
    │   │   └── README.md        # 内部ジャーナルの運用ルール
    │   ├── epics/               # エピック分解結果
    │   └── loop-state.json      # 実行時状態（gitignore）
    ├── scripts/                 # ループ制御
    │   ├── loop-state.sh        # ハードストップの実体
    │   ├── loop-journal.sh      # ＋1 外部記憶（Vault への書き出し）
    │   └── worktree.sh          # ②ワークツリー
    ├── hooks/                   # PreToolUse / PostToolUse / Stop フック
    │   ├── pre-tool-guard.sh    # 危険コマンド検知
    │   ├── loop-guard.sh        # ハードストップ後の続行をブロック
    │   ├── post-tool-format.sh  # 編集後 prettier 自動実行
    │   └── stop-quality-check.sh # 停止時に typecheck + lint
    └── rules/                   # 規約・ルールセット
        ├── loop-engineering.md  # ループ設計（2層構造・5＋1・ゲート・ハードストップ）
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
cp -r /tmp/agentic-tdd-starter/.github .
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
- **ハードストップの上限**を調整する（`.claude/rules/loop-engineering.md`、または環境変数 `LOOP_MAX_RETRY` / `LOOP_MAX_MINUTES` / `LOOP_MAX_SAME_GATE_FAIL`）
- **外部記憶を使う場合**: `bash .claude/scripts/loop-journal.sh init <vault-path>` で Obsidian Vault を接続する。
  Vault 側に `projects/<project>.md` が作られる。接続情報は端末ごとのローカル設定でコミットされない
- **自動化を使う場合**: `.github/workflows/loop-automation.yml` に Secrets（`ANTHROPIC_API_KEY`）を設定し、
  `loop:ready` / `loop:halted` ラベルを作成する。コストが読めるまで `schedule` は無効のままにする
- `jq` が必要（ループ状態管理とフックで使用）

### 前提ツール

| ツール | 用途 | 必須 |
| --- | --- | --- |
| `git` (2.5+) | worktree による作業領域分離 | ✅ |
| `jq` | ループ状態の読み書き・フック | ✅ |
| `gh` | Issue / PR 操作 | ループを GitHub で回す場合 |
| Obsidian Vault | 外部記憶（`projects/<project>.md`） | セッション跨ぎの記録を残す場合 |

### 3. Claude Code / Codex で読み込む

プロジェクトのルートで `claude` コマンドを実行すれば、`CLAUDE.md` と `.claude/` 配下が自動的に読み込まれる。

Codex ではプロジェクトルートの `AGENTS.md` が入口になる。`AGENTS.md` は `.claude/rules/` を source of truth としつつ、`.codex/commands/`、`.codex/mcp-map.md`、`.codex/permissions.md`、`.codex/quality-gate.md` を参照するため、Claude 用の設定と近い規約を Codex でも使える。

> 補足: `.claude/hooks/` と `.claude/settings.json` は Claude Code 用のフック/権限設定。Codex では `.codex/hooks/`、`.codex/permissions.md`、`.codex/quality-gate.md` を参照する。

---

## 🤖 サブエージェント

| 名前 | 日本語名 | 役割 | 層 | モデル |
| --- | --- | --- | --- | --- |
| Benz | メイド長 | 全体監督・オーケストレーション・Refactor判断 | Planner | — |
| Planner | 立案のメイド | エピック → Issue 分解、受け入れ条件の確定 | Planner | Opus |
| QA | 検閲のメイド | テスト設計（Red） | Generator | Sonnet |
| Architect | 礎のメイド | DB / 型 / Zod スキーマ定義 | Generator | Sonnet |
| Coder | 構築のメイド | 実装（Green） | Generator | Sonnet |
| Designer | 図案のメイド | UI / Tailwind / 視覚検証 | Generator | Sonnet |
| Evaluator | 評価のメイド | **G1** 機械ゲート（test/type/lint/build） | Validator | Sonnet |
| Tester | 実証のメイド | **G2** 実証ゲート（Playwright で実画面確認） | Validator | Sonnet |
| Spec Reviewer | 照合のメイド | **G3** 仕様ゲート（目的・意図・影響範囲） | Validator | Sonnet |
| Code Reviewer | 校閲のメイド | **G4** コードゲート（可読性・規約） | Validator | Sonnet |
| Security Reviewer | 守衛のメイド | **G5** セキュリティゲート（**条件起動**） | Validator | Opus |

呼び出し順序:
**Planner → QA → Architect → Coder → Designer → G1 → G2 → G3 → G4 → (G5) → Benz（Refactor）**

> **作る役と検証する役を混ぜない。** 1体に全部やらせるより、分けたほうが品質が上がる。
> G5 は常駐しない。認証・外部入力・SQL・シークレット・危険 API・依存追加に触れる Issue でのみ起動する。

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
| `/epic-flow`         | **アウターループ**（エピック分解→逐次実行→学習） | `.codex/commands/epic-flow.md` |
| `/issue-flow`        | **インナーループ**（実装→G1〜G5→差し戻し） | `.codex/commands/issue-flow.md` |
| `/loop-retro`        | Reflection（教訓を lessons.md に記録） | `.codex/commands/loop-retro.md` |
| `/loop-status`       | ループ状態・ハードストップ余力の確認 | `.codex/commands/loop-status.md` |
| `/worktree`          | 安全な作業環境の作成・撤収       | `.codex/commands/worktree.md` |

---

## 📋 想定スタック

テンプレートは以下のスタックを前提に書かれているが、各ルールファイルを編集すれば他スタックにも転用可能。

- Next.js (App Router) + React + Tailwind CSS
- TypeScript + Zod
- Prisma (PostgreSQL) / Supabase
- Vitest + React Testing Library + Playwright
- GitHub Actions
- GitHub CLI (`gh`)
- `jq`（ループ状態管理・フックで必須）

---

## ⛔ ハードストップ

「合格するまでやり直せ」とだけ命じるのは設計放棄。解けない問題に無限リトライしてコストが死ぬ。

| 停止条件 | 既定値 | 環境変数 |
| --- | --- | --- |
| 最大リトライ回数（1 Issue） | 3 | `LOOP_MAX_RETRY` |
| 最大経過時間（1 Issue・分） | 60 | `LOOP_MAX_MINUTES` |
| 同一ゲートの連続 FAIL | 2 | `LOOP_MAX_SAME_GATE_FAIL` |

```bash
bash .claude/scripts/loop-state.sh init <issue> <branch>   # ループ開始
bash .claude/scripts/loop-state.sh gate G1 pass            # ゲート結果を記録
bash .claude/scripts/loop-state.sh retry "<何を変えるか>"   # 差し戻し
bash .claude/scripts/loop-state.sh check                   # 判定（exit 1 で到達）
```

到達すると `.claude/hooks/loop-guard.sh` がサブエージェント起動・コミット・PR 作成を**ブロック**する。
勝手に進むな。勝手に止まるな。人間に報告して指示を仰げ。

---

## 🧠 メモリ（ループの学習）

メモリは**2層**。リポジトリの中と外に分ける。

```
外部（Obsidian Vault）  <VAULT>/projects/<project>.md
  … アウターループの節目 + 完了エピックの全記録。永続・追記のみ・リポジトリ外
        ↑ flush（アウターループ完了時に1回だけ）
内部（Git 管理）        .claude/memory/journal/<epic-slug>.md
  … インナーループの節目4点。別端末への引き継ぎのためコミットする。flush 後に削除
```

| ファイル | 内容 | Git |
| --- | --- | --- |
| `.claude/memory/lessons.md` | 教訓（次回ルール） | **コミットする** |
| `.claude/memory/journal/<epic>.md` | 経緯（何をやって、なぜそうしたか） | **コミットする** |
| `.claude/memory/epics/` | エピック分解結果 | **コミットする** |
| `.claude/memory/loop-state.json` | 実行時状態 | gitignore |
| `<VAULT>/projects/<project>.md` | 完了エピックの全記録 | 対象外（Vault 側） |

### 使い方

```bash
# 1. Vault を接続する（端末ごとに1回。省略で自動検出）
bash .claude/scripts/loop-journal.sh init "/path/to/Obsidian Vault"

# 2. ★新しいタスクの最初の行動。読むべき記録が出力される
bash .claude/scripts/loop-journal.sh context

# 3. インナーループの節目（4点）を内部ジャーナルへ
bash .claude/scripts/loop-journal.sh inner 42 impl "記事検索" <<'ENTRY'
- **やったこと**: Server Action と Zod スキーマを追加
- **なぜ**: 戻り値を Zod から導出しないと any に落ちる（過去の教訓）
ENTRY

# 4. アウターループの節目は Vault へ直接
bash .claude/scripts/loop-journal.sh outer plan "分解完了" <<< "- 3本に分解した"

# 5. エピック完了時。内部ジャーナルを Vault へ書き写して削除する
bash .claude/scripts/loop-journal.sh flush <<< "- 完了"

# 状態確認
bash .claude/scripts/loop-journal.sh status
```

**読む先の判定は自動。** 進行中のエピックがあれば内部ジャーナル、無ければ Vault。

`flush` は Vault への着地を確認するまで内部ジャーナルを削除しない。
Vault が繋がっていない端末では失敗してジャーナルを残す。**記録は落とさない。**

**メモリの無いループは、ただの順次実行。** Issue 完了時の `/loop-retro` と
エピック完了時の `flush` を飛ばした時点で学習は止まる。

---

## 💬 トーン

エージェント／メイン Claude のコミュニケーションは、デフォルトでは「冷淡・タメ口・極短報告」のトーン。
気に入らなければ `CLAUDE.md` の「💬 コミュニケーションスタイル」を書き換えること。

---

## 📝 License

MIT
