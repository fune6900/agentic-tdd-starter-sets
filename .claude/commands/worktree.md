git worktree で**安全な作業環境**を用意・撤収する。ループの「失敗しても他に影響を与えず、何度でもやり直せる環境」の実体。

## 対象

- 引数 $ARGUMENTS に `create <branch> [base]` / `list` / `path <branch>` / `remove <branch>` / `prune` を指定する。
- 未指定の場合は `list` を実行して現状を報告する。

## なぜ必要か

複数のエージェントが同じ作業ディレクトリを触ると衝突する。
また、失敗が本体の作業ツリーを汚すと「何度でもやり直せる」環境が失われる。
**作業領域を物理的に分離することで、ジュニアが失敗しても全体が壊れない状態を作る。**

---

## 手順

### 作成

```bash
bash .claude/scripts/worktree.sh create feat/42-article-search
```

- ベースブランチ（既定 `main`）を `git fetch` してから切るため、古い base の上で作業しない
- 既にブランチが存在する場合はそれを使う。存在しなければ base から新規作成する
- 出力の最終行が作業領域の絶対パス。以降の作業はそのディレクトリで行う

作成後の初期化（対象プロジェクトに `package.json` がある場合）:
```bash
cd <作業領域のパス>
npm ci   # または npm install
```

> `node_modules` は worktree 間で共有されない。作業領域ごとにインストールが必要。

### 一覧・パス確認

```bash
bash .claude/scripts/worktree.sh list
bash .claude/scripts/worktree.sh path feat/42-article-search
```

### 撤収

PR がマージされた後に実行する:

```bash
bash .claude/scripts/worktree.sh remove feat/42-article-search
bash .claude/scripts/worktree.sh prune
```

- **未コミットの変更が残っている場合、スクリプトが削除を拒否する**。中身を確認してマスターに報告すること
- ブランチ自体は削除されない。ブランチの削除は `gh pr merge --delete-branch` に任せる

---

## 並列実行のルール

複数の Issue を同時に流す場合:

- **依存関係のある Issue を並列にしない。** 領域を分離しても依存の破綻は防げない
- 同じファイルを触る可能性が高い Issue も並列にしない（マージ地獄になる）
- 並列数は3本まで。それ以上はレビュー側（人間）が追随できない
- 各作業領域で `loop-state.sh` の状態ファイルは独立する（`.claude/memory/loop-state.json` は worktree ごとに別物）

---

## 報告フォーマット

```
## ワークツリー: <操作>

### 結果
- ブランチ: <branch>
- 作業領域: <絶対パス>
- ベース: origin/main (<短縮ハッシュ>)

### 現在の作業領域一覧
（worktree list の出力）
```

## 注意

- 作業領域はリポジトリ**外**（既定で `<リポジトリの親>/.worktrees/<repo名>/`）に作られる。リポジトリ内に作らない
- `LOOP_WORKTREE_ROOT` 環境変数で置き場所を変更できる
- 未コミットの変更がある作業領域を強制削除しない。マスターの明示的な許可が必要
- 作業領域を作りっぱなしにしない。マージ後は必ず撤収する
