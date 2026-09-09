#!/usr/bin/env bash
# ワークツリー管理 — ループの「安全な作業環境」
#
# 複数エージェントが同じ場所を触って衝突するのを防ぐ。
# 失敗しても他に影響を与えず、何度でもやり直せる隔離領域を用意する。
#
# 使い方:
#   worktree.sh create <branch> [base]   ブランチ用の作業領域を作る（既定 base: main）
#   worktree.sh list                     作業領域の一覧
#   worktree.sh path <branch>            作業領域の絶対パスを表示
#   worktree.sh remove <branch>          作業領域を削除（ブランチは残す）
#   worktree.sh prune                    消えた作業領域の登録を掃除
#
# 作業領域の置き場所は既定で <リポジトリの親>/.worktrees/<repo名>/<branch をスラッシュ置換>
# LOOP_WORKTREE_ROOT で上書きできる。

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
REPO_NAME="$(basename "$PROJECT_DIR")"
WORKTREE_ROOT="${LOOP_WORKTREE_ROOT:-$(dirname "$PROJECT_DIR")/.worktrees/$REPO_NAME}"

slug() { echo "$1" | tr '/' '-'; }

# ブランチ名は作業領域のパスになる。'..' を通すと登録先がリポジトリの外へ出る。
# git-strategy.md の命名規則（英数字・kebab-case）に合わせて境界で弾く。
require_branch() {
  local b="${1:-}"
  [ -n "$b" ] || { echo "ERROR: ブランチ名を指定しろ。" >&2; exit 1; }
  case "$b" in
    *..*|-*|/*|*/)
      echo "ERROR: ブランチ名に使えない形式だ: '$b'" >&2
      echo "       '..' / 先頭のハイフン / 先頭・末尾のスラッシュは不可。" >&2
      exit 1
      ;;
  esac
  # grep は行単位で判定するため複数行入力をすり抜ける。case は文字列全体を見る。
  case "$b" in
    [!A-Za-z0-9]* | *[!A-Za-z0-9._/-]* )
      echo "ERROR: ブランチ名に使えない文字が入っている: '$b'" >&2
      echo "       英数字で始まり、英数字 . _ - / のみ使える（改行・空白は不可）。" >&2
      exit 1
      ;;
  esac
}

cmd_create() {
  local branch="${1:-}" base="${2:-main}"
  require_branch "$branch"
  require_branch "$base"
  local dir
  dir="$WORKTREE_ROOT/$(slug "$branch")"

  if [ -d "$dir" ]; then
    echo "既存の作業領域を再利用する: $dir"
    echo "$dir"
    return 0
  fi

  mkdir -p "$WORKTREE_ROOT"

  # base を最新化してから切る。古い base の上で作業させない。
  git -C "$PROJECT_DIR" fetch origin "$base" 2>/dev/null || true

  local start_point="origin/$base"
  git -C "$PROJECT_DIR" rev-parse --verify "$start_point" >/dev/null 2>&1 || start_point="$base"

  if git -C "$PROJECT_DIR" rev-parse --verify "$branch" >/dev/null 2>&1; then
    git -C "$PROJECT_DIR" worktree add "$dir" "$branch" || exit 1
  else
    git -C "$PROJECT_DIR" worktree add -b "$branch" "$dir" "$start_point" || exit 1
  fi

  echo "作業領域を作成した: $dir (branch=$branch base=$start_point)"
  echo "$dir"
}

cmd_list() { git -C "$PROJECT_DIR" worktree list; }

cmd_path() {
  local branch="${1:-}"
  require_branch "$branch"
  echo "$WORKTREE_ROOT/$(slug "$branch")"
}

cmd_remove() {
  local branch="${1:-}"
  require_branch "$branch"
  local dir
  dir="$WORKTREE_ROOT/$(slug "$branch")"

  if [ ! -d "$dir" ]; then
    echo "作業領域が存在しない: $dir"; exit 0
  fi

  # 未コミットの変更を巻き込んで消さない。
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo "ERROR: 未コミットの変更が残っている。マスターに確認せず消すな。" >&2
    git -C "$dir" status --short >&2
    exit 1
  fi

  git -C "$PROJECT_DIR" worktree remove "$dir" && echo "作業領域を削除した: ${dir}（ブランチ $branch は残っている）"
}

cmd_prune() { git -C "$PROJECT_DIR" worktree prune -v; }

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  list)   cmd_list ;;
  path)   shift; cmd_path "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  prune)  cmd_prune ;;
  *) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
