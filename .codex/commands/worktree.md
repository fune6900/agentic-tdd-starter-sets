# worktree（安全な作業環境）

git worktree で作業領域を分離する。失敗が本体を汚さず、何度でもやり直せる状態を作る。

## 手順

```bash
bash .claude/scripts/worktree.sh create <branch> [base]   # 作成（既定 base: main）
bash .claude/scripts/worktree.sh list                     # 一覧
bash .claude/scripts/worktree.sh path <branch>            # パス確認
bash .claude/scripts/worktree.sh remove <branch>          # 撤収
bash .claude/scripts/worktree.sh prune                    # 掃除
```

作成後、対象プロジェクトに `package.json` があれば作業領域内で `npm ci` を実行する
（`node_modules` は worktree 間で共有されない）。

## 並列実行のルール

- 依存関係のある Issue を並列にしない
- 同じファイルを触る可能性が高い Issue も並列にしない
- 並列数は3本まで

## Codex 注意点

- 未コミットの変更がある作業領域を強制削除しない。スクリプトが拒否したら中身を確認して報告する。
- 作業領域はリポジトリ外に作られる（`LOOP_WORKTREE_ROOT` で変更可）。
- マージ後は必ず撤収する。作りっぱなしにしない。
