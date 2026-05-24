現在のブランチのPRをmainにマージし、ローカルをmainに切り替えて最新状態に同期する。以下の手順を厳守すること。

## 手順

### Phase 1: 事前確認

1. `git status` で未コミットの変更がないことを確認する。変更があればマスターに報告し、コミットするか中止するか確認する。
2. `git branch --show-current` で現在のブランチ名を取得する。
3. `gh pr list --head <現在のブランチ名> --json number,title,state` で対応する PR を特定する。PRが存在しない場合はマスターに報告して中止する。

### Phase 2: PR のマージ

1. 対象 PR の CI ステータスを確認する:

   ```bash
   gh pr checks <PR番号>
   ```

   CI が全件グリーンでない場合はマスターに警告し、続行するか確認する。

2. PR を Squash マージする:

   ```bash
   gh pr merge <PR番号> --squash --delete-branch
   ```

   - `--squash` でコミットを1つに圧縮する
   - `--delete-branch` でリモートのフィーチャーブランチを削除する

### Phase 3: main への切り替えと同期

1. main ブランチに切り替える:

   ```bash
   git checkout main
   ```

2. リモートの最新状態を取得する:

   ```bash
   git pull origin main
   ```

3. ローカルのフィーチャーブランチを削除する（リモートが削除済みの場合）:
   ```bash
   git branch -d <フィーチャーブランチ名>
   ```

### Phase 4: 完了報告

以下を報告する:

- マージされた PR 番号とタイトル
- 現在のブランチ（main）
- `git log --oneline -5` で最新5件のコミット履歴

## 注意

- CI が red のままマージしない。マスターが明示的に許可した場合のみ続行する。
- `--force` や `--no-verify` は絶対に使わない。
- マージ後は必ず `git pull` で最新状態にしてから完了を報告する。
