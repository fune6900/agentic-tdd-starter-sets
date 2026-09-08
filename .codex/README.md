# Codex 設定

このディレクトリは、Claude Code の `.claude/` 設定を Codex で近い形に再現するための入口です。

## 構成

- `agents/`: Claude サブエージェントを Codex の作業フェーズとして読むための役割定義（11体）
- `commands/`: Claude slash command 相当の Codex 用手順（ループ系5本を含む）
- `hooks/`: Claude/Codex 両対応を意識した安全・整形・品質チェック用フック
- `mcp-map.md`: Claude 固有 MCP 名を Codex の利用可能ツールへ読み替える対応表
- `permissions.md`: Codex 向け権限ガイド
- `quality-gate.md`: Codex 向け完了前チェック

## ループエンジニアリング

ループの設計そのもの（2層構造・5＋1の部品・ゲート定義・ハードストップ）は
`.claude/rules/loop-engineering.md` が source of truth です。Codex 側に複製は置きません。

Codex 用の実行手順は以下:

- `commands/epic-flow.md`: アウターループ（エピック分解 → 逐次実行 → 学習）
- `commands/issue-flow.md`: インナーループ（実装 → G1〜G5 → 差し戻し）
- `commands/loop-retro.md`: Reflection（教訓を `.claude/memory/lessons.md` に記録）
- `commands/loop-status.md`: ループ状態の点検
- `commands/worktree.md`: 安全な作業環境の作成・撤収

ハードストップの判定は `.claude/scripts/loop-state.sh` が行います（Claude / Codex 共用）。
外部記憶（内部ジャーナル ↔ Obsidian Vault）の読み書きは `.claude/scripts/loop-journal.sh` が行います（同じく共用）。

### 外部記憶（2層）

```
外部（Obsidian Vault）  <VAULT>/projects/<project>.md   … 永続・追記のみ
        ↑ flush（アウターループ完了時に1回）
内部（Git 管理）        .claude/memory/journal/<epic>.md … インナーの節目4点。flush 後に削除
```

**新しいタスクの最初の行動は `bash .claude/scripts/loop-journal.sh context`。**
進行中のエピックがあれば内部ジャーナル、無ければ Vault の直近エピックが出力されます。

## 初回セットアップ

Codex には `SessionStart` フックが無いため、導入先 CI の自動生成は起動しません。
導入直後に一度だけ実行してください。

```bash
bash .claude/scripts/bootstrap-project.sh
```

`package.json` の `scripts` から `.github/workflows/ci.yml` を生成します。
既存ファイルは上書きせず、検出できない場合は何も生成しません（冪等）。

## 運用

Codex はまず `AGENTS.md` を読み、必要に応じてこのディレクトリの該当ファイルを参照します。
`.claude/` は引き続き Claude Code 側の source of truth として残し、Codex 固有の差分だけをここに置きます。
`.claude/memory/` と `.claude/scripts/` は Claude / Codex 双方から使う共有資産です。
