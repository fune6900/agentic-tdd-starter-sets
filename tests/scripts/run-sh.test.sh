#!/usr/bin/env bash
# tests/run.sh 自身のテスト（スイート除外: RUN_EXCLUDE）
#
# Issue #20 / PR #30: CI の tests ジョブと専用ジョブでスモークが二重に走っていた。
# tests ジョブだけが RUN_EXCLUDE=<スイート名> で外せるようにする。
# run.sh を検査する既存スイートが無かったため新規に置く（他のスイートの関心事ではない）。
#
# 契約:
#   - RUN_EXCLUDE はスペース区切りのスイート名。完全一致で除外（部分一致にしない）
#   - 未設定・空なら従来どおり全件
#   - 存在しないスイート名は FAIL（タイプミスで除外が効かないまま気付かない事態を防ぐ。lessons #10）
#   - 使える文字は英数字と . _ - のみ（改行・* ・/・, ; タブ等は拒否）。拒否時は 1 件も実行しない
#   - エラーは標準エラーに RUN_EXCLUDE を含むメッセージを出し、非 0 で終わる
#   - 全部除外されて 0 件なら既存どおり FAIL

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

REAL_RUN_SH="$REPO_ROOT/tests/run.sh"
trap cleanup_sandboxes EXIT

# 偽リポジトリ（ダミースイートだけ）を作る
BOX="$(mktemp -d)" || exit 1
SANDBOXES+=("$BOX")
mkdir -p "$BOX/tests/scripts"
for n in a ab b-smoke; do
  printf '#!/usr/bin/env bash\necho "RAN:%s"\n' "$n" > "$BOX/tests/scripts/$n.test.sh"
done

# rs <RUN_EXCLUDE の値 | __UNSET__> [フィルタ]  → 出力は ${LAST_OUTPUT}、終了コードを返す
rs() {
  local ex="$1"; shift
  if [ "$ex" = "__UNSET__" ]; then
    LAST_OUTPUT="$(env -u RUN_EXCLUDE REPO_ROOT="$BOX" bash "$REAL_RUN_SH" "$@" 2>&1)"
  else
    LAST_OUTPUT="$(env REPO_ROOT="$BOX" RUN_EXCLUDE="$ex" bash "$REAL_RUN_SH" "$@" 2>&1)"
  fi
}

ran_list() { printf '%s\n' "$LAST_OUTPUT" | grep -o '^RAN:.*' | sort | tr '\n' ' '; }

# ══════════════════════════════════════════════
suite "run.sh: 変数未設定・空なら従来どおり全件"
# ══════════════════════════════════════════════

it "RUN_EXCLUDE 未設定で全スイートが走る"
rs __UNSET__; rc=$?
assert_eq "$rc:$(ran_list)" "0:RAN:a RAN:ab RAN:b-smoke "

it "RUN_EXCLUDE が空文字でも全スイートが走る"
rs ""; rc=$?
assert_eq "$rc:$(ran_list)" "0:RAN:a RAN:ab RAN:b-smoke "

# ══════════════════════════════════════════════
suite "run.sh: 完全一致での除外"
# ══════════════════════════════════════════════

it "指定したスイートだけが除外される"
rs "b-smoke"; rc=$?
assert_eq "$rc:$(ran_list)" "0:RAN:a RAN:ab "

it "a を除外しても部分一致で ab は除外されない"
rs "a"; rc=$?
assert_eq "$rc:$(ran_list)" "0:RAN:ab RAN:b-smoke "

it "スペース区切りで複数を除外できる"
rs "a b-smoke"; rc=$?
assert_eq "$rc:$(ran_list)" "0:RAN:ab "

it "余分なスペース（連続・前後）は許容する"
rs "  a   b-smoke "; rc=$?
assert_eq "$rc:$(ran_list)" "0:RAN:ab "

it "除外したスイートは実行されない（RAN:a が出力に無い）"
rs "a"
case "$LAST_OUTPUT" in *"RAN:a"$'\n'*) fail "a が走った" ;; *) pass ;; esac

# ══════════════════════════════════════════════
suite "run.sh: 判定不能は FAIL（存在しない名前・不正な値）"
# ══════════════════════════════════════════════

it "存在しないスイート名の除外指定は非 0 で終わり、1 件も実行しない"
rs "monitor-image-smok"; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo nonzero):$(ran_list)" "nonzero:"

it "存在しない名前のエラーは RUN_EXCLUDE に言及する"
rs "a typo-suite"
assert_contains "$LAST_OUTPUT" "RUN_EXCLUDE"
it "存在しない名前のエラーに該当名が載る"
assert_contains "$LAST_OUTPUT" "typo-suite"

it "実在する名前と存在しない名前が混在していても FAIL（実在分だけ除外して続行しない）"
rs "a nope"; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo nonzero):$(ran_list)" "nonzero:"

it "接尾辞 .test.sh 付きの指定は拒否する（名前は拡張子抜き）"
rs "a.test.sh"; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo nonzero):$(ran_list)" "nonzero:"

bad_value() { # <説明> <値>
  it "不正な値を拒否する: $1"
  rs "$2"; local rc=$?
  assert_eq "$([ "$rc" -ne 0 ] && echo nonzero):$(ran_list)" "nonzero:"
}
bad_value "改行区切り" $'a\nb-smoke'
bad_value "末尾の改行に隠した名前" $'a\nab'
bad_value "ワイルドカード *" '*'
bad_value "ワイルドカード a*" 'a*'
bad_value "ワイルドカード ?" 'a?'
bad_value "パス区切り /" 'tests/scripts/a'
bad_value "パス上位参照" '../a'
bad_value "カンマ区切り" 'a,b-smoke'
bad_value "セミコロン区切り" 'a;b-smoke'
bad_value "タブ区切り" $'a\tb-smoke'
bad_value "クォート" "'a'"
bad_value "コマンド置換" '$(echo a)'
bad_value "先頭ハイフン" '-a'

it "不正な値のエラーは RUN_EXCLUDE に言及する"
rs 'a,b-smoke'
assert_contains "$LAST_OUTPUT" "RUN_EXCLUDE"

# ══════════════════════════════════════════════
suite "run.sh: フィルタ引数との併用・0 件"
# ══════════════════════════════════════════════

it "フィルタ a（部分一致で a と ab）から a を除外すると ab だけ走る"
rs "a" a; rc=$?
assert_eq "$rc:$(ran_list)" "0:RAN:ab "

it "フィルタに掛からない実在スイートの除外指定でも FAIL しない"
rs "b-smoke" a; rc=$?
assert_eq "$rc:$(ran_list)" "0:RAN:a RAN:ab "

it "フィルタに掛からない存在しない名前は FAIL（検証は全スイートに対して行う）"
rs "nope" a; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo nonzero):$(ran_list)" "nonzero:"

it "全部除外されて 0 件なら既存どおり FAIL（実行対象のテストが無い）"
rs "a ab b-smoke"; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo nonzero):$(ran_list)" "nonzero:"
it "0 件 FAIL のメッセージは既存のまま"
assert_contains "$LAST_OUTPUT" "実行対象のテストが無い"

it "フィルタ結果が除外で空になっても FAIL"
rs "b-smoke" b-smoke; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo nonzero):$(ran_list)" "nonzero:"

# ══════════════════════════════════════════════
suite "run.sh: 除外しても失敗は握りつぶさない"
# ══════════════════════════════════════════════

printf '#!/usr/bin/env bash\necho "RAN:bad"\nexit 1\n' > "$BOX/tests/scripts/bad.test.sh"

it "除外していない失敗スイートがあれば FAIL する"
rs "a"; rc=$?
assert_eq "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero"

it "失敗スイートを除外すれば他は PASS する（除外は名前だけに効く）"
rs "bad"; rc=$?
assert_eq "$rc" "0"
rm -f "$BOX/tests/scripts/bad.test.sh"

report
