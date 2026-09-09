#!/usr/bin/env bash
# worktree.sh のテスト
#
# 重点は「ブランチ名が作業領域のパスになる」こと。
# 検証を欠くと、リポジトリの外に作業領域を作り、`remove` でそれを消しに行く。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

trap cleanup_sandboxes EXIT

setup_wt() {
  new_sandbox
  cp "$REPO_ROOT/.claude/scripts/worktree.sh" "$SANDBOX_PROJ/.claude/scripts/"
  export LOOP_WORKTREE_ROOT="$SANDBOX_ROOT/worktrees"
  ( cd "$SANDBOX_PROJ" \
      && git -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init ) || true
}

wt() { bash "$SANDBOX_PROJ/.claude/scripts/worktree.sh" "$@"; }

# ══════════════════════════════════════════════
suite "worktree: ブランチ名の検証（パスになる値）"
# ══════════════════════════════════════════════

setup_wt

it "正当なブランチ名は通る"
assert_ok wt path "feat/12-article-search"

it "スラッシュは '-' に潰される"
run wt path "feat/12-search"
assert_contains "$LAST_OUTPUT" "feat-12-search"

it "空のブランチ名は拒否される"
assert_fails wt path ""

it "'..' を含むブランチ名は拒否される"
assert_fails wt path "../../escaped"

it "'..' そのものは拒否される"
assert_fails wt path ".."

it "先頭ハイフンは拒否される（オプションと誤認されうる）"
assert_fails wt path "--force"

it "先頭スラッシュは拒否される"
assert_fails wt path "/etc/passwd"

it "末尾スラッシュは拒否される"
assert_fails wt path "feat/"

it "空白を含むブランチ名は拒否される"
assert_fails wt path "feat/my branch"

it "複数行のブランチ名は拒否される"
# grep は行単位で判定するため、1行目が正当なら通ってしまっていた（回帰テスト）
assert_fails wt path "$(printf 'ok\nevil')"

it "複数行でも作業領域のパスを生成していない"
run wt path "$(printf 'ok\nevil')"
case "$LAST_OUTPUT" in
  *worktrees*) fail "拒否されずにパスを生成した" "出力: $LAST_OUTPUT" ;;
  *) pass ;;
esac

it "シェルの展開を含む文字列は拒否される"
assert_fails wt path '$(id)'

it "create でも base を検証する"
assert_fails wt create "feat/ok" "../evil"

it "remove でもブランチ名を検証する"
assert_fails wt remove "../../escaped"

# ══════════════════════════════════════════════
suite "worktree: パスの決定"
# ══════════════════════════════════════════════

setup_wt

it "LOOP_WORKTREE_ROOT を尊重する"
run wt path "feat/1-x"
assert_contains "$LAST_OUTPUT" "$SANDBOX_ROOT/worktrees"

it "同じブランチ名からは同じパスを返す（冪等）"
a="$(wt path "feat/1-x")"
b="$(wt path "feat/1-x")"
assert_eq "$b" "$a"

it "引数なしの呼び出しは使い方を表示して失敗する"
assert_fails wt

# ══════════════════════════════════════════════
suite "worktree: 作成と撤収"
# ══════════════════════════════════════════════

setup_wt

it "作業領域を作成できる"
assert_ok wt create "feat/9-probe"

it "作成した作業領域が実在する"
assert_ok test -d "$(wt path "feat/9-probe")"

it "既存の作業領域は再利用する（冪等）"
run wt create "feat/9-probe"
assert_contains "$LAST_OUTPUT" "再利用"

it "list に作成した作業領域が出る"
run wt list
assert_contains "$LAST_OUTPUT" "feat-9-probe"

it "未コミットの変更があれば撤収を拒否する"
printf 'dirty\n' > "$(wt path "feat/9-probe")/dirty.txt"
assert_fails wt remove "feat/9-probe"

it "拒否されたので作業領域は残っている"
assert_ok test -d "$(wt path "feat/9-probe")"

it "変更を片付ければ撤収できる"
rm -f "$(wt path "feat/9-probe")/dirty.txt"
assert_ok wt remove "feat/9-probe"

it "撤収後は作業領域が消えている"
assert_fails test -d "$(wt path "feat/9-probe")"

it "存在しない作業領域の撤収は異常終了しない"
assert_ok wt remove "feat/99-nonexistent"

report
