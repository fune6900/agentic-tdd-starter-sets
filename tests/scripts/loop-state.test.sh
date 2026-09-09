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
suite "loop-state: 壊れた状態では止まる（fail closed）"
# ══════════════════════════════════════════════
# 空・不正な状態ファイルを黙って通すと、上限判定が全て素通りして
# ハードストップが無効化される。無限リトライでコストが死ぬ経路そのもの。

new_sandbox
loopstate init 42 feat/42-x >/dev/null 2>&1
: > "$SANDBOX_PROJ/.claude/memory/loop-state.json"

it "空の状態ファイルでは check が停止する"
assert_fails loopstate check

it "空の状態ファイルでは gate の記録も拒否される"
assert_fails loopstate gate G1 pass

it "空の状態ファイルでは retry も拒否される"
assert_fails loopstate retry "何か"

it "壊れている理由を報告する"
run loopstate check
assert_contains "$LAST_OUTPUT" "壊れている"

printf '{ "issue": ' > "$SANDBOX_PROJ/.claude/memory/loop-state.json"

it "途中で切れた JSON でも停止する"
assert_fails loopstate check

new_sandbox

it "上限の環境変数が整数でなければ既定へ倒す"
run env LOOP_MAX_RETRY=abc bash "$SANDBOX_PROJ/.claude/scripts/loop-state.sh" init 42 feat/42-x
assert_contains "$LAST_OUTPUT" "整数ではない"

it "既定へ倒した後も状態ファイルは妥当な JSON である"
assert_ok jq empty "$SANDBOX_PROJ/.claude/memory/loop-state.json"

it "既定へ倒した後もハードストップが機能する"
assert_eq "$(state_field '.limits.max_retry')" "3"

it "不正な上限で空の状態ファイルを残さない"
# jq が --argjson で落ちて 0 バイトのファイルが残ると、以後の判定が全て素通りする
assert_ok test -s "$SANDBOX_PROJ/.claude/memory/loop-state.json"

# ══════════════════════════════════════════════
suite "loop-state: 書き込み失敗を握り潰さない（G5 の回帰テスト）"
# ══════════════════════════════════════════════
# write_state が正しく拒否しても、呼び出し側が戻り値を捨てれば
# retry が永久に加算されず、リトライ上限が一切効かなくなる。

new_sandbox
loopstate init 42 feat/42-x >/dev/null 2>&1
chmod 500 "$SANDBOX_PROJ/.claude/memory"

it "状態を書けないとき retry は失敗する"
assert_fails loopstate retry "修正1"

it "状態を書けないとき gate も失敗する"
assert_fails loopstate gate G1 pass

it "状態を書けないとき complete も失敗する"
assert_fails loopstate complete

chmod 700 "$SANDBOX_PROJ/.claude/memory"

it "書けなかった分は加算されていない"
assert_eq "$(state_field '.retry')" "0"

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
