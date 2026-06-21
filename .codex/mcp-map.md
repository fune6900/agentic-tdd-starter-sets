# Codex MCP / Tool 対応表

Claude Code 向けテンプレートに出てくる MCP 名は、Codex では同名で使えない場合がある。
Codex で作業するときは、以下の順に読み替える。

## ブラウザ・E2E

| Claude 側の名前 | Codex 側の優先手段 |
| --- | --- |
| `mcp__playwright__browser_*` | Codex のブラウザ操作ツール、または `tool_search` で browser / playwright をロード |
| `mcp__chrome-devtools__*` | Codex のブラウザ操作ツール、または Playwright / Chrome 相当の利用可能ツール |

Codex でブラウザツールが見えていない場合は、まず `tool_search` で `browser`、`playwright`、`chrome` を探す。
見つからない場合は、通常の CLI テスト（`npm run e2e` など）で代替し、未実施の視覚確認を明記する。

## 最新ドキュメント

| Claude 側の名前 | Codex 側の優先手段 |
| --- | --- |
| `mcp__context7__resolve-library-id` | 公式ドキュメントを web で確認、または利用可能な docs コネクタ |
| `mcp__context7__query-docs` | 公式ドキュメント、一次情報、リポジトリ内ドキュメント |

ライブラリや API の仕様が変わり得る場合は、推測で進めず一次情報を確認する。
OpenAI 製品に関する質問では、公式 OpenAI ドキュメントを優先する。

## GitHub

| Claude 側の名前 | Codex 側の優先手段 |
| --- | --- |
| `gh pr *` | GitHub コネクタが使える場合は優先。なければ `gh` CLI |
| `gh api *` | GitHub コネクタ、または `gh api` |

PR レビュー、CI 修正、PR 作成は、利用可能なら GitHub 系スキル/コネクタを優先する。

## スクリーンショット

一時スクリーンショットや検証画像は、完了前に削除する。
本番アセット、意図的なテストスナップショット、ユーザーが保存を求めた成果物は削除しない。
