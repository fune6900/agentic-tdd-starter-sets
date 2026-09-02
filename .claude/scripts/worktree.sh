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

cmd_create() {
  local branch="${1:-}" base="${2:-main}"
  if [ -z "$branch" ]; then
    echo "ERROR: ブランチ名を指定しろ。" >&2; exit 1
  fi
  local dir="$WORKTREE_ROOT/$(slug "$branch")"

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
  [ -z "$branch" ] && { echo "ERROR: ブランチ名を指定しろ。" >&2; exit 1; }
  echo "$WORKTREE_ROOT/$(slug "$branch")"
}

cmd_remove() {
  local branch="${1:-}"
  [ -z "$branch" ] && { echo "ERROR: ブランチ名を指定しろ。" >&2; exit 1; }
  local dir="$WORKTREE_ROOT/$(slug "$branch")"

  if [ ! -d "$dir" ]; then
    echo "作業領域が存在しない: $dir"; exit 0
  fi

  # 未コミットの変更を巻き込んで消さない。
  if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    echo "ERROR: 未コミットの変更が残っている。マスターに確認せず消すな。" >&2
    git -C "$dir" status --short >&2
    exit 1
  fi

  git -C "$PROJECT_DIR" worktree remove "$dir" && echo "作業領域を削除した: $dir（ブランチ $branch は残っている）"
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
