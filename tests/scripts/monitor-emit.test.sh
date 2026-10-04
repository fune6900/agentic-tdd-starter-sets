#!/usr/bin/env bash
# .claude/hooks/monitor-emit.sh のテスト（Issue #18。実装済み・変異テスト実施済み）
#
# 入力仕様は #17 の成果物だけ（推測しない。lessons #6）:
#   .claude/monitor/docs/event-schema.md / hook-events.md
#   .claude/monitor/test/fixtures/{hook-stdin,emitted}/*.json
#
# ── 実装（monitor-emit.sh）との契約 ────────────────────────────────────────────
#   - フックは stdin の JSON を jq で抽出し、curl に `--data-binary @-` で stdin から渡す
#   - 送信先は http://127.0.0.1:${port}/api/events 固定（curl の argv に URL がそのまま載る）
#   - Content-Type: application/json を付ける（スキーマ #17 は JSON。受信側 #3 が判定に使う）
#   - curl は PATH 経由で呼ぶ（絶対パス直書き禁止。テストは PATH にラッパーを置いて観測する）
#   - 背景化は `>/dev/null 2>&1 &`（curl の fd1/fd2 が /dev/null であること）
#   - フックの argv / jq・curl・basename 等の子プロセスの argv に、ペイロード由来の値
#     （session_id / tool_use_id / コマンド / パス / プロンプト）を載せない（ps で見える）
#   - 標準出力は 0 バイト・標準エラーも 0 バイト・終了コード 0（全入力・全異常系）
#   - 検証できなかった値は送らない（省略）。event が列挙外ならイベントごと送らない
#   - security.md の「監視の限界（送信側）」節に「送る項目」「送らない項目」「既知の限界」
#     の 3 語を含める。既知の限界には「先頭トークン」（後述の代表経路）を書く
#
# ── 既知の限界テストに選んだ経路（AC13）──────────────────────────────
#   Bash コマンドの先頭トークン自体が秘密で、かつ許可文字 [A-Za-z0-9._-] のみで
#   32 バイト以内なら、そのままベース名として bash_command に載って送られる。
#   （先頭トークン方式から必然的に通る。値を隠すには内容の意味解析が要るので諦める経路）
#
# ── 変異テスト対応表（AC15。実施済み。防御を外す変異で各テストが FAIL することを確認）─────────────
#   防御を外す変異                     落ちるべきテスト（it 名の先頭タグ）
#   allowlist 抽出                     [AC2]（番兵）/ [AC1]（キー集合・型・値）/ [AC1b]（スキーマ外キー・'/'）
#   制御文字除去                       [AC4] C0 / DEL / C1 / 双方向 の各ケース
#   長さ制限                           [AC4] 128 バイト切り詰め / [AC3] 32 バイト / [AC1c] session_id 長
#   背景化（& を外す）                 [AC5] 送信は背景で続く（フック終了後も curl が生きている）
#   stdout / stderr 切り離し           [AC5] curl の fd1・fd2 は /dev/null / [AC6]
#   --max-time                         [AC5] curl は有限時間で自ら終了する
#   --noproxy                          [AC9] 6 種のプロキシ変数（http_proxy / all_proxy 等）
#   ポート検証（case）                 [AC8] 不正値は既定 4319 へ倒れる
#   LOOP_MONITOR=0                     [AC7]
#   （参考）ホスト固定                 [AC10]
#   curl の -q（.curlrc を読ませない） [AC14] CURL_HOME / XDG_CONFIG_HOME / HOME × url / connect-to / trace-ascii
#   jq の HOME 差し替え（.jq 遮断）    [AC14] .jq の test / with_entries 上書き（ファイル・ディレクトリ）
#   32 バイト超を ? にする             [AC3] 33 / 44 バイト・40 文字 a・パス修飾のトークン断片がボディに出ない
#
# ── 検査の設計メモ ─────────────────────────────────────────────────────
#   - emitted fixture はキー・値とも stdin の純関数（ts 等の可変値をスキーマが持たない）。
#     よって [AC1] は「キー集合・型」と「値まで完全一致」を別 it で両方要求する。
#     with-usage の emitted は transcript 由来（#7）で hook-stdin 側に対応物が無いので対象外。
#   - 値の行き先を全数で数える（lessons #11）: 送信ボディ / curl の argv / stdout / stderr /
#     一時ファイル。[AC2]=ボディ、[AC11]=argv、[AC5]=stdout・stderr、一時ファイルは
#     フック実行前後の TMPDIR 差分（[AC11b]）。
#   - 既定ポート 4319 には実際の接続をしない（開発中の本物の監視サーバを汚さない）。
#     不正ポートの検査は PATH の curl ラッパー（送信しない記録専用モード）で argv の URL を見る。
#   - node / perl が無ければ FAIL（スキップ扱いにしない。lessons #10）。
#   - シェル側の検証は case（lessons #10）。番兵・argv の包含判定は検証ではなく観測なので grep -F を使う。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

cd "$REPO_ROOT" || exit 1

STUB_PIDS=()
cleanup_all() {
  local p
  for p in "${STUB_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null
    wait "$p" 2>/dev/null
  done
  # 生き残った curl（hang スタブ相手）を掃除する
  for p in "${CURL_PIDS_TO_KILL[@]:-}"; do
    [ -n "$p" ] || continue
    kill "$p" 2>/dev/null
  done
  cleanup_sandboxes
}
CURL_PIDS_TO_KILL=()
trap cleanup_all EXIT

HOOK="$REPO_ROOT/.claude/hooks/monitor-emit.sh"
STUB_JS="$REPO_ROOT/tests/scripts/fixtures/monitor-stub.mjs"
MON="$REPO_ROOT/.claude/monitor"
STDIN_DIR="$MON/test/fixtures/hook-stdin"
EMITTED_DIR="$MON/test/fixtures/emitted"
SCHEMA_DOC="$MON/docs/event-schema.md"
SETTINGS="$REPO_ROOT/.claude/settings.json"
BASELINE="$REPO_ROOT/tests/scripts/fixtures/settings-hooks.baseline.json"
SECURITY_MD="$REPO_ROOT/.claude/rules/security.md"

BASH_BIN="$(command -v bash)"
NODE_BIN="$(command -v node || true)"
PERL_BIN="$(command -v perl || true)"

WORK="$(mktemp -d)" || { echo "mktemp に失敗した" >&2; exit 1; }
SANDBOXES+=("$WORK")
ERR="$WORK/stderr"
IN="$WORK/stdin"

# 環境の影響を断つ（各テストが必要な変数だけ env で渡す）
unset LOOP_MONITOR LOOP_MONITOR_PORT LOOP_MONITOR_HOST \
      http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
export CLAUDE_PROJECT_DIR="$REPO_ROOT"

# ══════════════════════════════════════════════
suite "前提: 道具とフックの存在"
# ══════════════════════════════════════════════

it "node がある（スタブ受信器に必須。無ければ FAIL）"
if [ -n "$NODE_BIN" ]; then pass; else fail "node が無い。テストを実行できない"; fi

it "perl がある（Time::HiRes での計測に必須。無ければ FAIL）"
if [ -n "$PERL_BIN" ] && "$PERL_BIN" -MTime::HiRes=time -e 1 2>/dev/null; then pass; else fail "perl / Time::HiRes が無い"; fi

if [ -z "$NODE_BIN" ] || [ -z "$PERL_BIN" ]; then report; exit 1; fi

it "フック .claude/hooks/monitor-emit.sh が存在する"
HOOK_MISSING=0
if [ -f "$HOOK" ]; then pass; else HOOK_MISSING=1; fail "無い: $HOOK"; fi

it "フックが set -u を宣言している"
if [ "$HOOK_MISSING" -eq 1 ]; then fail "フックが無い"; else assert_file_contains "$HOOK" "set -u"; fi

# ---------- スタブ ----------

S_DIR=""; S_PORT=""; S_PID=""

start_stub() { # <capture|hang|proxy> → S_DIR / S_PORT / S_PID
  S_DIR="$(mktemp -d)" || exit 1
  SANDBOXES+=("$S_DIR")
  "$NODE_BIN" "$STUB_JS" "$1" "$S_DIR" >"$S_DIR/stub.log" 2>&1 &
  S_PID=$!
  STUB_PIDS+=("$S_PID")
  local i=0
  while [ ! -f "$S_DIR/port" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  S_PORT=""
  if [ -f "$S_DIR/port" ]; then S_PORT="$(cat "$S_DIR/port")"; fi
  case "$S_PORT" in
    ''|*[!0-9]*) echo "スタブ($1)が起動しない: $(cat "$S_DIR/stub.log" 2>/dev/null)" >&2; exit 1 ;;
  esac
}

stop_stub() { # <pid>
  kill "$1" 2>/dev/null
  wait "$1" 2>/dev/null
}

conn_count() { # <dir>
  if [ -f "$1/conns" ]; then wc -l <"$1/conns" | tr -d ' '; else echo 0; fi
}

body_count() { # <dir>
  local n=0 f
  for f in "$1"/body.*; do [ -e "$f" ] && n=$((n + 1)); done
  echo "$n"
}

# フックは送信を背景化するので、届くまで上限付きでポーリングする
WAIT_ITERS=150   # 0.02 秒刻み = 上限 3 秒
wait_file() { # <path> → 上限内に現れたら 0
  local i=0
  [ "$HOOK_MISSING" -eq 1 ] && return 1
  while [ ! -e "$1" ] && [ "$i" -lt "$WAIT_ITERS" ]; do sleep 0.02; i=$((i + 1)); done
  [ -e "$1" ]
}

wait_log_contains() { # <log> <文字列> → 上限内に現れたら 0
  local i=0
  [ "$HOOK_MISSING" -eq 1 ] && return 1
  while [ "$i" -lt "$WAIT_ITERS" ]; do
    if [ -f "$1" ] && grep -qF -- "$2" "$1"; then return 0; fi
    sleep 0.02; i=$((i + 1))
  done
  return 1
}

# ---------- フックの実行 ----------

# フックを perl で起動し、EOF まで待って（＝パイプを握る子孫がいれば待たされる）
# 経過秒・終了コード・標準出力バイト数を得る。標準エラーは $ERR へ。
T_ELAPSED=""; T_RC=""; T_BYTES=""
timed_hook() { # <stdin ファイル> [VAR=val | -u VAR ...]
  local in="$1" out; shift
  out="$(env "$@" "$PERL_BIN" -MTime::HiRes=time -e '
    $t = time;
    $pid = open(P, "-|", @ARGV);
    die "fork: $!" unless defined $pid;
    { local $/; $o = <P>; }
    close(P);
    $rc = $? >> 8; $sig = $? & 127;
    printf "%.3f %d %d\n", time - $t, ($sig ? 128 + $sig : $rc), length(defined $o ? $o : "");
  ' "$BASH_BIN" "$HOOK" <"$in" 2>"$ERR")"
  read -r T_ELAPSED T_RC T_BYTES <<<"$out"
  T_ELAPSED="${T_ELAPSED:-99}"; T_RC="${T_RC:-127}"; T_BYTES="${T_BYTES:-0}"
}

# 直前の timed_hook が「stdout 0 バイト・stderr 空・exit 0」だったか（判定のみ。it/pass は呼ばない）
is_quiet() { [ "$T_BYTES" = "0" ] && [ "$T_RC" = "0" ] && [ ! -s "$ERR" ]; }

check_quiet() { # <ラベル> [ACタグ。既定 AC5]
  it "[${2:-AC5}] ${1}: stdout 0 バイト・stderr 空・exit 0"
  if is_quiet; then pass
  else fail "stdout=${T_BYTES} バイト rc=${T_RC} stderr=$(head -c 200 "$ERR")"; fi
}

# capture スタブへ送って新しいボディが届くまで待つ。BODY に届いたパス（無ければ空）。
CAP_DIR=""; CAP_PORT=""; BODY=""
emit() { # <stdin ファイル> [VAR=val ...]
  local in="$1" before; shift
  before="$(body_count "$CAP_DIR")"
  timed_hook "$in" LOOP_MONITOR_PORT="$CAP_PORT" "$@"
  BODY=""
  if wait_file "$CAP_DIR/body.$((before + 1))"; then BODY="$CAP_DIR/body.$((before + 1))"; fi
}

# 届かないことを検査する時は待ち時間を短くする（届くなら十分に短い時間で届く）
emit_expect_none() { # <stdin ファイル> [VAR=val ...]
  local saved="$WAIT_ITERS"
  WAIT_ITERS=50
  emit "$@"
  WAIT_ITERS="$saved"
}

# 入力 JSON を作る。$1=出力先 $2=元 fixture 名（拡張子なし） $3=jq フィルタ [jq の追加引数...]
mk_stdin() {
  local out="$1" base="$2" filter="$3"; shift 3
  jq -c "$@" "$filter" "$STDIN_DIR/${base}.json" >"$out"
}

schema_keys_json() {
  sed -n '/<!-- SCHEMA:KEYS -->/,/<!-- \/SCHEMA:KEYS -->/p' "$SCHEMA_DOC" \
    | grep -o '`[a-z_]*`' | tr -d '`' | jq -R . | jq -s -c .
}

start_stub capture
CAP_DIR="$S_DIR"; CAP_PORT="$S_PORT"
SCHEMA_KEYS="$(schema_keys_json)"

# ══════════════════════════════════════════════
suite "[AC1] hook-stdin fixture → 送信ボディが emitted fixture と一致"
# ══════════════════════════════════════════════

shape_filter='def shape: if type=="object" then map_values(shape) elif type=="array" then map(shape) else type end; shape'

for f in "$STDIN_DIR"/*.json; do
  name="$(basename "$f" .json)"
  emitted="$EMITTED_DIR/${name}.json"

  emit "$f"

  it "[AC1] ${name}: 送信ボディが届き、POST /api/events で Content-Type が JSON"
  if [ -n "$BODY" ] && [ -f "$CAP_DIR/req.$(body_count "$CAP_DIR")" ]; then
    req="$(cat "$CAP_DIR/req.$(body_count "$CAP_DIR")")"
    case "$req" in
      "POST /api/events"*"content-type: application/json"*) pass ;;
      *) fail "リクエスト行またはヘッダが違う" "実際: ${req}" ;;
    esac
  else
    fail "ボディが届かない（フック不在または送信失敗）"
  fi

  it "[AC1] ${name}: キー集合と型が emitted fixture と一致"
  if [ -n "$BODY" ] && [ -f "$emitted" ]; then
    assert_eq "$(jq -S -c "$shape_filter" "$BODY" 2>/dev/null)" "$(jq -S -c "$shape_filter" "$emitted")"
  else
    fail "ボディまたは emitted fixture が無い: ${name}"
  fi

  it "[AC1] ${name}: 値まで emitted fixture と完全一致（可変値なし）"
  if [ -n "$BODY" ] && [ -f "$emitted" ]; then
    assert_eq "$(jq -S -c . "$BODY" 2>/dev/null)" "$(jq -S -c . "$emitted")"
  else
    fail "ボディまたは emitted fixture が無い: ${name}"
  fi

  it "[AC1b] ${name}: キーが全て SCHEMA:KEYS 内で、ボディに '/' を含まない（パス・URL 混入なし）"
  if [ -n "$BODY" ]; then
    bad="$(jq -r --argjson allowed "$SCHEMA_KEYS" '[keys[] | select(. as $k | $allowed | index($k) | not)] | join(",")' "$BODY" 2>/dev/null)"
    case "$(cat "$BODY")" in
      */*) fail "ボディに '/' がある: $(cat "$BODY")" ;;
      *) assert_eq "$bad" "" ;;
    esac
  else
    fail "ボディが届かない"
  fi

  check_quiet "$name"
done

it "[AC1] emitted 側で対応する hook-stdin が無いのは with-usage だけ（#7 の transcript 由来）"
orphans=""
for e in "$EMITTED_DIR"/*.json; do
  n="$(basename "$e" .json)"
  [ -f "$STDIN_DIR/${n}.json" ] || orphans="$orphans $n"
done
assert_eq "$(echo "$orphans" | tr -s ' ')" " Stop.with-usage SubagentStop.with-usage"

it "[AC1] Notification（実測で未発火・fixture 無し）も スキーマ通りの最小ボディで送る"
printf '%s' '{"hook_event_name":"Notification","session_id":"11111111-1111-4111-8111-111111111111","message":"SNTLEAFMSGX","cwd":"/work/project"}' >"$IN"
emit "$IN"
if [ -n "$BODY" ]; then
  assert_eq "$(jq -S -c . "$BODY")" '{"event":"Notification","schema_version":1,"session_id":"11111111-1111-4111-8111-111111111111"}'
else fail "ボディが届かない"; fi

# ══════════════════════════════════════════════
suite "[AC2] 全文字列リーフに番兵を注入 → allowlist 由来以外は 1 つも出ない"
# ══════════════════════════════════════════════
# allowlist の源泉パス（送信ボディの値の元になりうる場所）だけ元の値を残し（残さないと
# イベントごと届かない）、それ以外の全文字列リーフを jq の paths で列挙してリーフごとに
# 異なる番兵に置換する。既知フィールドだけを検査する方式にしない（未知のキーも
# 追加して、実装が「送らない」ことを列挙でなく allowlist で保証しているかを見る）。

KEEP='["session_id","hook_event_name","tool_name","tool_use_id","agent_id","agent_type","source","reason","trigger","tool_input.subagent_type","tool_input.command","tool_input.file_path"]'
inject_filter='
  def pj: map(tostring) | join(".");
  [paths(type == "string")] as $ps
  | reduce range(0; $ps | length) as $i (.;
      ($ps[$i]) as $p
      | if ($keep | index($p | pj)) then . else setpath($p; "SNTLEAF\($i)X") end)
  | .extra_top_secret = "SNTLEAFTOPX"
  | if (.tool_input | type) == "object" then .tool_input.extra_field = "SNTLEAFNESTX" else . end
'

for f in "$STDIN_DIR"/*.json; do
  name="$(basename "$f" .json)"
  jq -c --argjson keep "$KEEP" "$inject_filter" "$f" >"$IN"
  emit "$IN"

  it "[AC2] ${name}: 番兵（SNTLEAF）がボディに現れない"
  if [ -z "$BODY" ]; then fail "ボディが届かない（allowlist 源泉は元の値のままなので届くはず）"
  else
    case "$(cat "$BODY")" in
      *SNTLEAF*) fail "スキーマ外の番兵が送信された" "ボディ: $(cat "$BODY")" ;;
      *) pass ;;
    esac
  fi
done

it "[AC2] 番兵の網羅性: 注入対象の文字列リーフが fixture 全体で 100 個以上ある（検査が空振りしていない）"
total=0
for f in "$STDIN_DIR"/*.json; do
  c="$(jq --argjson keep "$KEEP" '[paths(type=="string")] | length' "$f")"
  total=$((total + c))
done
if [ "$total" -ge 100 ]; then pass; else fail "リーフが少なすぎる: ${total}"; fi

it "[AC2] 逆方向: allowlist フィールド（session_id / tool_use_id）の値はボディに現れる"
jq -c '.session_id = "SNTSESSAB-12" | .tool_use_id = "toolu_SNTTUIDAB"' "$STDIN_DIR/PreToolUse.read.json" >"$IN"
emit "$IN"
if [ -n "$BODY" ]; then
  assert_eq "$(jq -c '[.session_id, .tool_use_id]' "$BODY")" '["SNTSESSAB-12","toolu_SNTTUIDAB"]'
else fail "ボディが届かない"; fi

# ══════════════════════════════════════════════
suite "[AC3] Bash コマンドは先頭トークンのベース名のみ"
# ══════════════════════════════════════════════

bash_case() { # <コマンド文字列> → BODY
  mk_stdin "$IN" "PreToolUse.bash" '.tool_input.command = $c' --arg c "$1"
  emit "$IN"
}

it "[AC3] export API_KEY=xxx → export。値 SECRETXXX1 が出ない"
bash_case 'export API_KEY=SECRETXXX1'
if [ -n "$BODY" ]; then
  case "$(cat "$BODY")" in
    *SECRETXXX1*|*API_KEY*) fail "秘密が送信された: $(cat "$BODY")" ;;
    *) assert_eq "$(jq -r '.bash_command' "$BODY")" "export" ;;
  esac
else fail "ボディが届かない"; fi

it "[AC3] curl -H \"Authorization: Bearer xxx\" → curl。SECRETXXX2 と Bearer が出ない"
bash_case 'curl -H "Authorization: Bearer SECRETXXX2" https://example.invalid/'
if [ -n "$BODY" ]; then
  case "$(cat "$BODY")" in
    *SECRETXXX2*|*Bearer*|*example*) fail "引数が送信された: $(cat "$BODY")" ;;
    *) assert_eq "$(jq -r '.bash_command' "$BODY")" "curl" ;;
  esac
else fail "ボディが届かない"; fi

it "[AC3] パス修飾されたコマンドはベース名だけ: /usr/bin/git status → git"
bash_case '/usr/bin/git status'
[ -n "$BODY" ] && assert_eq "$(jq -r '.bash_command' "$BODY")" "git" || fail "ボディが届かない"

it "[AC3] 相対パス: ./scripts/run.sh arg → run.sh"
bash_case './scripts/run.sh arg'
[ -n "$BODY" ] && assert_eq "$(jq -r '.bash_command' "$BODY")" "run.sh" || fail "ボディが届かない"

it "[AC3] 先頭の空白は無視: '   ls -la' → ls"
bash_case '   ls -la'
[ -n "$BODY" ] && assert_eq "$(jq -r '.bash_command' "$BODY")" "ls" || fail "ボディが届かない"

it "[AC3] 環境変数代入の前置き FOO=SECRETXXX3 cmd は許可文字外(=)を含むので ? で、値が出ない"
bash_case 'FOO=SECRETXXX3 cmd'
if [ -n "$BODY" ]; then
  case "$(cat "$BODY")" in
    *SECRETXXX3*) fail "値が送信された" ;;
    *) assert_eq "$(jq -r '.bash_command' "$BODY")" "?" ;;
  esac
else fail "ボディが届かない"; fi

for c in 'ls;rm x' '$(whoami) x' '`id` x' 'echo|cat' '"quoted" x' "it's x" 'a&b x' '日本語コマンド x'; do
  it "[AC3] 許可文字外を含む先頭トークンは ? に倒す: ${c}"
  bash_case "$c"
  [ -n "$BODY" ] && assert_eq "$(jq -r '.bash_command' "$BODY")" "?" || fail "ボディが届かない"
done

it "[AC3] 複数行: 先頭トークンの後の行に秘密があっても出ない（case 判定。1 行目だけを見る grep 判定にしない）"
bash_case $'ls\nexport API_KEY=SECRETXXX4'
if [ -n "$BODY" ]; then
  case "$(cat "$BODY")" in
    *SECRETXXX4*) fail "2 行目が送信された" ;;
    *) assert_eq "$(jq -r '.bash_command' "$BODY")" "ls" ;;
  esac
else fail "ボディが届かない"; fi

it "[AC3] 複数行: 先頭トークンが改行を挟んで許可文字外なら ? （行ごとに判定して 1 行目だけ合格させない）"
bash_case $'ok\n;bad'
[ -n "$BODY" ] && assert_eq "$(jq -r '.bash_command' "$BODY")" "ok" || fail "ボディが届かない"

# G5 差し戻し(#18 retry 1)・マスター決定: 32 バイト超のトークンは「切り詰めて送る」のではなく
# 「送らずに ?」にする。切り詰めると ghp_ 形式のような長い許可文字のみの秘密トークンの
# 先頭 32 バイトが漏れるため。旧テスト（40 文字 → 1〜32 バイトならよい）は
# 切り詰めを許容していたので、? 固定・トークン断片ゼロの期待へ書き換えた。
# 判定は「ベース名化した後の長さ」で行う前提（/usr/bin/<長い名前> も対象）。
long_token_case() { # <ラベル> <トークン> <コマンド全体>
  local label="$1" tok="$2" cmd="$3" p8 m8 l8
  bash_case "$cmd"
  it "[AC3] ${label}: bash_command は ?（切り詰めない）で、トークンの先頭・中間・末尾 8 バイトのどれもボディに出ない"
  if [ -n "$BODY" ]; then
    p8="${tok:0:8}"; m8="${tok:12:8}"; l8="${tok: -8}"
    case "$(cat "$BODY")" in
      *"$p8"*|*"$m8"*|*"$l8"*) fail "トークンの断片が送信された: $(cat "$BODY")" ;;
      *) assert_eq "$(jq -r '.bash_command // "OMITTED"' "$BODY")" "?" ;;
    esac
  else fail "ボディが届かない"; fi
}

# 秘密スキャナの誤検知を避けるため、プレフィックスは実行時に連結して組み立てる
GH_PREFIX="gh""p_"
FAKE32="${GH_PREFIX}FAKEONLYNOTREAL0123456789abc"
FAKE33="${FAKE32}X"
FAKE44="${FAKE32}defghijklmno"

it "[AC3] 自己診断: 偽トークンの長さが 33 / 44 / 32 バイトで、実在しない形（FAKE 入り）"
if [ "${#FAKE33}" -eq 33 ] && [ "${#FAKE44}" -eq 44 ] && [ "${#FAKE32}" -eq 32 ]; then pass
else fail "長さ: ${#FAKE33} / ${#FAKE44} / ${#FAKE32}"; fi

long_token_case "33 バイトのトークン" "$FAKE33" "$FAKE33 --flag"
long_token_case "44 バイトのトークン" "$FAKE44" "$FAKE44 arg"
long_token_case "40 文字の a" "$(printf 'a%.0s' $(seq 1 40))" "$(printf 'a%.0s' $(seq 1 40)) arg"
long_token_case "パス修飾（ベース名化後に 33 バイト）" "$FAKE33" "/usr/bin/${FAKE33} x"

it "[AC3] 境界: ちょうど 32 バイトのトークンはそのまま送られる"
bash_case "$FAKE32 --flag"
[ -n "$BODY" ] && assert_eq "$(jq -r '.bash_command // "OMITTED"' "$BODY")" "$FAKE32" || fail "ボディが届かない"

it "[AC3] 境界: パス修飾でもベース名が 32 バイトならベース名がそのまま送られる"
bash_case "/usr/bin/${FAKE32} x"
[ -n "$BODY" ] && assert_eq "$(jq -r '.bash_command // "OMITTED"' "$BODY")" "$FAKE32" || fail "ボディが届かない"

it "[AC3] 判定はベース名化後: 全体が長くてもベース名が短ければ（/very/.../ls）ベース名が送られる"
bash_case "/very/long/directory/name/that/exceeds/thirty/two/bytes/ls arg"
[ -n "$BODY" ] && assert_eq "$(jq -r '.bash_command // "OMITTED"' "$BODY")" "ls" || fail "ボディが届かない"

it "[AC3] 空コマンド・空白のみでも落ちず、漏らさない（bash_command は省略か ?）"
bash_case '   '
if [ -n "$BODY" ]; then
  case "$(jq -r 'if has("bash_command") then .bash_command else "OMITTED" end' "$BODY")" in
    OMITTED|"?") pass ;;
    *) fail "空コマンドで bash_command が送られた: $(cat "$BODY")" ;;
  esac
else fail "ボディが届かない"; fi

it "[AC3] Bash 以外のツール（Read）に bash_command を付けない"
emit "$STDIN_DIR/PreToolUse.read.json"
[ -n "$BODY" ] && assert_eq "$(jq -r 'has("bash_command")' "$BODY")" "false" || fail "ボディが届かない"

# ══════════════════════════════════════════════
suite "[AC4] file_path はベース名のみ・制御文字除去・128 バイトで切り詰め"
# ══════════════════════════════════════════════
# 制御文字のケースは tests/scripts/loop-journal.test.sh の safe_display 系
# （ESC / 双方向 RLO / C1）と同じ種類に、C0 全般・DEL・NUL・双方向 U+2066-2069 を足したもの。

fp_case() { # <jq 文字列リテラル（\u エスケープ可）> → BODY
  jq -c "$1 as \$p | .tool_input.file_path = \$p" "$STDIN_DIR/PreToolUse.read.json" >"$IN"
  emit "$IN"
}

it "[AC4] ディレクトリ部分を落としてベース名のみ: /x/DIRSENTINEL/name.txt → name.txt"
fp_case '"/x/DIRSENTINEL/name.txt"'
if [ -n "$BODY" ]; then
  case "$(cat "$BODY")" in
    *DIRSENTINEL*) fail "ディレクトリが送信された" ;;
    *) assert_eq "$(jq -r '.file_path' "$BODY")" "name.txt" ;;
  esac
else fail "ボディが届かない"; fi

it "[AC4] ESC（C0）を除去: 'evil<ESC>[31mINJECTED' → evil[31mINJECTED"
fp_case '"evil\u001b[31mINJECTED"'
[ -n "$BODY" ] && assert_eq "$(jq -r '.file_path' "$BODY")" "evil[31mINJECTED" || fail "ボディが届かない"

it "[AC4] NUL / BEL / TAB / 改行 / CR を除去（C0 全般）"
fp_case '"a\u0000b\u0007c\td\ne\rf"'
[ -n "$BODY" ] && assert_eq "$(jq -r '.file_path' "$BODY")" "abcdef" || fail "ボディが届かない"

it "[AC4] DEL（0x7F）を除去"
fp_case '"a\u007fb"'
[ -n "$BODY" ] && assert_eq "$(jq -r '.file_path' "$BODY")" "ab" || fail "ボディが届かない"

it "[AC4] C1 制御文字（U+0085 / U+009B）を除去"
fp_case '"a\u0085b\u009bc"'
[ -n "$BODY" ] && assert_eq "$(jq -r '.file_path' "$BODY")" "abc" || fail "ボディが届かない"

it "[AC4] 双方向制御文字 RLO（U+202E）/ U+202A-202E を除去"
fp_case '"A‮B‪C‭D"'
[ -n "$BODY" ] && assert_eq "$(jq -r '.file_path' "$BODY")" "ABCD" || fail "ボディが届かない"

it "[AC4] 双方向制御文字 U+2066-2069 と LRM/RLM（U+200E/200F）を除去"
fp_case '"A⁦B⁩C‎D‏E"'
[ -n "$BODY" ] && assert_eq "$(jq -r '.file_path' "$BODY")" "ABCDE" || fail "ボディが届かない"

it "[AC4] 通常のマルチバイト文字（日本語）は壊さない"
fp_case '"/x/レポート.md"'
[ -n "$BODY" ] && assert_eq "$(jq -r '.file_path' "$BODY")" "レポート.md" || fail "ボディが届かない"

it "[AC4] ディレクトリ側の制御文字・改行があってもベース名だけになる"
fp_case '"/a\u001b/b\nc/d.txt"'
[ -n "$BODY" ] && assert_eq "$(jq -r '.file_path' "$BODY")" "d.txt" || fail "ボディが届かない"

it "[AC4] 300 文字の ASCII は 128 バイト以内に切り詰める（空にはしない）"
fp_case "\"$(printf 'A%.0s' $(seq 1 300))\""
if [ -n "$BODY" ]; then
  len="$(jq -j '.file_path' "$BODY" | LC_ALL=C wc -c | tr -d ' ')"
  if [ "$len" -ge 1 ] && [ "$len" -le 128 ]; then pass; else fail "file_path が ${len} バイト"; fi
else fail "ボディが届かない"; fi

it "[AC4] 多バイトは文字の途中で割らない: 'あ'×100（300 バイト）→ 128 バイト以内で不正バイト・U+FFFD なし"
fp_case "\"$(printf 'あ%.0s' $(seq 1 100))\""
if [ -n "$BODY" ]; then
  len="$(jq -j '.file_path' "$BODY" | LC_ALL=C wc -c | tr -d ' ')"
  rest="$(jq -j '.file_path' "$BODY" | LC_ALL=C tr -d '\343\201\202')"   # 'あ' = E3 81 82 の完全な並びだけ消す
  if [ "$len" -ge 1 ] && [ "$len" -le 128 ] && [ -z "$rest" ]; then pass
  else fail "len=${len} 完全な文字以外のバイトが残っている"; fi
else fail "ボディが届かない"; fi

it "[AC4] 送信ボディの file_path に '/' が残らない"
fp_case '"/a/b/c.txt"'
[ -n "$BODY" ] && case "$(jq -r '.file_path' "$BODY")" in */*) fail "'/' が残った" ;; *) pass ;; esac || fail "ボディが届かない"

# ══════════════════════════════════════════════
suite "[AC1c] 検証できない値は送らない（fail open だが fail closed な値の扱い）"
# ══════════════════════════════════════════════

it "[AC1c] hook_event_name が列挙外（Evil）ならイベントごと送らない"
mk_stdin "$IN" "PreToolUse.read" '.hook_event_name = "Evil"'
emit_expect_none "$IN"
assert_eq "$BODY" ""

it "[AC1c] session_id が許可文字外なら、そのままは送らない（省略でも棄却でも可）"
mk_stdin "$IN" "PreToolUse.read" '.session_id = "abc$(id);x"'
emit_expect_none "$IN"
if [ -z "$BODY" ]; then pass
else
  case "$(jq -r '.session_id // ""' "$BODY")" in
    *[!A-Za-z0-9-]*) fail "許可文字外の session_id が送信された: $(cat "$BODY")" ;;
    *) pass ;;
  esac
fi

it "[AC1c] session_id は 64 バイトを超えて送られない"
mk_stdin "$IN" "PreToolUse.read" '.session_id = ("a" * 100)'
emit_expect_none "$IN"
if [ -z "$BODY" ]; then pass
else
  len="$(jq -j '.session_id // ""' "$BODY" | LC_ALL=C wc -c | tr -d ' ')"
  if [ "$len" -le 64 ]; then pass; else fail "session_id が ${len} バイト"; fi
fi

it "[AC1c] tool_name が許可文字外なら、そのままは送らない"
mk_stdin "$IN" "PreToolUse.read" '.tool_name = "Read;evil"'
emit_expect_none "$IN"
if [ -z "$BODY" ]; then pass
else
  case "$(jq -r '.tool_name // ""' "$BODY")" in
    *[!A-Za-z0-9_-]*) fail "許可文字外の tool_name が送信された" ;;
    *) pass ;;
  esac
fi

it "[AC1c] duration_ms が上限 3,600,000 超なら省略"
mk_stdin "$IN" "PostToolUse.read" '.duration_ms = 3600001'
emit "$IN"
[ -n "$BODY" ] && assert_eq "$(jq -r 'has("duration_ms")' "$BODY")" "false" || fail "ボディが届かない"

it "[AC1c] duration_ms が上限ちょうど 3,600,000 なら送る"
mk_stdin "$IN" "PostToolUse.read" '.duration_ms = 3600000'
emit "$IN"
[ -n "$BODY" ] && assert_eq "$(jq -c '.duration_ms' "$BODY")" "3600000" || fail "ボディが届かない"

for v in '-1' '1.5' '"5"' 'null' 'true'; do
  it "[AC1c] duration_ms が非負整数でない（${v}）なら省略"
  mk_stdin "$IN" "PostToolUse.read" ".duration_ms = ${v}"
  emit "$IN"
  [ -n "$BODY" ] && assert_eq "$(jq -r 'has("duration_ms")' "$BODY")" "false" || fail "ボディが届かない"
done

it "[AC1c] stop_hook_active が真偽値でない（\"true\" 文字列）なら省略"
mk_stdin "$IN" "Stop" '.stop_hook_active = "true"'
emit "$IN"
[ -n "$BODY" ] && assert_eq "$(jq -r 'has("stop_hook_active")' "$BODY")" "false" || fail "ボディが届かない"

it "[AC1c] SessionEnd の reason が未知の値なら unknown に丸める"
mk_stdin "$IN" "SessionEnd" '.reason = "zzz-new-reason"'
emit "$IN"
[ -n "$BODY" ] && assert_eq "$(jq -r '.reason' "$BODY")" "unknown" || fail "ボディが届かない"

it "[AC1c] SessionStart の source が列挙外なら省略"
mk_stdin "$IN" "SessionStart" '.source = "zzz"'
emit "$IN"
[ -n "$BODY" ] && assert_eq "$(jq -r 'has("source")' "$BODY")" "false" || fail "ボディが届かない"

# ══════════════════════════════════════════════
suite "[AC5] 全異常系で stdout 0 バイト・stderr 空・exit 0"
# ══════════════════════════════════════════════

stub_closed_port() { # 使い終わって閉じたポート番号を返す（サーバ不在の再現）
  start_stub proxy
  CLOSED_PORT="$S_PORT"
  stop_stub "$S_PID"
}
stub_closed_port


printf '{not json' >"$IN";              timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "不正 JSON"
: >"$IN";                               timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "空 stdin"
printf '  \n\n' >"$IN";                 timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "空白のみ stdin"
printf '[]' >"$IN";                     timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "JSON 配列"
printf 'null' >"$IN";                   timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "JSON null"
printf '"str"' >"$IN";                  timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "JSON 文字列"
printf '{"hook_event_name":' >"$IN";    timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "途中で切れた JSON"
head -c 4096 /dev/urandom >"$IN";       timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "バイナリ"
jq -n -c '{hook_event_name:"PreToolUse",session_id:"a-1",tool_name:"Read",tool_use_id:"t1",tool_input:{content:("x" * 1000000)}}' >"$IN"
timed_hook "$IN" LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "1MB の巨大入力"
timed_hook /dev/null LOOP_MONITOR_PORT="$CAP_PORT"; check_quiet "/dev/null を stdin に"

it "[AC5] 不正入力（不正 JSON / 空 / 配列 / null）ではスタブに何も届かない"
before="$(body_count "$CAP_DIR")"; sleep 0.5
assert_eq "$(body_count "$CAP_DIR")" "$before"

timed_hook "$STDIN_DIR/SessionStart.json" LOOP_MONITOR_PORT="$CLOSED_PORT"
check_quiet "サーバ不在（閉じたポート）"
sleep 0.3

# 隔離 PATH: jq / curl を意図的に欠かした最小の PATH を作る
make_bin_without() { # <除外するコマンド名> → ディレクトリパスを echo
  local d="$WORK/bin-without-$1" c p
  mkdir -p "$d"
  for c in cat sed tr cut head tail basename dirname wc awk grep od expr sort uniq date sleep env printf \
           ls mkdir tee mktemp rm perl python3 xargs id true false test; do
    [ "$c" = "$1" ] && continue
    p="$(command -v "$c" 2>/dev/null || true)"
    case "$p" in /*) ln -sf "$p" "$d/$c" ;; esac
  done
  echo "$d"
}

NOJQ_BIN="$(make_bin_without jq)"
NOCURL_BIN="$(make_bin_without curl)"
# 隔離 PATH が本当に jq / curl を隠せているか（自己診断。隠せていなければ以降の検査は無意味）
it "[AC5] 自己診断: 隔離 PATH（jq 無し）で jq が見えない"
if env -i PATH="$NOJQ_BIN" "$BASH_BIN" -c 'command -v jq' >/dev/null 2>&1; then fail "jq が見えている"; else pass; fi
it "[AC5] 自己診断: 隔離 PATH（curl 無し）で curl が見えない"
if env -i PATH="$NOCURL_BIN" "$BASH_BIN" -c 'command -v curl' >/dev/null 2>&1; then fail "curl が見えている"; else pass; fi

before="$(body_count "$CAP_DIR")"
timed_hook "$STDIN_DIR/PreToolUse.bash.json" PATH="$NOJQ_BIN" LOOP_MONITOR_PORT="$CAP_PORT"
check_quiet "jq 不在"
it "[AC5] jq 不在では（入力を検証できないので）何も送らない"
sleep 0.5
assert_eq "$(body_count "$CAP_DIR")" "$before"

timed_hook "$STDIN_DIR/PreToolUse.bash.json" PATH="$NOCURL_BIN" LOOP_MONITOR_PORT="$CAP_PORT"
check_quiet "curl 不在"

start_stub hang
HANG_DIR="$S_DIR"; HANG_PORT="$S_PORT"; HANG_PID="$S_PID"
timed_hook "$STDIN_DIR/PreToolUse.bash.json" LOOP_MONITOR_PORT="$HANG_PORT"
check_quiet "サーバが接続を受けて応答しない（hang）"

# ---------- curl / jq / basename 等のラッパー（argv・fd・pid の観測用） ----------

SHIM_DIR="$WORK/shims"
mkdir -p "$SHIM_DIR"
make_shim() { # <名前>
  local name="$1" real
  real="$(command -v "$name" 2>/dev/null || true)"
  [ -n "$real" ] || return 0
  {
    cat <<'TEMPLATE'
#!/bin/sh
log="${SHIM_LOG:-/dev/null}"
{ printf 'CMD %s\n' "@NAME@"; for a in "$@"; do printf 'ARG %s\n' "$a"; done; } >>"$log"
TEMPLATE
    if [ "$name" = curl ]; then
      cat <<'TEMPLATE'
printf '%s\n' "$$" >>"${SHIM_PIDFILE:-/dev/null}"
@PERL@ -e '
  @n = stat("/dev/null");
  foreach $f (\*STDOUT, \*STDERR) {
    @s = stat($f);
    push @r, (($s[0] == $n[0] && $s[1] == $n[1]) ? "null" : "other");
  }
  open(L, ">>", $ENV{SHIM_LOG}) or exit 0;
  print L "FD @r\n";
'
if [ -n "${SHIM_NOSEND:-}" ]; then cat >/dev/null; exit 0; fi
TEMPLATE
    fi
    printf 'exec %s "$@"\n' "$real"
  } | sed -e "s|@NAME@|${name}|g" -e "s|@PERL@|${PERL_BIN}|g" >"$SHIM_DIR/$name"
  chmod +x "$SHIM_DIR/$name"
}
for c in curl jq basename dirname sed tr cut awk head tail grep od expr sort; do make_shim "$c"; done

# ---------- AC5 追加: 背景化・切り離し・--max-time ----------

SHIM_PATH="$SHIM_DIR:$PATH"
LOG="$WORK/hang.log"; PIDF="$WORK/hang.pid"
: >"$LOG"; : >"$PIDF"
timed_hook "$STDIN_DIR/PreToolUse.bash.json" PATH="$SHIM_PATH" SHIM_LOG="$LOG" SHIM_PIDFILE="$PIDF" LOOP_MONITOR_PORT="$HANG_PORT"
wait_log_contains "$LOG" "FD "
CURL_PID="$(head -1 "$PIDF")"
[ -n "$CURL_PID" ] && CURL_PIDS_TO_KILL+=("$CURL_PID")

it "[AC5] curl の fd1・fd2 は /dev/null に切り離されている（stdout を握って Claude Code を待たせない）"
assert_file_contains "$LOG" "FD null null"

it "[AC5] 送信は背景で続く（フック終了直後も curl がまだ生きている＝ & で背景化）"
if [ -n "$CURL_PID" ] && kill -0 "$CURL_PID" 2>/dev/null; then pass
else fail "フック終了時点で curl が終了済み（同期実行の疑い）pid='${CURL_PID}'"; fi

it "[AC5] curl は有限時間（5 秒以内）で自ら終了する（--max-time）"
i=0
while [ -n "$CURL_PID" ] && kill -0 "$CURL_PID" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
if [ -n "$CURL_PID" ] && ! kill -0 "$CURL_PID" 2>/dev/null; then pass
else fail "5 秒経っても curl が生きている（応答しないサーバで無限に待つ）"; fi

it "[AC5] 自己診断: hang スタブに実際に接続していた（応答しない状況を再現できている）"
if [ "$(conn_count "$HANG_DIR")" -ge 1 ]; then pass; else fail "hang スタブへの接続が 0 件"; fi

# ══════════════════════════════════════════════
suite "[AC6] 応答しないサーバに対して 20 回全て 1 秒未満"
# ══════════════════════════════════════════════

slow=""; nonzero=""; noisy=""
n=1
while [ "$n" -le 20 ]; do
  timed_hook "$STDIN_DIR/PreToolUse.bash.json" LOOP_MONITOR_PORT="$HANG_PORT"
  awk -v e="$T_ELAPSED" 'BEGIN { exit !(e < 1.0) }' || slow="$slow ${n}:${T_ELAPSED}s"
  [ "$T_RC" = "0" ] || nonzero="$nonzero ${n}:rc${T_RC}"
  { [ "$T_BYTES" = "0" ] && [ ! -s "$ERR" ]; } || noisy="$noisy ${n}"
  n=$((n + 1))
done

it "[AC6] 20 回全て 1 秒未満（perl Time::HiRes。出力パイプの EOF 待ちを含めて計測）"
assert_eq "$(echo "$slow" | tr -s ' ')" ""

it "[AC6] 20 回全て exit 0"
assert_eq "$(echo "$nonzero" | tr -s ' ')" ""

it "[AC6] 20 回全て stdout 0 バイト・stderr 空"
assert_eq "$(echo "$noisy" | tr -s ' ')" ""

stop_stub "$HANG_PID"

# ══════════════════════════════════════════════
suite "[AC7] LOOP_MONITOR=0 で接続 0 件"
# ══════════════════════════════════════════════

start_stub capture
Z_DIR="$S_DIR"; Z_PORT="$S_PORT"
ZLOG="$WORK/zero.log"; : >"$ZLOG"
fails=""
for f in SessionStart PreToolUse.bash PostToolUse.read Stop UserPromptSubmit; do
  timed_hook "$STDIN_DIR/${f}.json" PATH="$SHIM_PATH" SHIM_LOG="$ZLOG" LOOP_MONITOR=0 LOOP_MONITOR_PORT="$Z_PORT"
  is_quiet || fails="$fails ${f}"
done
sleep 0.8

it "[AC7] LOOP_MONITOR=0: 全イベントで stdout 空・exit 0"
assert_eq "$(echo "$fails" | tr -s ' ')" ""

it "[AC7] LOOP_MONITOR=0: スタブへの接続 0 件"
assert_eq "$(conn_count "$Z_DIR")" "0"

it "[AC7] LOOP_MONITOR=0: curl を一度も起動していない"
assert_file_not_contains "$ZLOG" "CMD curl"

it "[AC7] 対照: LOOP_MONITOR=1 では届く（0 件が「動いていない」せいでないことの確認）"
CAP_SAVE_DIR="$CAP_DIR"; CAP_SAVE_PORT="$CAP_PORT"
CAP_DIR="$Z_DIR"; CAP_PORT="$Z_PORT"
emit "$STDIN_DIR/SessionStart.json" LOOP_MONITOR=1
if [ -n "$BODY" ]; then pass; else fail "LOOP_MONITOR=1 でも届かない"; fi
CAP_DIR="$CAP_SAVE_DIR"; CAP_PORT="$CAP_SAVE_PORT"

# ══════════════════════════════════════════════
suite "[AC8] LOOP_MONITOR_PORT が不正なら既定 4319 へ倒れる"
# ══════════════════════════════════════════════
# 4319 へ実際に接続すると、開発中の本物の監視サーバ（#3）へテストデータを送ってしまう。
# curl ラッパーを記録専用（送信しない）にして、argv の URL で行き先を検査する。
# 他のポート（スタブ）には接続しないことも同時に確認する。

DEFAULT_URL="http://127.0.0.1:4319/api/events"
start_stub capture
P_DIR="$S_DIR"; P_PORT="$S_PORT"

port_case() { # <ラベル> <値>
  local label="$1" value="$2" plog="$WORK/port.$$.$RANDOM.log"
  : >"$plog"
  timed_hook "$STDIN_DIR/SessionStart.json" PATH="$SHIM_PATH" SHIM_LOG="$plog" SHIM_NOSEND=1 LOOP_MONITOR_PORT="$value"
  it "[AC8] ${label}: 既定 4319 の URL へ倒れる"
  if wait_log_contains "$plog" "ARG ${DEFAULT_URL}"; then pass
  else fail "argv に ${DEFAULT_URL} が無い" "記録: $(tr '\n' ' ' <"$plog")"; fi
  check_quiet "$label" AC8
}

port_case "abc" "abc"
port_case "0" "0"
port_case "70000" "70000"
port_case "複数行 4319\\n80" $'4319\n80'
port_case "空文字" ""
port_case "65536（上限超え）" "65536"
port_case "負数" "-1"
port_case "先頭が + の 80" "+80"
port_case "16 進風 0x50" "0x50"
port_case "前後に空白" " 4319 "
port_case "桁あふれ" "99999999999999999999"
port_case "コマンド置換風" '$(id)'

it "[AC8] 不正ポートのどれも、他のポート（スタブ）へは接続していない"
assert_eq "$(conn_count "$P_DIR")" "0"

it "[AC8] 正常ポート指定はその URL へ向かう（対照）"
plog="$WORK/port.valid.log"; : >"$plog"
timed_hook "$STDIN_DIR/SessionStart.json" PATH="$SHIM_PATH" SHIM_LOG="$plog" SHIM_NOSEND=1 LOOP_MONITOR_PORT="$P_PORT"
if wait_log_contains "$plog" "ARG http://127.0.0.1:${P_PORT}/api/events"; then pass
else fail "指定ポートの URL が argv に無い"; fi

it "[AC8] 未指定は既定 4319（対照）"
plog="$WORK/port.unset.log"; : >"$plog"
timed_hook "$STDIN_DIR/SessionStart.json" PATH="$SHIM_PATH" SHIM_LOG="$plog" SHIM_NOSEND=1
if wait_log_contains "$plog" "ARG ${DEFAULT_URL}"; then pass
else fail "既定 URL が argv に無い"; fi

# ══════════════════════════════════════════════
suite "[AC9] プロキシ環境変数を無視する（--noproxy）"
# ══════════════════════════════════════════════

start_stub proxy
PX_DIR="$S_DIR"; PX_PORT="$S_PORT"

for var in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY; do
  before="$(body_count "$CAP_DIR")"
  timed_hook "$STDIN_DIR/SessionStart.json" LOOP_MONITOR_PORT="$CAP_PORT" "${var}=http://127.0.0.1:${PX_PORT}"
  ok=0
  if wait_file "$CAP_DIR/body.$((before + 1))"; then ok=1; fi

  it "[AC9] ${var} をスタブに向けても、本来の宛先（127.0.0.1）へ直接届く"
  if [ "$ok" -eq 1 ]; then pass; else fail "プロキシ経由に流れて宛先に届いていない"; fi

  it "[AC9] ${var}: プロキシスタブへの接続 0 件"
  assert_eq "$(conn_count "$PX_DIR")" "0"
done

# ══════════════════════════════════════════════
suite "[AC10] 送信先ホストは 127.0.0.1 固定で環境変数で変えられない"
# ══════════════════════════════════════════════

hlog="$WORK/host.log"; : >"$hlog"
before="$(body_count "$CAP_DIR")"
timed_hook "$STDIN_DIR/SessionStart.json" PATH="$SHIM_PATH" SHIM_LOG="$hlog" LOOP_MONITOR_PORT="$CAP_PORT" \
  LOOP_MONITOR_HOST=203.0.113.9 MONITOR_HOST=203.0.113.9 LOOP_MONITOR_URL=http://203.0.113.9:1/x \
  LOOP_MONITOR_ENDPOINT=http://203.0.113.9:1/x LOOP_MONITOR_BASE_URL=http://203.0.113.9:1 \
  LOOP_HOST=203.0.113.9 HOST=203.0.113.9 HOSTNAME=203.0.113.9
ok=0
if wait_file "$CAP_DIR/body.$((before + 1))"; then ok=1; fi

it "[AC10] ホスト系の環境変数を設定しても、スタブ（127.0.0.1）へ届く"
if [ "$ok" -eq 1 ]; then pass; else fail "届かない"; fi

it "[AC10] curl の argv の URL は http://127.0.0.1:<port>/api/events のまま"
assert_file_contains "$hlog" "ARG http://127.0.0.1:${CAP_PORT}/api/events"

it "[AC10] argv に 203.0.113.9（設定した別ホスト）が現れない"
assert_file_not_contains "$hlog" "203.0.113.9"

# ══════════════════════════════════════════════
suite "[AC11] ペイロードは curl の argv に載らない（子プロセスの argv 全数）"
# ══════════════════════════════════════════════
# PATH の先頭に curl / jq / basename / dirname / sed / tr / cut / awk / head / tail / grep /
# od / expr / sort のラッパーを置き、フックが起動した子プロセスの argv を全て記録する。
# ps のスナップショットは取りこぼす（短命プロセスは見えない）。ラッパーは macOS / Linux で同じ。

check_argv() { # <ラベル> <番兵...>  （直前の emit で $ALOG が埋まっている前提）
  local label="$1" hits="" s; shift
  for s in "$@"; do
    if grep -qF -- "$s" "$ALOG"; then hits="$hits ${s}"; fi
  done
  it "[AC11] ${label}: 子プロセスの argv にペイロード由来の番兵が現れない"
  assert_eq "$(echo "$hits" | tr -s ' ')" ""
}

ALOG="$WORK/argv.log"; : >"$ALOG"
jq -c '.session_id = "ARGVSESS-1234" | .tool_use_id = "toolu_ARGVTUID"
  | .tool_input.command = "curl -H \"Authorization: Bearer ARGVSECRET1\" https://x.invalid/ARGVURL"
  | .tool_input.description = "ARGVDESC" | .tool_input.content = "ARGVCONTENT"' \
  "$STDIN_DIR/PreToolUse.bash.json" >"$IN"
emit "$IN" PATH="$SHIM_PATH" SHIM_LOG="$ALOG"

it "[AC11] Bash: ラッパー経由でも送信は成功する（観測が送信を壊していない）"
if [ -n "$BODY" ]; then pass; else fail "ボディが届かない"; fi
check_argv "Bash" ARGVSECRET1 ARGVDESC ARGVCONTENT ARGVURL ARGVSESS ARGVTUID

it "[AC11] Bash: 観測の自己診断（ラッパーが curl と jq の起動を記録している）"
if grep -qF "CMD curl" "$ALOG" && grep -qF "CMD jq" "$ALOG"; then pass
else fail "curl / jq の記録が無い。フックが PATH 経由で呼んでいない" "記録: $(tr '\n' ' ' <"$ALOG" | head -c 300)"; fi

it "[AC11] curl は --data-binary で stdin（@-）から本文を受ける"
assert_file_contains "$ALOG" "ARG @-"

: >"$ALOG"
jq -c '.session_id = "ARGVSESS-5678" | .tool_use_id = "toolu_ARGVTUID2"
  | .tool_input.file_path = "/ARGVDIR/sub/ARGVBASE.txt" | .tool_input.content = "ARGVCONTENT2"' \
  "$STDIN_DIR/PreToolUse.read.json" >"$IN"
emit "$IN" PATH="$SHIM_PATH" SHIM_LOG="$ALOG"
check_argv "Read（file_path）" ARGVDIR ARGVBASE ARGVCONTENT2 ARGVSESS ARGVTUID2

: >"$ALOG"
jq -c '.prompt = "ARGVPROMPT" | .session_id = "ARGVSESS-9999"' "$STDIN_DIR/UserPromptSubmit.json" >"$IN"
emit "$IN" PATH="$SHIM_PATH" SHIM_LOG="$ALOG"
check_argv "UserPromptSubmit（prompt）" ARGVPROMPT ARGVSESS

it "[AC11b] 一時ファイルを作らない（TMPDIR の差分が空）"
TD="$WORK/tmpdir"; mkdir -p "$TD"
timed_hook "$STDIN_DIR/PreToolUse.bash.json" TMPDIR="$TD" LOOP_MONITOR_PORT="$CAP_PORT"
sleep 0.5
assert_eq "$(find "$TD" -mindepth 1 | wc -l | tr -d ' ')" "0"

# ══════════════════════════════════════════════
suite "[AC12] settings.json への登録と既存フックの不変"
# ══════════════════════════════════════════════

FIRED_EVENTS="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse SubagentStart SubagentStop Stop PreCompact"

for ev in $FIRED_EVENTS; do
  it "[AC12] ${ev} に monitor-emit が登録されている（bash \$CLAUDE_PROJECT_DIR/.claude/hooks/monitor-emit.sh 形式）"
  n="$(jq --arg ev "$ev" '[.hooks[$ev][]?.hooks[]? | select(.type == "command" and (.command | test("^bash .*\\.claude/hooks/monitor-emit\\.sh( |$)")))] | length' "$SETTINGS")"
  if [ "${n:-0}" -ge 1 ]; then pass; else fail "登録が無い"; fi
done

for ev in PreToolUse PostToolUse; do
  it "[AC12] ${ev} の monitor-emit は全ツールを対象にする（matcher が無指定・空・'*'・'.*'）"
  n="$(jq --arg ev "$ev" '[.hooks[$ev][]? | select(any(.hooks[]?; (.command // "") | test("monitor-emit"))) | select((.matcher // "") | IN("", "*", ".*"))] | length' "$SETTINGS")"
  if [ "${n:-0}" -ge 1 ]; then pass; else fail "全ツール対象の登録が無い"; fi
done

it "[AC12] monitor-emit を取り除くと、既存フックの定義が main（基準 fixture）と jq 比較で完全一致"
actual="$(jq -S -c '
  .hooks
  | with_entries(.value |= (map(.hooks |= map(select((.command // "") | test("monitor-emit") | not))) | map(select((.hooks | length) > 0))))
  | with_entries(select((.value | length) > 0))' "$SETTINGS" 2>/dev/null)"
expected="$(jq -S -c . "$BASELINE")"
assert_eq "$actual" "$expected"

it "[AC12] 自己診断: 基準 fixture に既存 5 フックが全て入っている"
missing=""
for h in pre-tool-guard loop-guard post-tool-format stop-quality-check bootstrap-project; do
  grep -qF "$h" "$BASELINE" || missing="$missing $h"
done
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "[AC12] 5 つの既存フックが今の settings.json にも残っている"
missing=""
for h in pre-tool-guard loop-guard post-tool-format stop-quality-check bootstrap-project; do
  grep -qF "$h" "$SETTINGS" || missing="$missing $h"
done
assert_eq "$(echo "$missing" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "[AC14] 外部コマンドが暗黙に読む設定ファイル（.curlrc / .jq）でフックの挙動が変わらない"
# ══════════════════════════════════════════════
# G5 差し戻し(#18 retry 1)。curl は -q が無いと .curlrc を、jq は $HOME/.jq を暗黙に読む。
# 探索順は man curl の -K 節: 1) $CURL_HOME/.curlrc 2) $XDG_CONFIG_HOME/curlrc 3) $HOME/.curlrc。
# ここは本物の curl / jq が設定ファイルを読む挙動を見るので PATH ラッパーは使わない。
# 1 テスト 1 要因: HOME は常に空の一時ディレクトリへ差し替え（実ユーザーの設定を持ち込まない）、
# 設定ファイルの置き場所だけを変える。外部ホストへは一切接続せず、全部ローカルのスタブで検証する。

new_tmp_dir() { # <代入先の変数名>
  local __dest="$1" dir
  dir="$(mktemp -d)" || { echo "mktemp に失敗した" >&2; exit 1; }
  SANDBOXES+=("$dir")
  printf -v "$__dest" '%s' "$dir"
}

# 設定ファイルを置く。出力 CFG_ENV に env へ渡す変数（配列）を作る
CFG_ENV=(); RC_PATH=""
place_curlrc() { # <置き場> <homeディレクトリ> <cfgディレクトリ> <内容>
  local where="$1" home="$2" cfg="$3" content="$4"
  CFG_ENV=("HOME=$home")
  case "$where" in
    CURL_HOME) RC_PATH="$cfg/.curlrc"; CFG_ENV+=("CURL_HOME=$cfg") ;;
    # man curl（-K 節）は $XDG_CONFIG_HOME/curlrc（7.73.0 以降）。版差に備えて .curlrc も同内容で置く
    XDG_CONFIG_HOME) RC_PATH="$cfg/curlrc"; printf '%s\n' "$content" >"$cfg/.curlrc"; CFG_ENV+=("XDG_CONFIG_HOME=$cfg") ;;
    HOME) RC_PATH="$home/.curlrc" ;;
  esac
  printf '%s\n' "$content" >"$RC_PATH"
}

for where in CURL_HOME XDG_CONFIG_HOME HOME; do
  for kind in url connect-to trace-ascii; do
    new_tmp_dir C_HOME; new_tmp_dir C_CFG; new_tmp_dir C_OUT
    start_stub capture
    D_DIR="$S_DIR"; D_PORT="$S_PORT"     # おとり（設定ファイルが行き先を変えた時の受け皿）
    start_stub capture
    T_DIR="$S_DIR"; T_PORT="$S_PORT"     # 本来の宛先
    TRACE="$C_OUT/trace.txt"
    case "$kind" in
      url) rc="url = \"http://127.0.0.1:${D_PORT}/leak\"" ;;
      connect-to) rc="connect-to = \"127.0.0.1:${T_PORT}:127.0.0.1:${D_PORT}\"" ;;
      trace-ascii) rc="trace-ascii = \"${TRACE}\"" ;;
    esac
    place_curlrc "$where" "$C_HOME" "$C_CFG" "$rc"

    # 自己診断: 同じ設定ファイルが、-q 無しの本物の curl では実際に効く（効かない設定なら検査が空振り）
    env "${CFG_ENV[@]}" curl -s --noproxy '*' --connect-timeout 1 --max-time 3 -d SNTDIAG \
      "http://127.0.0.1:${T_PORT}/diag" >/dev/null 2>&1
    it "[AC14] 自己診断: ${where} の .curlrc（${kind}）は -q 無しの curl では実際に効く"
    case "$kind" in
      url) if [ "$(conn_count "$D_DIR")" -ge 1 ]; then pass; else fail "おとりへ接続が無い。設定が効いていない"; fi ;;
      connect-to)
        if [ "$(conn_count "$D_DIR")" -ge 1 ] && [ "$(conn_count "$T_DIR")" = "0" ]; then pass
        else fail "付け替わっていない: おとり=$(conn_count "$D_DIR") 宛先=$(conn_count "$T_DIR")"; fi ;;
      trace-ascii) if [ -s "$TRACE" ]; then pass; else fail "trace ファイルが作られない。設定が効いていない"; fi ;;
    esac
    d0="$(conn_count "$D_DIR")"
    rm -f "$TRACE"; DB0="$(body_count "$D_DIR")"

    saved_dir="$CAP_DIR"; saved_port="$CAP_PORT"
    CAP_DIR="$T_DIR"; CAP_PORT="$T_PORT"
    emit "$STDIN_DIR/PreToolUse.bash.json" "${CFG_ENV[@]}"
    sleep 0.5
    CAP_DIR="$saved_dir"; CAP_PORT="$saved_port"

    it "[AC14] ${where} に .curlrc（${kind}）を置いても、本来のスタブへ届く"
    if [ -n "$BODY" ]; then pass; else fail "本来の宛先に届かない（設定ファイルで送信先が変わった疑い）"; fi

    it "[AC14] ${where} に .curlrc（${kind}）を置いても、おとりへの接続は 0 件増"
    assert_eq "$(( $(conn_count "$D_DIR") - d0 ))" "0"

    it "[AC14] ${where} に .curlrc（${kind}）を置いても、おとりへボディが POST されない"
    assert_eq "$(( $(body_count "$D_DIR") - DB0 ))" "0"

    it "[AC14] ${where} に .curlrc（${kind}）を置いても、trace ファイルが作られずボディが書き出されない"
    if [ ! -e "$TRACE" ]; then pass; else fail "trace ファイルが作られた: $(head -c 200 "$TRACE")"; fi

    check_quiet "${where} / .curlrc ${kind}" AC14
  done
done

# ---------- .jq ----------

JQ_LEAK_VAR="SNTJQENVLEAK"; JQ_LEAK_VAL="SNTLEAKVALUE9"

# HOME を一時ディレクトリへ差し替え、$HOME/.jq に定義を置いてフックを走らせる
jq_home_case() { # <ラベル> <file|dir> <.jq の内容> <jq フィルタ（stdin 加工）>
  local label="$1" mode="$2" defs="$3" filter="$4"
  new_tmp_dir J_HOME
  case "$mode" in
    file) printf '%s\n' "$defs" >"$J_HOME/.jq" ;;
    dir) mkdir -p "$J_HOME/.jq"; printf '%s\n' "$defs" >"$J_HOME/.jq/.jq" ;;
  esac
  jq -c "$filter" "$STDIN_DIR/PreToolUse.read.json" >"$IN"
  emit "$IN" "HOME=$J_HOME" "${JQ_LEAK_VAR}=${JQ_LEAK_VAL}"
}

it "[AC14] 自己診断: \$HOME/.jq の test 上書きは jq 単体では実際に効く（改行入り値が通る）"
new_tmp_dir JD_HOME
printf '%s\n' 'def test($re): true;' >"$JD_HOME/.jq"
if [ "$(HOME="$JD_HOME" jq -n -r '"a\nb" | test("\\Aa\\z")' 2>/dev/null)" = "true" ]; then pass
else fail ".jq が効いていない。jq の版・探索が想定と違う"; fi

for mode in file dir; do
  jq_home_case "test 上書き" "$mode" 'def test($re): true;' '.session_id = "abc\nSNTNEWLINE" | .tool_name = "Read;evil"'
  it "[AC14] .jq（${mode}）で test を上書きしても、改行入り session_id・許可文字外 tool_name は送られない"
  if [ -z "$BODY" ]; then pass
  else
    sid="$(jq -r '.session_id // ""' "$BODY")"; tn="$(jq -r '.tool_name // ""' "$BODY")"
    case "${sid}${tn}" in
      *[!A-Za-z0-9_-]*) fail "検証を素通りした値が送信された: $(cat "$BODY")" ;;
      *) pass ;;
    esac
  fi
  check_quiet ".jq（${mode}）test 上書き" AC14

  jq_home_case "with_entries 上書き" "$mode" "def with_entries(f): . + {leak: \$ENV.${JQ_LEAK_VAR}};" '.'
  it "[AC14] .jq（${mode}）で with_entries を上書きしても、環境変数の番兵がボディに出ない"
  if [ -n "$BODY" ]; then
    case "$(cat "$BODY")" in
      *"$JQ_LEAK_VAL"*) fail "環境変数がボディに載った: $(cat "$BODY")" ;;
      *) pass ;;
    esac
  else fail "ボディが届かない（通常入力なので届くはず）"; fi
  check_quiet ".jq（${mode}）with_entries 上書き" AC14
done

# ══════════════════════════════════════════════
suite "[AC13] security.md「監視の限界（送信側）」と既知の限界"
# ══════════════════════════════════════════════

section="$(awk '/^#+ .*監視の限界（送信側）/ { f = 1; next } f && /^## / { f = 0 } f' "$SECURITY_MD" 2>/dev/null)"

it "[AC13] security.md に「監視の限界（送信側）」節がある"
if grep -qE '^#+ .*監視の限界（送信側）' "$SECURITY_MD"; then pass; else fail "節が無い"; fi

for term in "送る項目" "送らない項目" "既知の限界" "先頭トークン" ".curlrc" ".jq"; do
  it "[AC13] 節が「${term}」を書いている"
  assert_contains "$section" "$term"
done

SK_PREFIX="sk""-"
TOKEN="${SK_PREFIX}FAKE0TESTONLY0123456789abcdef"
known_limit_first_token_secret() {
  mk_stdin "$IN" "PreToolUse.bash" '.tool_input.command = $c' --arg c "${TOKEN} --flag"
  emit "$IN"
  [ -n "$BODY" ] || { echo "ボディが届かない"; return 1; }
  [ "$(jq -r '.bash_command' "$BODY")" = "$TOKEN" ] || { echo "想定した限界の挙動と違う: $(cat "$BODY")"; return 1; }
}
it "[AC13] 既知の限界: 先頭トークン自体が許可文字だけの秘密なら、ベース名として bash_command に載って送られる（設計上の限界として固定）"
assert_ok known_limit_first_token_secret

report
