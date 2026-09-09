#!/usr/bin/env bash
# loop-state.sh のテスト
#
# 重点はハードストップ。上限に達したら**必ず止まる**ことを機械で保証する。
# 「止まるはずだった」で済ませると、無限リトライでコストが死ぬ。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

trap cleanup_sandboxes EXIT

state_field() { # <jq のパス>
  jq -r "$1" "$SANDBOX_PROJ/.claude/memory/loop-state.json"
}

# ══════════════════════════════════════════════
suite "loop-state: 初期化"
# ══════════════════════════════════════════════

new_sandbox

it "init 前の gate は拒否される"
assert_fails loopstate gate G1 pass

it "init が状態ファイルを作る"
loopstate init 42 feat/42-search >/dev/null 2>&1
assert_file "$SANDBOX_PROJ/.claude/memory/loop-state.json"

it "init が Issue 番号を記録する"
assert_eq "$(state_field '.issue')" "42"

it "init が status を running にする"
assert_eq "$(state_field '.status')" "running"

it "init が epic を空で持つ（第3引数なし）"
assert_eq "$(state_field '.epic')" ""

it "init の第3引数で epic を記録する"
loopstate init 43 feat/43-x article-search >/dev/null 2>&1
assert_eq "$(state_field '.epic')" "article-search"

it "環境変数 LOOP_EPIC からも epic を拾う"
LOOP_EPIC=from-env loopstate init 44 feat/44-x >/dev/null 2>&1
assert_eq "$(state_field '.epic')" "from-env"

# ══════════════════════════════════════════════
suite "loop-state: ゲート結果の記録"
# ══════════════════════════════════════════════

new_sandbox
loopstate init 42 feat/42-search >/dev/null 2>&1

it "PASS を記録できる"
assert_ok loopstate gate G1 pass

it "記録した結果が読み出せる"
assert_eq "$(state_field '.gates.G1.result')" "pass"

it "FAIL の理由が保存される"
loopstate gate G2 fail "受け入れ条件 #2 が未達" >/dev/null 2>&1
assert_eq "$(state_field '.gates.G2.reason')" "受け入れ条件 #2 が未達"

it "不正なゲート名は拒否される"
assert_fails loopstate gate G9 pass

it "不正な結果は拒否される"
assert_fails loopstate gate G1 maybe

it "PASS すると同一ゲートの連続失敗カウントが戻る"
loopstate gate G2 pass >/dev/null 2>&1
assert_eq "$(state_field '.consecutive_gate_fail.G2')" "0"

# ══════════════════════════════════════════════
suite "loop-state: ハードストップ（最重要）"
# ══════════════════════════════════════════════

new_sandbox
LOOP_MAX_RETRY=3 loopstate init 42 feat/42-search >/dev/null 2>&1

it "上限未満の retry は続行できる"
assert_ok loopstate retry "1回目"

it "retry が加算される"
assert_eq "$(state_field '.retry')" "1"

it "retry でゲート結果がリセットされる（G1 からやり直すため）"
assert_eq "$(state_field '.gates')" "{}"

it "retry 上限に到達すると停止する"
loopstate retry "2回目" >/dev/null 2>&1
assert_fails loopstate retry "3回目"

it "上限到達で status が halted になる"
assert_eq "$(state_field '.status')" "halted"

it "halted 後の gate 記録は拒否される"
assert_fails loopstate gate G1 pass

it "halted 後の retry は拒否される"
assert_fails loopstate retry "4回目"

it "halted 後の check は exit 1 を返す"
assert_fails loopstate check

new_sandbox
LOOP_MAX_SAME_GATE_FAIL=2 loopstate init 42 feat/42-x >/dev/null 2>&1

it "同一ゲートの連続 FAIL が上限に達すると停止する"
loopstate gate G2 fail "1回目" >/dev/null 2>&1
assert_fails loopstate gate G2 fail "2回目"

it "その理由が halt_reason に残る"
assert_contains "$(state_field '.halt_reason')" "G2"

new_sandbox
LOOP_MAX_MINUTES=0 loopstate init 42 feat/42-x >/dev/null 2>&1

it "時間上限に到達すると停止する"
assert_fails loopstate check

# ══════════════════════════════════════════════
suite "loop-state: 完了と後始末"
# ══════════════════════════════════════════════

new_sandbox
loopstate init 42 feat/42-x >/dev/null 2>&1

it "complete で status が completed になる"
loopstate complete >/dev/null 2>&1
assert_eq "$(state_field '.status')" "completed"

it "clear で状態ファイルが消える"
loopstate clear >/dev/null 2>&1
assert_no_file "$SANDBOX_PROJ/.claude/memory/loop-state.json"

it "履歴が時系列で積まれる"
loopstate init 42 feat/42-x >/dev/null 2>&1
loopstate gate G1 pass >/dev/null 2>&1
loopstate retry "変更内容" >/dev/null 2>&1
assert_eq "$(state_field '.history | length')" "2"

report
