# create PR

現在のブランチから Pull Request を作成する。

## 手順

1. `git status --short` で未コミット変更を確認する。
2. 未コミット変更がある場合は、コミットするかユーザーに確認する。
3. `git log main..HEAD --oneline` と `git diff main...HEAD` で PR 内容を把握する。
4. 必要なら `git push -u origin HEAD` を実行する。
5. GitHub コネクタが使える場合はそれを優先し、なければ `gh pr create` を使う。
6. PR タイトルは英語で 70 文字以内、本文は日本語で作る。
7. 作成後、PR URL を報告する。

## PR 本文の基本構成

- 変更の概要
- 変更の理由
- 変更内容
- テスト方法
- 影響範囲
- チェックリスト

## Codex 注意点

- 最新コミットだけでなく、ブランチ全体の差分を見る。
- `.github/pull_request_template.md` が存在する場合は優先する。
- Claude 版の詳細テンプレートが必要な場合は `.claude/commands/create-pr.md` も参照する。
