# merge and sync

現在のブランチの PR を main にマージし、ローカルを最新化する。

## 手順

1. `git status --short` で未コミット変更がないことを確認する。
2. 現在のブランチ名を確認する。
3. GitHub コネクタまたは `gh pr list --head <branch>` で対応 PR を特定する。
4. PR の CI/checks がグリーンか確認する。
5. CI が red の場合はマージせず、ユーザーに確認する。
6. Squash merge とリモートブランチ削除を実行する。
7. `main` に切り替えて最新状態を取得する。
8. ローカルの作業ブランチを削除できる場合は削除する。
9. マージ PR、現在ブランチ、最新コミットを報告する。

## Codex 注意点

- `--force`、`--no-verify`、破壊的な履歴変更は禁止。
- ユーザーの未コミット変更がある場合は止まる。
- Claude 版の詳細テンプレートが必要な場合は `.claude/commands/merge-and-sync.md` も参照する。
