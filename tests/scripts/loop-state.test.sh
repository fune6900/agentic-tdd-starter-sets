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


# ══════════════════════════════════════════════
suite "loop-state: 経過時間からスリープを除く（#32）"
# ══════════════════════════════════════════════
# 取得源は PATH 上の perl（起きていた時間）と sysctl / uname（起動 ID）。
# テスト用の環境変数ノブは本番の抜け道になるので作らない。
# 偽のコマンドをサンドボックス内の bin に置き、PATH の先頭で差し替える。
# サンドボックスごと cleanup_sandboxes が消すので個別の後片付けは要らない。

FAKE=""
STATE_JSON=""

# 偽の perl / sysctl / uname を作る。値は $FAKE/awake と $FAKE/boot から読む。
# ファイルが無ければ偽コマンドは exit 1（コマンドが使えない環境の再現）。
fake_setup() {
  FAKE="$SANDBOX_ROOT/fake"
  STATE_JSON="$SANDBOX_PROJ/.claude/memory/loop-state.json"
  mkdir -p "$FAKE/bin"
  cat > "$FAKE/bin/perl" <<EOF
#!/bin/bash
[ -f '${FAKE}/awake' ] || exit 1
cat '${FAKE}/awake'
EOF
  # sysctl は引数で答えを変える。bootsessionuuid は $FAKE/boot の中身、それ以外は exit 1。
  # kern.boottime の分岐は回帰用。本体は kern.boottime を読まない（時刻補正で usec が変わるため）。
  # 呼ぶたびに usec が変わる値を返し、同じ起動中の時刻補正を再現する。
  cat > "$FAKE/bin/sysctl" <<EOF
#!/bin/bash
case "\${1:-} \${2:-}" in
  '-n kern.bootsessionuuid') [ -f '${FAKE}/boot' ] || exit 1; cat '${FAKE}/boot' ;;
  '-n kern.boottime')
    n=\$(cat '${FAKE}/bt' 2>/dev/null || echo 0)
    n=\$((n + 1))
    echo "\$n" > '${FAKE}/bt'
    echo "{ sec = 1700000000, usec = \${n} }"
    ;;
  *) exit 1 ;;
esac
EOF
  cat > "$FAKE/bin/uname" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-s" ]; then echo Darwin; else exec /usr/bin/uname "$@"; fi
EOF
  chmod +x "$FAKE/bin/perl" "$FAKE/bin/sysctl" "$FAKE/bin/uname"
}

set_awake() { printf '%s\n' "$1" > "$FAKE/awake"; }
set_boot() { printf '%s\n' "$1" > "$FAKE/boot"; }

# 偽コマンドを PATH の先頭に置いて loop-state.sh を実行する
fakestate() { PATH="$FAKE/bin:$PATH" loopstate "$@"; }

# 状態ファイルを jq で書き換える
edit_state() { # <jq フィルタ> [jq の引数...]
  local filter="$1"; shift
  jq "$@" "$filter" "$STATE_JSON" > "$SANDBOX_ROOT/state.tmp" && mv "$SANDBOX_ROOT/state.tmp" "$STATE_JSON"
}

# 壁時計だけ 120 分進めた状態にする（スリープ込みの経過の再現）
backdate_wall() { edit_state '.started_epoch = $e' --argjson e "$(( $(date -u +%s) - 7200 ))"; }

# サンドボックス + 偽コマンド + init（上限60分・awake=1000・BOOT-A）+ 壁時計 120 分経過
new_awake_case() {
  new_sandbox
  fake_setup
  set_awake 1000
  set_boot "UUID-A"
  LOOP_MAX_MINUTES=60 fakestate init 32 feat/32-x >/dev/null 2>&1
  backdate_wall
}

# 壁時計に倒れる 1 ケース: show は wall で 120 分、check は停止する
expect_wall_fallback() { # <ラベル>
  it "$1: show の elapsed_source が wall"
  run fakestate show
  assert_eq "$(printf '%s' "$LAST_OUTPUT" | jq -r '.elapsed_source')" "wall"
  it "$1: show の elapsed_minutes が壁時計の 120 分"
  assert_eq "$(printf '%s' "$LAST_OUTPUT" | jq -r '.elapsed_minutes')" "120"
  it "$1: 壁時計 120 分・上限 60 分で check が停止する"
  assert_fails fakestate check
  it "$1: status が halted になる"
  assert_eq "$(jq -r '.status' "$STATE_JSON")" "halted"
}

# --- 1. init の記録 ---
new_sandbox
fake_setup
set_awake 4242
set_boot "UUID-A"
fakestate init 32 feat/32-x >/dev/null 2>&1

it "init が起きていた時間の基準値 awake_start を整数で記録する"
assert_eq "$(state_field '.awake_start')" "4242"

it "init が記録する boot_id は kern.bootsessionuuid の値である"
assert_eq "$(state_field '.boot_id')" "UUID-A"

it "init は壁時計の started_epoch も残す"
case "$(state_field '.started_epoch')" in
  ''|null|*[!0-9]*) fail "started_epoch が整数ではない" ;;
  *) pass ;;
esac

rm -f "$FAKE/awake"
fakestate init 32 feat/32-x >/dev/null 2>&1

it "perl が使えないとき init は awake_start を null にする"
assert_eq "$(state_field '.awake_start')" "null"

it "perl が使えなくても init は boot_id を記録する"
assert_eq "$(state_field '.boot_id')" "UUID-A"

set_awake 4242
rm -f "$FAKE/boot"
fakestate init 32 feat/32-x >/dev/null 2>&1

it "起動 ID が取れないとき init は boot_id を null にする"
assert_eq "$(state_field '.boot_id')" "null"

# --- 2. 壁時計 120 分・起きていた時間 30 分 ---
new_awake_case
set_awake $((1000 + 1800))

it "壁時計 120 分でも起きていた時間が 30 分なら check は OK"
assert_ok fakestate check

it "OK 行に起きていた時間で数えたことが出る"
assert_contains "$LAST_OUTPUT" "起きていた時間"

it "show の elapsed_source が awake になる"
run fakestate show
assert_eq "$(printf '%s' "$LAST_OUTPUT" | jq -r '.elapsed_source')" "awake"

it "show の elapsed_minutes が起きていた時間の 30 分になる"
assert_eq "$(printf '%s' "$LAST_OUTPUT" | jq -r '.elapsed_minutes')" "30"

it "show の wall_elapsed_minutes が壁時計の 120 分を示す"
assert_eq "$(printf '%s' "$LAST_OUTPUT" | jq -r '.wall_elapsed_minutes')" "120"

it "check が OK のとき status は running のまま"
assert_eq "$(state_field '.status')" "running"

# --- 3. 起きていた時間が上限に到達 ---
new_awake_case
set_awake $((1000 + 3600))

it "起きていた時間が上限 60 分に到達すると check が停止する"
assert_fails fakestate check

it "起きていた時間で停止したとき status が halted になる"
assert_eq "$(state_field '.status')" "halted"

it "停止理由に起きていた時間で数えたことが出る"
assert_contains "$(state_field '.halt_reason')" "起きていた時間"

# --- 4/5. 壁時計に倒れるケース ---
new_awake_case
rm -f "$FAKE/awake"
expect_wall_fallback "perl が使えない"

new_awake_case
: > "$FAKE/awake"
expect_wall_fallback "出力が空"

new_awake_case
set_awake "abc"
expect_wall_fallback "非数値 abc"

new_awake_case
set_awake "1.5e3"
expect_wall_fallback "指数表記 1.5e3"

new_awake_case
printf '12\n34\n' > "$FAKE/awake"
expect_wall_fallback "複数行 12 と 34"

new_awake_case
set_awake 500
expect_wall_fallback "現在値が awake_start より小さい（再起動）"

new_awake_case
set_awake 1000
set_boot "UUID-B"
expect_wall_fallback "起動 ID が変わった"

new_awake_case
set_awake $((1000 + 7200 + 600))  # 差分 7800 秒 > 壁時計 7200 + 60 秒なので壁時計に倒れる（数秒遅れても反転しない）
expect_wall_fallback "起きていた時間の差分が壁時計 + 60 秒を超える"

new_awake_case
edit_state 'del(.awake_start)'
set_awake 1000
expect_wall_fallback "awake_start が無い旧形式"

new_awake_case
set_awake abc

it "壁時計に倒れて停止したとき停止理由に壁時計で数えたことが出る"
fakestate check >/dev/null 2>&1
assert_contains "$(state_field '.halt_reason')" "壁時計"

# --- 6. 境界: 起きていた時間で数える側 ---
new_awake_case
set_awake $((1000 + 7200 + 60))

it "差分が壁時計の差分 + 60 秒ちょうどなら起きていた時間で数える（境界）"
run fakestate show
assert_eq "$(printf '%s' "$LAST_OUTPUT" | jq -r '.elapsed_source')" "awake"

new_awake_case
set_awake 1000

it "現在値が awake_start と等しいなら起きていた時間で数える（境界）"
run fakestate show
assert_eq "$(printf '%s' "$LAST_OUTPUT" | jq -r '.elapsed_source')" "awake"

# --- 7. 回帰: 同じ起動中に kern.boottime の usec が変わっても起きていた時間で数える ---
new_awake_case
set_awake $((1000 + 1800))
run fakestate show
run fakestate show

it "kern.boottime の usec が呼ぶたびに変わっても elapsed_source は awake のまま"
run fakestate show
assert_eq "$(printf '%s' "$LAST_OUTPUT" | jq -r '.elapsed_source')" "awake"

it "kern.boottime の usec が変わっても check は起きていた時間 30 分で OK"
assert_ok fakestate check

it "init の boot_id は kern.boottime の出力を含まない"
case "$(state_field '.boot_id')" in
  *sec*) fail "boot_id に kern.boottime が混入している: '$(state_field '.boot_id')'" ;;
  *) pass ;;
esac

# --- 8. 実機の perl（偽物なし） ---
new_sandbox
loopstate init 32 feat/32-x >/dev/null 2>&1

it "実機の perl があれば awake_start は整数、無ければ null"
real_awake="$(state_field '.awake_start')"
if command -v perl >/dev/null 2>&1; then
  case "$real_awake" in
    ''|null|*[!0-9]*) fail "perl があるのに awake_start が整数ではない: '${real_awake}'" ;;
    *) pass ;;
  esac
else
  assert_eq "$real_awake" "null"
fi

report
