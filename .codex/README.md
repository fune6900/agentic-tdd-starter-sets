# Codex 設定

このディレクトリは、Claude Code の `.claude/` 設定を Codex で近い形に再現するための入口です。

## 構成

- `agents/`: Claude サブエージェントを Codex の作業フェーズとして読むための役割定義
- `commands/`: Claude slash command 相当の Codex 用手順
- `hooks/`: Claude/Codex 両対応を意識した安全・整形・品質チェック用フック
- `mcp-map.md`: Claude 固有 MCP 名を Codex の利用可能ツールへ読み替える対応表
- `permissions.md`: Codex 向け権限ガイド
- `quality-gate.md`: Codex 向け完了前チェック

## 運用

Codex はまず `AGENTS.md` を読み、必要に応じてこのディレクトリの該当ファイルを参照します。
`.claude/` は引き続き Claude Code 側の source of truth として残し、Codex 固有の差分だけをここに置きます。
