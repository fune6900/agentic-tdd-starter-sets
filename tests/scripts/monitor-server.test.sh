#!/usr/bin/env bash
# .claude/monitor/server（受信サーバ）のテスト（Issue #19 / Red）
#
# 本体は node:test（.claude/monitor/test/*.test.mjs）。このスクリプトはそれを bash tests/run.sh から回す橋渡しと、
# node では検査できないもの（node の有無・security.md の記述・CI の Node 用意）を受け持つ。
#
# ── 設計メモ ──────────────────────────────────────────────────────────────
#   - node が無い（または node:sqlite をフラグ無しで使えない古い版）場合は **スキップではなく FAIL**（lessons #10 / 受け入れ条件）。
#     判定ロジックは node_gate / node_version_ok に切り出し、PATH から node を外した自己診断で縛る
#   - `node --test <ディレクトリ>` は Node 22.22 で「ディレクトリをファイルとして require して失敗」する（実測）。
#     受け入れ条件の字面（`node --test .claude/monitor/test/`）は動かないので、glob で渡す。glob が空なら FAIL
#   - 実行環境の MONITOR_BIND / LOOP_MONITOR_PORT / MONITOR_DB を外してから走らせる（開発中の実サーバや
#     ユーザーの設定を拾わない）。DB は node 側がテストごとに一時ディレクトリへ作る
#   - security.md の節は awk で抜き出し、判定は case（lessons #10: grep は行単位なので複数行入力・見出し以外に誤爆する）
#   - 変異テスト対応表は .claude/monitor/test/server.test.mjs の冒頭コメント
#
# ── security.md「監視の限界（受信側）」の契約（Coder が書く。見出しと語はここで固定）──────────
#   ## 監視の限界（受信側）                ← 「## 監視の限界（送信側）」節の後ろ
#     ### 受け付ける入力 / ### 止める仕組み / ### 既知の限界
#   止める仕組み: fail closed / Host / Origin / Content-Type / 64KB / Access-Control-Allow-Origin /
#                 127.0.0.1 / MONITOR_BIND / プレースホルダ / ログ
#                 （G5 retry 1 で追加）Sec-Fetch-Site / same-origin / シンボリックリンク / lstat / 0700 / 0600
#   既知の限界:   認証 / 同一端末 / 書き込み / 読み出し / セキュリティ境界ではない / known_limit_local_process_can_write

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

cd "$REPO_ROOT" || exit 1

trap cleanup_sandboxes EXIT

TEST_DIR=".claude/monitor/test"
SECURITY_MD=".claude/rules/security.md"
CI_YML=".github/workflows/template-ci.yml"
MIN_NODE_TESTS=120

# 部分文字列の包含（失敗時に対象全文を吐かない。長い節・ジョブでログが埋まるため）
assert_has() { # <対象> <部分文字列>
  case "$1" in
    *"$2"*) pass ;;
    *) fail "'$2' が無い（対象 ${#1} 字）" ;;
  esac
}

# ---------- node の前提 ----------

# <バージョン文字列> が node:sqlite をフラグ無しで使える版（22.13 以上）なら 0。判定不能は 1（fail closed）
node_version_ok() {
  local ver="$1" major rest minor
  case "$ver" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) return 1 ;;
  esac
  major="${ver%%.*}"
  rest="${ver#*.}"
  minor="${rest%%.*}"
  case "$major$minor" in
    *[!0-9]*) return 1 ;;
  esac
  if [ "$major" -gt 22 ]; then return 0; fi
  if [ "$major" -eq 22 ] && [ "$minor" -ge 13 ]; then return 0; fi
  return 1
}

# node が PATH にあり、版が足りるなら 0。そうでなければ理由を出して 1
node_gate() {
  local ver
  if ! command -v node >/dev/null 2>&1; then
    echo "node が PATH に無い。スキップせず FAIL 扱いにする"
    return 1
  fi
  ver="$(node -p 'process.versions.node' 2>/dev/null)" || { echo "node のバージョンを取得できない"; return 1; }
  if ! node_version_ok "$ver"; then
    echo "node ${ver} は node:sqlite をフラグ無しで使えない（22.13 以上が必要）"
    return 1
  fi
  return 0
}

# node:test スイートを全て走らせる。stdout は TAP。失敗は非 0
run_node_tests() {
  local files=() f
  node_gate || return 1
  for f in "$TEST_DIR"/*.test.mjs; do
    [ -e "$f" ] && files+=("$f")
  done
  if [ "${#files[@]}" -eq 0 ]; then
    echo "$TEST_DIR に *.test.mjs が1つも無い"
    return 1
  fi
  env -u MONITOR_BIND -u LOOP_MONITOR_PORT -u MONITOR_DB -u LOOP_MONITOR NODE_NO_WARNINGS=1 \
    node --test --test-reporter=tap "${files[@]}"
}

# TAP 出力から `# <key> N` の N を取り出す（無ければ空）
tap_count() { # <出力> <key>
  printf '%s\n' "$1" | sed -n "s/^# $2 \([0-9][0-9]*\)\$/\1/p" | tail -n 1
}

# 見出し行（完全一致）から次の `## ` までを出す
md_section() { # <ファイル> <見出し>
  awk -v h="$2" '$0 == h { p = 1; next } p && /^## / { exit } p { print }' "$1"
}

# 節の本文から `### <名前>` 小節を出す
md_subsection() { # <見出し名>（stdin: 節の本文）
  awk -v h="### $1" '$0 == h { p = 1; next } p && /^### / { exit } p { print }'
}

# CI のジョブ（`  <name>:` 行から次のジョブまで）
ci_job() { # <ジョブ名>
  awk -v j="  $1:" '$0 == j { p = 1; print; next } p && /^  [A-Za-z0-9_-]+:$/ { exit } p { print }' "$CI_YML"
}

# ══════════════════════════════════════════════
suite "monitor-server: 前提（node。無ければ FAIL）"
# ══════════════════════════════════════════════

it "node が PATH にあり、node:sqlite をフラグ無しで使える版（22.13 以上）である"
GATE_MSG="$(node_gate 2>&1)"
GATE_RC=$?
if [ "$GATE_RC" -eq 0 ]; then pass; else fail "$GATE_MSG"; fi

it "[自己診断] node_version_ok: 22.13 以上は通り、それ未満・判定不能は拒否する"
bad=""
for v in 22.13.0 22.22.0 23.0.0 24.1.2 25.0.0; do node_version_ok "$v" || bad="$bad 通るべき:$v"; done
for v in 22.12.9 22.0.0 21.9.9 20.19.0 "" abc 22 22.x.1 v22.13.0 -22.13.0 22.13; do
  if node_version_ok "$v"; then bad="$bad 拒否すべき:'$v'"; fi
done
assert_eq "$bad" ""

it "[自己診断] PATH から node を外すと node_gate は FAIL（1）を返す。スキップにならない"
EMPTY_BIN="$(mktemp -d)" || { echo "mktemp に失敗した" >&2; exit 1; }
SANDBOXES+=("$EMPTY_BIN")
( PATH="$EMPTY_BIN"; node_gate >/dev/null 2>&1 )
assert_eq "$?" "1"

it "[自己診断] PATH から node を外すと run_node_tests は FAIL（1）を返す"
( PATH="$EMPTY_BIN"; run_node_tests >/dev/null 2>&1 )
assert_eq "$?" "1"

if [ "$GATE_RC" -ne 0 ]; then
  report
  exit 1
fi

# ══════════════════════════════════════════════
suite "monitor-server: node:test スイート（.claude/monitor/test）"
# ══════════════════════════════════════════════

for f in validate derive store server server-reject server-security server-fetch-site server-dbpath sse static; do
  it "テストファイル ${f}.test.mjs が存在する"
  assert_file "$TEST_DIR/$f.test.mjs"
done

NODE_OUT="$(run_node_tests 2>&1)"
NODE_RC=$?

it "node --test が全件 PASS する（終了コード 0）"
if [ "$NODE_RC" -eq 0 ]; then
  pass
else
  fail "終了コード $NODE_RC" "$(printf '%s\n' "$NODE_OUT" | grep -E '^ *not ok' | head -n 15)"
fi

NODE_TESTS="$(tap_count "$NODE_OUT" tests)"
NODE_FAILS="$(tap_count "$NODE_OUT" fail)"

it "node のテスト件数が下限（${MIN_NODE_TESTS}）以上（空振り・ファイル欠落で PASS させない）"
case "$NODE_TESTS" in
  ''|*[!0-9]*) fail "件数を読み取れない: '$NODE_TESTS'" ;;
  *) if [ "$NODE_TESTS" -ge "$MIN_NODE_TESTS" ]; then pass; else fail "件数が少ない: $NODE_TESTS < $MIN_NODE_TESTS"; fi ;;
esac

it "node のテストに失敗・キャンセルが無い"
NODE_CANCELLED="$(tap_count "$NODE_OUT" cancelled)"
assert_eq "${NODE_FAILS:-?}/${NODE_CANCELLED:-?}" "0/0"

it "既知の限界テスト known_limit_local_process_can_write が存在し PASS している（TAP の ok 行を観測）"
# 検証ではなく観測なので行単位の grep でよい（先頭の空白はサブテストのインデント）
KL_OK="$(printf '%s\n' "$NODE_OUT" | grep -cE '^ *ok [0-9]+ - known_limit_local_process_can_write')"
KL_NG="$(printf '%s\n' "$NODE_OUT" | grep -cE '^ *not ok [0-9]+ - known_limit_local_process_can_write')"
assert_eq "$KL_OK/$KL_NG" "1/0"

# ══════════════════════════════════════════════
suite "monitor-server: security.md「監視の限界（受信側）」"
# ══════════════════════════════════════════════

RECV="$(md_section "$SECURITY_MD" '## 監視の限界（受信側）')"

it "「## 監視の限界（受信側）」節がある（空なら FAIL）"
if [ -n "$RECV" ]; then pass; else fail "節が無い、または空"; fi

it "既存の「## 監視の限界（送信側）」節が残っている"
SEND="$(md_section "$SECURITY_MD" '## 監視の限界（送信側）')"
if [ -n "$SEND" ]; then pass; else fail "送信側の節が消えた"; fi

it "受信側の節が送信側の節より後ろにある"
send_line="$(grep -n -m 1 -F '## 監視の限界（送信側）' "$SECURITY_MD" | cut -d: -f1)"
recv_line="$(grep -n -m 1 -F '## 監視の限界（受信側）' "$SECURITY_MD" | cut -d: -f1)"
case "$send_line" in
  ''|*[!0-9]*) fail "送信側の行番号を取れない: '$send_line'" ;;
  *)
    case "$recv_line" in
      ''|*[!0-9]*) fail "受信側の行番号を取れない（節が無い）: '$recv_line'" ;;
      *) if [ "$send_line" -lt "$recv_line" ]; then pass; else fail "順序が逆: send=$send_line recv=$recv_line"; fi ;;
    esac ;;
esac

ACCEPT="$(printf '%s\n' "$RECV" | md_subsection '受け付ける入力')"
STOPS="$(printf '%s\n' "$RECV" | md_subsection '止める仕組み')"
LIMITS="$(printf '%s\n' "$RECV" | md_subsection '既知の限界')"

it "小節「受け付ける入力」「止める仕組み」「既知の限界」が全て非空"
if [ -n "$ACCEPT" ] && [ -n "$STOPS" ] && [ -n "$LIMITS" ]; then pass; else fail "空の小節がある" "受け付ける入力=${#ACCEPT}字 止める仕組み=${#STOPS}字 既知の限界=${#LIMITS}字"; fi

for word in "fail closed" "Host" "Origin" "Content-Type" "64KB" "Access-Control-Allow-Origin" "127.0.0.1" "MONITOR_BIND" "プレースホルダ" "ログ"; do
  it "止める仕組みに「${word}」が書かれている"
  assert_has "$STOPS" "$word"
done

for word in "Sec-Fetch-Site" "same-origin" "シンボリックリンク" "lstat" "0700" "0600"; do
  it "止める仕組みに「${word}」が書かれている（G5 retry 1: リンク拒否・Sec-Fetch-Site・パーミッション）"
  assert_has "$STOPS" "$word"
done

for word in "認証" "同一端末" "書き込み" "読み出し" "セキュリティ境界ではない" "known_limit_local_process_can_write"; do
  it "既知の限界に「${word}」が書かれている"
  assert_has "$LIMITS" "$word"
done

it "security.md が言及する既知の限界テストが node のテストファイルに実在する"
assert_file_contains "$TEST_DIR/server-security.test.mjs" "known_limit_local_process_can_write"

# ══════════════════════════════════════════════
suite "monitor-server: CI（template-ci.yml の tests ジョブで Node 24 を用意する）"
# ══════════════════════════════════════════════

TESTS_JOB="$(ci_job tests)"

it "tests ジョブが抜き出せる（空なら FAIL）"
if [ -n "$TESTS_JOB" ]; then pass; else fail "tests ジョブが無い"; fi

it "tests ジョブに actions/setup-node がある"
assert_has "$TESTS_JOB" "actions/setup-node@"

it "setup-node が Node 24 を指定している"
case "$TESTS_JOB" in
  *"node-version: 24"*|*"node-version: '24'"*|*'node-version: "24"'*) pass ;;
  *) fail "node-version: 24 が無い" ;;
esac

it "setup-node の参照が浮動参照（@main / @master）でも空でもない"
case "$TESTS_JOB" in
  *"actions/setup-node@main"*|*"actions/setup-node@master"*) fail "浮動参照" ;;
  *"actions/setup-node@"[A-Za-z0-9]*) pass ;;
  *) fail "ref が空または無い" ;;
esac

it "setup-node がテスト実行（bash tests/run.sh）より前にある"
BEFORE_RUN="${TESTS_JOB%%bash tests/run.sh*}"
case "$BEFORE_RUN" in
  *"actions/setup-node@"*) pass ;;
  *) fail "テスト実行の後ろ、または bash tests/run.sh が無い" ;;
esac

it "必須の4ジョブ（shell / tests / docs / hygiene）が残っている"
missing=""
for job in "shell:" "tests:" "docs:" "hygiene:"; do
  grep -qF "  $job" "$CI_YML" || missing="$missing $job"
done
assert_eq "$(echo "$missing" | tr -s ' ')" ""

report
