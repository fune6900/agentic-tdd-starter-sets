# Git / ブランチ戦略

## ブランチモデル

```
main
  └── feat/<issue番号>-<内容>   # 機能開発
  └── fix/<issue番号>-<内容>    # バグ修正
  └── refactor/<issue番号>-<内容>  # リファクタリング
  └── chore/<issue番号>-<内容>  # 設定・依存関係変更
```

- `main` は常にデプロイ可能な状態を維持する
- 直接 `main` へのコミットは禁止。必ずブランチを切ってPRを通す
- ブランチは機能単位で切る。1ブランチ = 1 ISSUE

---

## ブランチ命名規則

```
<種別>/<issue番号>-<内容の短縮（英語・kebab-case）>

feat/12-article-search
fix/15-submit-button-double-click
refactor/20-dashboard-query-optimization
chore/25-update-next-to-16
ci/30-add-test-workflow
```

| 種別 | 用途 |
|------|------|
| `feat/` | 新機能の追加 |
| `fix/` | バグ修正 |
| `refactor/` | 機能変更を伴わないリファクタリング |
| `chore/` | 設定・依存関係・ドキュメント変更 |
| `ci/` | CI/CD パイプラインの変更 |

---

## コミット規約

```
<種別>: <変更の理由（英語・50文字以内）>

本文（省略可）:
- 詳細な理由・背景
- 意思決定の記録

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
```

| 種別 | 用途 |
|------|------|
| `feat` | 新機能 |
| `fix` | バグ修正 |
| `refactor` | リファクタリング |
| `test` | テスト追加・修正 |
| `chore` | 設定変更・依存更新 |
| `ci` | CI/CD変更 |
| `docs` | ドキュメントのみの変更 |

**NG例**: `fix bug`, `update`, `WIP`, `あとでなおす`
**OK例**: `fix: prevent double submission on submit button`

コミットには `/smart-commit` を使う。lint + typecheck を自動で通過確認してからコミットする。

---

## ISSUE との紐付け

- PR の body に `Closes #<issue番号>` を記載する
- マージ時に ISSUE が自動クローズされることを確認する
- ISSUE なしの PR は原則禁止（緊急 hotfix を除く）

---

## PRルール

- タイトルは英語・70文字以内
- body は `.github/pull_request_template.md` に従う
- `Closes #<issue番号>` を必ず記載する
- セルフレビュー（`/review-pr`）後にレビュー依頼する
- CI（lint / typecheck / build）が全件グリーンになるまでマージしない
- 重要度「高」の指摘が残っている場合はマージしない

---

## マージ戦略

```bash
gh pr merge <PR番号> --squash --delete-branch
```

- **Squash merge** を使う。`main` のコミット履歴を意味のある単位に保つ
- マージ後はフィーチャーブランチを削除する
- Rebase merge・Merge commit は使わない

---

## 禁止操作

- `git push --force` / `git push -f` は `main` ブランチへは絶対禁止
- `git reset --hard` は確認なしに実行しない
- `git commit --amend` は push 済みのコミットに対して行わない
- `--no-verify` でフックをスキップしない
