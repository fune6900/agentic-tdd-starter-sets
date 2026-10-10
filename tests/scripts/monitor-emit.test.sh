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
# ── 変異テスト対応表（Issue #23 UsageSnapshot。実施済み。ただし末尾の「retry 2 で追加」の 3 行は実装後に実施する）──
#   防御を外す変異                         落ちるべきテスト（it 名の先頭タグ）
#   symlink 拒否（-L 判定）を外す          [US2] Stop: 最終要素が symlink（4 種）/ SubagentStop の symlink /
#                                          symlink 拒否の結果にリンク先の集計値が載らない
#   サイズ上限を外す / 超過判定を > にする  [US3] 上限がファイルサイズちょうど→ok / 1 バイト小さい→too_large（main・sub）
#   +1 バイトの打ち切り（head -c）を外す    ブラックボックスでは単独で検出できない（stat の判定が先に too_large にするため。
#                                          確認と読み取りの間の差し替えは競合で、security.md の限界に記録される範囲）。
#                                          Coder は実装の単体確認（head -c 上限+1 の存在）をレビューで見ること
#   環境変数で既定値を超えられる           [US3] 512MiB の疎ファイル × 上限 10^15 / 巨大桁 / 未設定 → いずれも too_large
#   環境変数の不正値を無視しない           [US3] 不正値（空・0・負・+・先頭ゼロ・全角・改行入り等）13 通り
#   FIFO を開く（-f の前に open する）      [US2] FIFO（not_regular_file）/ FIFO でも前景 1 秒未満
#   message.id による重複排除を外す         [US1] 同じ id が 2〜4 行 / 離れた位置の同じ id / 最後の行を採る（順序違い 2 通り）
#   部分合計を送る（不正行を飛ばして集計）  [US1] 正常 2 件 + 不正 1 件 / 不正な数値の全ケース（unknown のみ・models を持たない）
#   モデル ID の unknown 化を外す           [US1] 許可外のモデル ID 7 種 / model キー無し / [US3] 番兵入りモデル ID
#   番兵（本文・パス・id）を出力に通す      [US3] ボディに SNT / PATHSENT / msg_ が出ない / argv に出ない
#   パスを argv に載せる                   [US3] argv に transcript_path の値が現れない
#   agent_id の検証落ちを省略して送る       [US3] SubagentStop: agent_id が検証に落ちる（6 通り）
#   Stop に agent_id を付ける               [US1] Stop は stdin に agent_id があっても UsageSnapshot に付けない
#   全 0 の行を数える                       [US1] usage が全て 0 の行（<synthetic>）は数えない
#   5 分側への寄せ / cache_split_unknown    [US1] キャッシュ書き込みの内訳（8 通り）
#   前景で集計する（背景化しない）          [US4] 10MB 級 transcript の前景 1 秒未満（サーバ停止中・稼働中）
#   --- retry 2 で追加（G5 中指摘: 判定と読み取りの間の差し替え競合）。実装後に実施する ---
#   O_NONBLOCK を外す                       [US5] FIFO を渡す: ハングせず not_regular_file（タイムアウトで FAIL）/ 静的検査
#   O_NOFOLLOW を外す                       [US5] /dev/zero への symlink → symlink / 静的検査
#   fd 上の -f 判定（stat($fh)）を外す       [US5] /dev/zero（デバイス）・FIFO → not_regular_file・読み取りプロセスが残らない
#   名前での再オープンが残る                [US5] 静的検査（<"$tpath" / wc -c / head -c / [ -L|-e|-f "$tpath" ]）
#   --- Refactor で追加（G5 低指摘: PERL_UNICODE / PERLIO の :utf8 層）。実装後に実施する ---
#   env -u PERL_UNICODE -u PERLIO と binmode を外す  [US5] 環境に PERL_UNICODE=SDA / 空 / D / PERLIO=:utf8 があっても ok（動作テスト）
#   O_NOCTTY を外す                         [US5] 静的: O_NOCTTY が sysopen と同じ文に指定されている
#
# ── 検査の設計メモ ─────────────────────────────────────────────────────
#   - emitted fixture はキー・値とも stdin の純関数（ts 等の可変値をスキーマが持たない）。
#     よって [AC1] は「キー集合・型」と「値まで完全一致」を別 it で両方要求する。
#     UsageSnapshot の emitted は transcript 由来（#23）で hook-stdin 側に対応物が無いので対象外
#     （検査は末尾の「[US*] UsageSnapshot」節）。Stop / SubagentStop は UsageSnapshot が別に
#     届くので、emit() は UsageSnapshot 以外の最初のボディを BODY にする。
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
# Stop / SubagentStop は元のイベントに加えて UsageSnapshot（Issue #23）が別に届く。
# 到着順は不定なので、UsageSnapshot 以外の最初のボディを BODY にする（元のイベントの検査用）。
# BODY_REQ は BODY と対のリクエスト記録。UsageSnapshot の検査は後述の snap_run を使う。
BODY_REQ=""
emit() { # <stdin ファイル> [VAR=val ...]
  local in="$1" before ev want n last saved
  shift
  before="$(body_count "$CAP_DIR")"
  ev="$(jq -r '.hook_event_name // empty' "$in" 2>/dev/null)"
  timed_hook "$in" LOOP_MONITOR_PORT="$CAP_PORT" "$@"
  BODY=""; BODY_REQ=""
  case "$ev" in Stop|SubagentStop) want=2 ;; *) want=1 ;; esac
  wait_file "$CAP_DIR/body.$((before + 1))" || return 0
  if [ "$want" -eq 2 ]; then
    saved="$WAIT_ITERS"; WAIT_ITERS=50
    wait_file "$CAP_DIR/body.$((before + 2))"
    WAIT_ITERS="$saved"
  fi
  last="$(body_count "$CAP_DIR")"
  n=$((before + 1))
  while [ "$n" -le "$last" ]; do
    if [ "$(jq -r '.event // empty' "$CAP_DIR/body.$n" 2>/dev/null)" != "UsageSnapshot" ]; then
      BODY="$CAP_DIR/body.$n"; BODY_REQ="$CAP_DIR/req.$n"
      return 0
    fi
    n=$((n + 1))
  done
  # UsageSnapshot しか届いていない（元のイベントが届かなかった）。BODY は空のまま
  return 0
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
  if [ -n "$BODY" ] && [ -f "$BODY_REQ" ]; then
    req="$(cat "$BODY_REQ")"
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

it "[AC1] emitted 側で対応する hook-stdin が無いのは UsageSnapshot だけ（#23。transcript 由来の合成イベント）"
orphans=""
for e in "$EMITTED_DIR"/*.json; do
  n="$(basename "$e" .json)"
  [ -f "$STDIN_DIR/${n}.json" ] || orphans="$orphans $n"
done
assert_eq "$(echo "$orphans" | tr -s ' ')" " UsageSnapshot.main-ok UsageSnapshot.sub-ok UsageSnapshot.unknown"

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

# ══════════════════════════════════════════════
suite "[US0] UsageSnapshot（Issue #23）: 道具"
# ══════════════════════════════════════════════
# 仕様の正は event-schema.md「UsageSnapshot」。期待値は fixture（emitted/UsageSnapshot.*.json）と
# 仕様の規則から導く。フックを実際に実行し、capture スタブに届いたボディを検査する。

TR_DIR="$MON/test/fixtures/transcript"
US_DIR="$WORK/usage"
PATHSENT="$US_DIR/PATHSENT-dir"
mkdir -p "$PATHSENT"
SNAP=""; SNAP_N=0; SNAP_ITERS=150   # 0.02 秒刻み。既定の上限は 3 秒

snap_scan() { # <before> → 直近の実行以降に届いた UsageSnapshot を SNAP（最初の 1 通）/ SNAP_N（通数）に
  local before="$1" last n
  SNAP=""; SNAP_N=0
  last="$(body_count "$CAP_DIR")"
  n=$((before + 1))
  while [ "$n" -le "$last" ]; do
    if [ "$(jq -r '.event // empty' "$CAP_DIR/body.$n" 2>/dev/null)" = "UsageSnapshot" ]; then
      [ -z "$SNAP" ] && SNAP="$CAP_DIR/body.$n"
      SNAP_N=$((SNAP_N + 1))
    fi
    n=$((n + 1))
  done
}

snap_run() { # <stdin ファイル> [VAR=val ...]  → フック実行 + SNAP / SNAP_N
  local in="$1" before i=0
  shift
  before="$(body_count "$CAP_DIR")"
  timed_hook "$in" LOOP_MONITOR_PORT="$CAP_PORT" "$@"
  if [ "$HOOK_MISSING" -eq 1 ]; then SNAP=""; SNAP_N=0; return 0; fi
  snap_scan "$before"
  while [ -z "$SNAP" ] && [ "$i" -lt "$SNAP_ITERS" ]; do sleep 0.02; i=$((i + 1)); snap_scan "$before"; done
  if [ -n "$SNAP" ]; then sleep 0.25; snap_scan "$before"; fi   # 2 通目（重複送信）を拾うための猶予
}

snap_run_none() { # 届かないことの検査用（待ち時間を短くする）
  local saved="$SNAP_ITERS"
  SNAP_ITERS=60
  snap_run "$@"
  SNAP_ITERS="$saved"
}

mk_main() { jq -c --arg p "$2" '.transcript_path = $p' "$STDIN_DIR/Stop.json" >"$1"; }                  # <out> <transcript>
mk_sub() { jq -c --arg p "$2" '.agent_transcript_path = $p' "$STDIN_DIR/SubagentStop.json" >"$1"; }     # <out> <transcript>
run_main() { local f="$1"; shift; mk_main "$IN" "$f"; snap_run "$IN" "$@"; }   # <transcript> [env...]
run_sub() { local f="$1"; shift; mk_sub "$IN" "$f"; snap_run "$IN" "$@"; }

# transcript の行を作る（assistant）。usage は 4 種 + 5 分側の内訳が合う形
asst_raw() { # <id> <model の JSON> <input> <output> <cache_creation> <cache_read>
  jq -n -c --arg id "$1" --argjson m "$2" --argjson i "$3" --argjson o "$4" --argjson cc "$5" --argjson cr "$6" \
    '{type:"assistant",message:{id:$id,model:$m,usage:{input_tokens:$i,output_tokens:$o,cache_creation_input_tokens:$cc,cache_read_input_tokens:$cr,cache_creation:{ephemeral_5m_input_tokens:$cc,ephemeral_1h_input_tokens:0}}}}'
}
asst() { asst_raw "$1" "\"$2\"" "$3" "$4" "$5" "$6"; }   # <id> <model> <in> <out> <cc> <cr>
asst_u() { # <id> <model> <usage の JSON>
  jq -n -c --arg id "$1" --arg m "$2" --argjson u "$3" '{type:"assistant",message:{id:$id,model:$m,usage:$u}}'
}
MODEL_OK="claude-haiku-4-5-20251001"

ok_case() { # <ラベル> <jq 式（models などを取り出す）> <期待する JSON>
  it "[US1] $1"
  if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"; return; fi
  assert_eq "$(jq -c "[.usage_status, ($2)]" "$SNAP" 2>/dev/null)|$SNAP_N" "[\"ok\",$3]|1"
}
unk_case() { # <ラベル> <理由>
  it "[US1] $1 → unknown/$2 を 1 通だけ送り、models を持たない（部分合計を送らない）"
  if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"; return; fi
  assert_eq "$(jq -c '[.schema_version,.event,.usage_status,.unknown_reason,has("models")]' "$SNAP" 2>/dev/null)|$SNAP_N" "[2,\"UsageSnapshot\",\"unknown\",\"$2\",false]|1"
}
tr_path() { printf '%s/%s' "$US_DIR" "$1"; }

# ══════════════════════════════════════════════
suite "[US1] 集計: fixture と emitted の一致・帰属"
# ══════════════════════════════════════════════

run_main "$TR_DIR/main.jsonl"
it "[US1] Stop + main.jsonl → emitted/UsageSnapshot.main-ok.json と値まで一致（1 通だけ）"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -S -c . "$SNAP")|$SNAP_N" "$(jq -S -c . "$EMITTED_DIR/UsageSnapshot.main-ok.json")|1"; fi
check_quiet "Stop + main.jsonl" US4
# 基本の 1 通すら届かない（送信されない）なら、以降の「届くはず」の検査は待たずに FAIL させる（Red の所要時間を抑える）
if [ -z "$SNAP" ]; then
  echo "       (UsageSnapshot が届かない。以降の待ち時間を短縮する)"
  SNAP_ITERS=3
fi

run_sub "$TR_DIR/sub.jsonl"
it "[US1] SubagentStop + sub.jsonl → emitted/UsageSnapshot.sub-ok.json と値まで一致（agent_id 付き・1 通だけ）"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -S -c . "$SNAP")|$SNAP_N" "$(jq -S -c . "$EMITTED_DIR/UsageSnapshot.sub-ok.json")|1"; fi
check_quiet "SubagentStop + sub.jsonl" US4

mk_main "$IN" "$TR_DIR/main.jsonl"
jq -c '.agent_id = "aaaaaaaaaaaaaaaaa" | .agent_transcript_path = "/nonexistent/sub.jsonl"' "$IN" >"$IN.2"
snap_run "$IN.2"
it "[US1] Stop は stdin に agent_id があっても UsageSnapshot に付けず、transcript_path（メイン）を読む"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -S -c . "$SNAP")" "$(jq -S -c . "$EMITTED_DIR/UsageSnapshot.main-ok.json")"; fi

mk_sub "$IN" "$TR_DIR/sub.jsonl"
jq -c --arg p "$TR_DIR/main.jsonl" '.transcript_path = $p' "$IN" >"$IN.2"
snap_run "$IN.2"
it "[US1] SubagentStop は agent_transcript_path（サブ）を読み、transcript_path（メイン）は読まない"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -S -c . "$SNAP")" "$(jq -S -c . "$EMITTED_DIR/UsageSnapshot.sub-ok.json")"; fi

mk_main "$IN" "$TR_DIR/main.jsonl"
it "[US1] 元の Stop は schema_version 1 のまま（UsageSnapshot だけが 2）"
emit "$IN"
if [ -n "$BODY" ]; then assert_eq "$(jq -c '[.event,.schema_version]' "$BODY")" '["Stop",1]'; else fail "Stop が届かない"; fi

# ══════════════════════════════════════════════
suite "[US1] 集計: 重複排除・全 0 の行・非 assistant"
# ══════════════════════════════════════════════

for k in 2 3 4; do
  f="$(tr_path "dup${k}.jsonl")"
  { for _ in $(seq 1 "$k"); do asst msg_D "$MODEL_OK" 10 20 30 40; done; } >"$f"
  run_main "$f"
  ok_case "同じ message.id の行が ${k} 行 → 1 件として数える（水増ししない）" \
    '[.models[0].message_count,.models[0].input_tokens,.models[0].output_tokens,.models[0].cache_creation_5m_input_tokens,.models[0].cache_read_input_tokens]' '[1,10,20,30,40]'
done

f="$(tr_path dup-nonadjacent.jsonl)"
{ asst msg_P "$MODEL_OK" 1 2 3 4; asst msg_Q "$MODEL_OK" 10 20 30 40; asst msg_P "$MODEL_OK" 1 2 3 4; } >"$f"
run_main "$f"
ok_case "離れた位置の同じ id も 1 件に畳む（msg_P ×2 + msg_Q → 2 件）" \
  '[.models[0].message_count,.models[0].input_tokens,.models[0].output_tokens]' '[2,11,22]'

f="$(tr_path last-wins.jsonl)"
{ asst msg_L "$MODEL_OK" 1 1 1 1; asst msg_L "$MODEL_OK" 5 7 9 11; } >"$f"
run_main "$f"
ok_case "同じ id で usage が違う → 最後の行を採る" \
  '[.models[0].message_count,.models[0].input_tokens,.models[0].output_tokens,.models[0].cache_creation_5m_input_tokens,.models[0].cache_read_input_tokens]' '[1,5,7,9,11]'

f="$(tr_path last-wins-rev.jsonl)"
{ asst msg_L "$MODEL_OK" 5 7 9 11; asst msg_L "$MODEL_OK" 1 1 1 1; } >"$f"
run_main "$f"
ok_case "同じ id で usage が違う（順序を逆に）→ やはり最後の行（先頭を採る実装を弾く）" \
  '[.models[0].input_tokens,.models[0].output_tokens]' '[1,1]'

f="$(tr_path synthetic.jsonl)"
{ asst msg_R "$MODEL_OK" 3 4 5 6; asst_raw msg_S '"<synthetic>"' 0 0 0 0; asst msg_Z claude-zero 0 0 0 0; } >"$f"
run_main "$f"
ok_case "usage が全て 0 の行（<synthetic> ほか）は数えず、モデルの一覧にも載せない" \
  '[[.models[].model], .models[0].message_count]' '[["claude-haiku-4-5-20251001"],1]'

f="$(tr_path only-zero.jsonl)"
{ asst_raw msg_S '"<synthetic>"' 0 0 0 0; } >"$f"
run_main "$f"
ok_case "全 0 の行しか無い → ok で models は空配列（0 トークンが事実）" '.models' '[]'

f="$(tr_path empty.jsonl)"
: >"$f"
run_main "$f"
ok_case "空ファイル → ok で models は空配列" '.models' '[]'

f="$(tr_path nonassistant.jsonl)"
{
  asst msg_R "$MODEL_OK" 3 4 5 6
  printf '%s\n' '{"type":"user","message":{"id":"u1","usage":{"input_tokens":"bad"}}}'
  printf '%s\n' '{"type":"Assistant","message":{"id":"u2","model":"claude-x","usage":{"input_tokens":99}}}'
  printf '%s\n' '{"type":"cost-state","costUSD":1}'
  printf '%s\n' '{"type":"assistant","message":{"id":"nousage","model":"claude-y"}}'
  printf '%s\n' '{"type":"assistant","message":{"id":"strusage","model":"claude-y","usage":"x"}}'
  printf '%s\n' '{"type":"assistant"}'
} >"$f"
run_main "$f"
ok_case "type が文字列 assistant 以外の行（user / Assistant / cost-state）と usage を持たない行は無視する" \
  '[[.models[].model], .models[0].message_count]' '[["claude-haiku-4-5-20251001"],1]'

# ══════════════════════════════════════════════
suite "[US1] 集計: キャッシュ書き込みの内訳"
# ══════════════════════════════════════════════

cache_case() { # <ラベル> <usage の JSON> <期待 [5m, 1h, split_unknown]>
  local f
  f="$(tr_path cache.jsonl)"
  asst_u msg_K "$MODEL_OK" "$2" >"$f"
  run_main "$f"
  ok_case "$1" '[.models[0].cache_creation_5m_input_tokens,.models[0].cache_creation_1h_input_tokens,.models[0].cache_split_unknown]' "$3"
}
cache_case "内訳が合計と一致（30 + 70 = 100）→ そのまま使う" \
  '{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":30,"ephemeral_1h_input_tokens":70}}' '[30,70,false]'
cache_case "cache_creation オブジェクトが無い → 全量を 5 分側に入れ cache_split_unknown" \
  '{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":100}' '[100,0,true]'
cache_case "内訳の片方（1h）が欠ける → 全量を 5 分側に入れ cache_split_unknown" \
  '{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":30}}' '[100,0,true]'
cache_case "内訳の片方（5m）が欠ける → 全量を 5 分側に入れ cache_split_unknown" \
  '{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_1h_input_tokens":70}}' '[100,0,true]'
cache_case "内訳の合計が不一致（30 + 60 ≠ 100）→ 全量を 5 分側に入れ cache_split_unknown" \
  '{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":30,"ephemeral_1h_input_tokens":60}}' '[100,0,true]'
cache_case "内訳の合計が 1 だけ不一致（50 + 51 ≠ 100）→ cache_split_unknown（境界）" \
  '{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":50,"ephemeral_1h_input_tokens":51}}' '[100,0,true]'
cache_case "1h だけに全量（0 + 100）→ 1h 側に入れる（一致している）" \
  '{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":100}}' '[0,100,false]'

f="$(tr_path split-or.jsonl)"
{
  asst_u msg_K1 "$MODEL_OK" '{"input_tokens":1,"cache_creation_input_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":100,"ephemeral_1h_input_tokens":0}}'
  asst_u msg_K2 "$MODEL_OK" '{"input_tokens":1,"cache_creation_input_tokens":10}'
} >"$f"
run_main "$f"
ok_case "cache_split_unknown は 1 件でも合わないメッセージがあれば true（モデル内の OR）。合計は 5 分側へ" \
  '[.models[0].cache_creation_5m_input_tokens,.models[0].cache_creation_1h_input_tokens,.models[0].cache_split_unknown]' '[110,0,true]'

# ══════════════════════════════════════════════
suite "[US1] 集計: 速度・地域のフラグ"
# ══════════════════════════════════════════════

flag_case() { # <ラベル> <usage に足す JSON> <期待 [fast, us, variant_unknown]>
  local f u
  f="$(tr_path flags.jsonl)"
  u="$(jq -c --argjson x "$2" '{input_tokens:1,output_tokens:1,cache_creation_input_tokens:0,cache_read_input_tokens:0,cache_creation:{ephemeral_5m_input_tokens:0,ephemeral_1h_input_tokens:0}} + $x' <<<'{}')"
  asst_u msg_F "$MODEL_OK" "$u" >"$f"
  run_main "$f"
  ok_case "$1" '[.models[0].fast_mode,.models[0].us_inference,.models[0].variant_unknown]' "$3"
}
flag_case "speed / inference_geo のキーが無い → 全て false" '{}' '[false,false,false]'
flag_case "speed: null, inference_geo: null → 全て false" '{"speed":null,"inference_geo":null}' '[false,false,false]'
flag_case "speed: standard, inference_geo: not_available → 全て false" '{"speed":"standard","inference_geo":"not_available"}' '[false,false,false]'
flag_case "inference_geo: global → 通常（全て false）" '{"inference_geo":"global"}' '[false,false,false]'
flag_case "speed: fast → fast_mode" '{"speed":"fast"}' '[true,false,false]'
flag_case "inference_geo: us → us_inference" '{"inference_geo":"us"}' '[false,true,false]'
flag_case "speed が未知の値（turbo）→ variant_unknown" '{"speed":"turbo"}' '[false,false,true]'
flag_case "inference_geo が未知の値（eu）→ variant_unknown" '{"inference_geo":"eu"}' '[false,false,true]'
flag_case "speed が文字列でない（数値）→ variant_unknown" '{"speed":1}' '[false,false,true]'

f="$(tr_path flags-or.jsonl)"
{
  asst_u msg_F1 "$MODEL_OK" '{"input_tokens":1,"speed":"fast"}'
  asst_u msg_F2 "$MODEL_OK" '{"input_tokens":1,"inference_geo":"us"}'
  asst_u msg_F3 "$MODEL_OK" '{"input_tokens":1,"speed":"standard"}'
} >"$f"
run_main "$f"
ok_case "フラグは同じモデルの全メッセージの OR（fast と us が別メッセージでも両方立つ）" \
  '[.models[0].message_count,.models[0].fast_mode,.models[0].us_inference]' '[3,true,true]'

# ══════════════════════════════════════════════
suite "[US1] 集計: 不正な数値・JSON・上限"
# ══════════════════════════════════════════════

f="$(tr_path bad-num.jsonl)"
for v in 'null' '"5"' '-1' '1.5' 'true' '[]' '{}'; do
  asst_u msg_B "$MODEL_OK" "{\"input_tokens\":${v},\"output_tokens\":1}" >"$f"
  run_main "$f"
  unk_case "input_tokens が ${v}（非負整数でない）" invalid_usage
done
for key in output_tokens cache_creation_input_tokens cache_read_input_tokens; do
  for v in 'null' '-1'; do
    asst_u msg_B "$MODEL_OK" "{\"input_tokens\":1,\"${key}\":${v}}" >"$f"
    run_main "$f"
    unk_case "${key} が ${v}" invalid_usage
  done
done
asst_u msg_B "$MODEL_OK" '{"input_tokens":1,"cache_creation_input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":"x","ephemeral_1h_input_tokens":0}}' >"$f"
run_main "$f"
unk_case "cache_creation.ephemeral_5m_input_tokens が文字列" invalid_usage
asst_u msg_B "$MODEL_OK" '{"input_tokens":1,"cache_creation_input_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":-1}}' >"$f"
run_main "$f"
unk_case "cache_creation.ephemeral_1h_input_tokens が負数" invalid_usage

printf '%s\n' '{"type":"assistant","message":{"id":"msg_1","model":"claude-haiku-4-5","usage":{"input_tokens":1.0,"output_tokens":2}}}' >"$f"
run_main "$f"
ok_case "1.0 は整数として受理する（input_tokens: 1.0 → 1。jq の版により 1.0 のまま出る実装もあるので数値として比べる）" '[(.models[0].input_tokens | floor),.models[0].output_tokens]' '[1,2]'

asst_u msg_B "$MODEL_OK" '{"output_tokens":5}' >"$f"
run_main "$f"
ok_case "キーが無い数値は 0 として扱う（output_tokens だけ）" \
  '[.models[0].input_tokens,.models[0].output_tokens,.models[0].cache_read_input_tokens,.models[0].cache_creation_5m_input_tokens]' '[0,5,0,0]'

printf '%s\n' '{"type":"assistant","message":{"model":"claude-x","usage":{"input_tokens":5}}}' >"$f"
run_main "$f"
unk_case "usage を持つが message.id が無い行（トークンが 0 超）" invalid_usage
printf '%s\n' '{"type":"assistant","message":{"id":123,"model":"claude-x","usage":{"output_tokens":1}}}' >"$f"
run_main "$f"
unk_case "message.id が文字列でない行（トークンが 0 超）" invalid_usage
printf '%s\n' '{"type":"assistant","message":{"id":"","model":"claude-x","usage":{"cache_read_input_tokens":1}}}' >"$f"
run_main "$f"
unk_case "message.id が空文字列の行（トークンが 0 超）" invalid_usage
{ asst msg_R "$MODEL_OK" 3 4 5 6; printf '%s\n' '{"type":"assistant","message":{"model":"claude-x","usage":{"input_tokens":0,"output_tokens":0}}}'; } >"$f"
run_main "$f"
ok_case "usage を持つが message.id が無い行でも、トークンが全て 0 なら無視する" '[[.models[].model]]' '[["claude-haiku-4-5-20251001"]]'

{ asst msg_R "$MODEL_OK" 3 4 5 6; printf '%s\n' '{broken json'; } >"$f"
run_main "$f"
unk_case "JSON として読めない行がある" parse_failed
{ asst msg_R "$MODEL_OK" 3 4 5 6; printf '%s' '{"type":"assistant"'; } >"$f"
run_main "$f"
unk_case "途中で切れた最終行（改行なし）" parse_failed
{ asst_u msg_B "$MODEL_OK" '{"input_tokens":-1}'; printf '%s\n' 'not json'; } >"$f"
run_main "$f"
unk_case "parse_failed と invalid_usage が両方該当 → parse_failed が優先" parse_failed

{ asst_u msg_B "$MODEL_OK" '{"input_tokens":-1}'; for n in 1 2 3 4 5 6 7 8 9; do asst "msg_M$n" "claude-m$n" 1 1 0 0; done; } >"$f"
run_main "$f"
unk_case "invalid_usage と too_many_models が両方該当 → invalid_usage が優先" invalid_usage

{ for n in 1 2 3 4 5 6 7 8 9; do asst "msg_M$n" "claude-m$n" 1 1 0 0; done; asst msg_BIG claude-m1 1000000000001 0 0 0; } >"$f"
run_main "$f"
unk_case "too_many_models と out_of_range が両方該当 → too_many_models が優先" too_many_models

# out_of_range（キー別の上限 10^12）
for key in input_tokens output_tokens cache_read_input_tokens; do
  asst_u msg_B "$MODEL_OK" "{\"${key}\":1000000000001}" >"$f"
  run_main "$f"
  unk_case "${key} が 10^12 + 1（1 行で上限超過）" out_of_range
done
asst_u msg_B "$MODEL_OK" '{"cache_creation_input_tokens":1000000000001,"cache_creation":{"ephemeral_5m_input_tokens":1000000000001,"ephemeral_1h_input_tokens":0}}' >"$f"
run_main "$f"
unk_case "cache_creation_5m が 10^12 + 1" out_of_range
{ asst msg_B1 "$MODEL_OK" 600000000000 0 0 0; asst msg_B2 "$MODEL_OK" 600000000000 0 0 0; } >"$f"
run_main "$f"
unk_case "2 行の合計が 1.2 × 10^12（合計値で上限判定）" out_of_range
{ asst msg_B1 "$MODEL_OK" 600000000000 0 0 0; asst msg_B2 "$MODEL_OK" 400000000000 0 0 0; } >"$f"
run_main "$f"
ok_case "合計がちょうど 10^12 → ok（上限ちょうどは通す）" '[.models[0].input_tokens]' '[1000000000000]'

# モデル数
f="$(tr_path models9.jsonl)"
{ for n in 1 2 3 4 5 6 7 8 9; do asst "msg_M$n" "claude-m$n" 1 1 0 0; done; } >"$f"
run_main "$f"
unk_case "異なるモデルが 9 種" too_many_models

f="$(tr_path models8.jsonl)"
{ for n in 8 7 6 5 4 3 2 1; do asst "msg_M$n" "claude-m$n" 1 1 0 0; done; } >"$f"
run_main "$f"
ok_case "異なるモデルが 8 種 → ok（境界）。model の昇順で並ぶ" '[.models | length, [.[].model]]' '[8,["claude-m1","claude-m2","claude-m3","claude-m4","claude-m5","claude-m6","claude-m7","claude-m8"]]'

f="$(tr_path models-bytes-order.jsonl)"
{ asst msg_1 claude-b 1 1 0 0; asst msg_2 Zeta 1 1 0 0; asst msg_3 claude-a 1 1 0 0; asst msg_4 a.b_c-1 1 1 0 0; } >"$f"
run_main "$f"
ok_case "並び順はバイト順の昇順（大文字 → 小文字）" '[.models[].model]' '["Zeta","a.b_c-1","claude-a","claude-b"]'

# モデル ID の unknown 化
f="$(tr_path model-unknown.jsonl)"
{
  asst_raw msg_U1 "$(jq -n --arg m 'bad model' '$m')" 1 10 0 0
  asst_raw msg_U2 "$(jq -n --arg m $'a\nb' '$m')" 2 20 0 0
  asst_raw msg_U3 "$(jq -n --arg m "$(printf 'a%.0s' $(seq 1 65))" '$m')" 4 40 0 0
  asst_raw msg_U4 '""' 8 80 0 0
  asst_raw msg_U5 'null' 16 160 0 0
  asst_raw msg_U6 '123' 32 320 0 0
  asst_raw msg_U7 '"SNTMODEL/../x"' 64 640 0 0
  asst msg_U8 "$MODEL_OK" 128 1280 0 0
} >"$f"
run_main "$f"
ok_case "許可外のモデル ID（空白・改行・65 バイト・空・null・数値・'/'）は unknown に合算し、1 要素にまとめる" \
  '[[.models[].model], (.models[] | select(.model == "unknown") | [.message_count,.input_tokens,.output_tokens])]' '[["claude-haiku-4-5-20251001","unknown"],[7,127,1270]]'

f="$(tr_path model-nokey.jsonl)"
{ printf '%s\n' '{"type":"assistant","message":{"id":"msg_N1","usage":{"input_tokens":3,"output_tokens":4}}}'; } >"$f"
run_main "$f"
ok_case "model キー自体が無い行は unknown" '[[.models[].model]]' '[["unknown"]]'

f="$(tr_path model-64.jsonl)"
M64="$(printf 'a%.0s' $(seq 1 64))"
{ asst msg_6 "$M64" 1 1 0 0; } >"$f"
run_main "$f"
ok_case "64 バイトちょうどのモデル ID はそのまま通す（境界）" '[[.models[].model | length]]' '[[64]]'

f="$(tr_path model-unknown-count.jsonl)"
{ for n in 1 2 3 4 5 6 7; do asst "msg_M$n" "claude-m$n" 1 1 0 0; done; asst msg_X1 "bad one" 1 1 0 0; asst msg_X2 "bad two" 1 1 0 0; } >"$f"
run_main "$f"
ok_case "unknown に落ちた複数のモデルは 1 種として数える（7 種 + unknown = 8 種 → ok）" '[.models | length]' '[8]'

# 部分合計を送らない
f="$(tr_path partial.jsonl)"
{ asst msg_R "$MODEL_OK" 3 4 5 6; asst msg_R2 "$MODEL_OK" 30 40 50 60; asst_u msg_BAD "$MODEL_OK" '{"output_tokens":-3}'; } >"$f"
run_main "$f"
unk_case "正常な行 2 件 + 不正な行 1 件 → 正常分だけの部分合計を送らない" invalid_usage

# ══════════════════════════════════════════════
suite "[US2] 読み取り: パスの判定（no_path）"
# ══════════════════════════════════════════════

nopath_case() { # <ラベル> <Stop の stdin を作る jq 式>
  jq -c "$2" "$STDIN_DIR/Stop.json" >"$IN"
  snap_run "$IN"
  unk_case "Stop: $1" no_path
}
nopath_case "transcript_path のキーが無い" 'del(.transcript_path)'
nopath_case "transcript_path が数値" '.transcript_path = 123'
nopath_case "transcript_path が null" '.transcript_path = null'
nopath_case "transcript_path が空文字列" '.transcript_path = ""'
nopath_case "transcript_path が相対パス" '.transcript_path = "rel/main.jsonl"'
nopath_case "transcript_path が C0 制御文字（\\u0001）を含む" '.transcript_path = "/tmp/a\u0001b.jsonl"'
nopath_case "transcript_path が改行を含む" '.transcript_path = "/tmp/a\nb.jsonl"'
nopath_case "transcript_path が DEL（\\u007f）を含む" '.transcript_path = "/tmp/a\u007fb.jsonl"'

LONGPATH="$("$PERL_BIN" -e 'print "/" . ("a" x 4096)')"
jq -c --arg p "$LONGPATH" '.transcript_path = $p' "$STDIN_DIR/Stop.json" >"$IN"
snap_run "$IN"
unk_case "Stop: transcript_path が 4097 バイト（上限 4096 超）" no_path

LONGPATH="$("$PERL_BIN" -e 'print "/" . ("a" x 4095)')"
jq -c --arg p "$LONGPATH" '.transcript_path = $p' "$STDIN_DIR/Stop.json" >"$IN"
snap_run "$IN"
unk_case "Stop: transcript_path が 4096 バイトちょうど（形式は有効。存在しないので read_failed）" read_failed

jq -c 'del(.agent_transcript_path)' "$STDIN_DIR/SubagentStop.json" >"$IN"
jq -c --arg p "$TR_DIR/main.jsonl" '.transcript_path = $p' "$IN" >"$IN.2"
snap_run "$IN.2"
unk_case "SubagentStop: agent_transcript_path が無い（transcript_path が有効でも流用しない）" no_path

jq -c --arg p "$TR_DIR/sub.jsonl" 'del(.transcript_path) | .agent_transcript_path = $p' "$STDIN_DIR/Stop.json" >"$IN"
snap_run "$IN"
unk_case "Stop: transcript_path が無い（agent_transcript_path が有効でも流用しない）" no_path

# ══════════════════════════════════════════════
suite "[US2] 読み取り: symlink・通常ファイル以外・存在しない"
# ══════════════════════════════════════════════

cp "$TR_DIR/sub.jsonl" "$US_DIR/real.jsonl"
ln -s "$US_DIR/real.jsonl" "$US_DIR/link-to-file.jsonl"
ln -s "$US_DIR/does-not-exist.jsonl" "$US_DIR/link-dangling.jsonl"
mkdir -p "$US_DIR/realdir"
ln -s "$US_DIR/realdir" "$US_DIR/link-to-dir"
ln -s "$US_DIR/real.jsonl" "$US_DIR/link-chain1.jsonl"
ln -s "$US_DIR/link-chain1.jsonl" "$US_DIR/link-chain2.jsonl"

for l in link-to-file.jsonl link-dangling.jsonl link-to-dir link-chain2.jsonl; do
  run_main "$US_DIR/$l"
  unk_case "Stop: 最終要素が symlink（${l}）" symlink
done
run_sub "$US_DIR/link-to-file.jsonl"
unk_case "SubagentStop: 最終要素が symlink" symlink

# 内容の流出も起きない（symlink 先の内容が数値として載らない）
it "[US2] symlink を拒否した結果に、リンク先の集計値（トークン数）が一切載らない"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else
  case "$(cat "$SNAP")" in *14242*|*'"models"'*) fail "リンク先の内容が載った: $(cat "$SNAP")" ;; *) pass ;; esac
fi

mkdir -p "$US_DIR/realparent"
cp "$TR_DIR/sub.jsonl" "$US_DIR/realparent/sub.jsonl"
ln -s "$US_DIR/realparent" "$US_DIR/linkparent"
run_sub "$US_DIR/linkparent/sub.jsonl"
it "[US2] 親ディレクトリが symlink でも拒否しない（最終要素のみ判定。限界として security.md に記録）"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -S -c . "$SNAP")" "$(jq -S -c . "$EMITTED_DIR/UsageSnapshot.sub-ok.json")"; fi

run_main "$US_DIR/realdir"
unk_case "Stop: ディレクトリ" not_regular_file

FIFO="$US_DIR/fifo.jsonl"
mkfifo "$FIFO"
run_main "$FIFO"
unk_case "Stop: FIFO（開かずに判定する）" not_regular_file
it "[US2] FIFO でもフックの前景は 1 秒未満で終わり、ハングしない"
if awk -v t="$T_ELAPSED" 'BEGIN { exit !(t < 1) }'; then pass; else fail "前景が ${T_ELAPSED} 秒"; fi
check_quiet "FIFO" US4
# 開いたまま待っている実装がいた場合のための後始末（RDWR で開けば待ちが解ける）
exec 8<>"$FIFO"
exec 8>&-

run_main "$US_DIR/no-such-file.jsonl"
unk_case "Stop: 存在しないファイル" read_failed

it "[US2] 読み取り権限が無いファイル → read_failed"
if [ "$(id -u)" = "0" ]; then
  echo "       (root では権限拒否を再現できないので省略)"; pass
else
  cp "$TR_DIR/sub.jsonl" "$US_DIR/noperm.jsonl"
  chmod 000 "$US_DIR/noperm.jsonl"
  run_main "$US_DIR/noperm.jsonl"
  if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
  else assert_eq "$(jq -c '[.usage_status,.unknown_reason,has("models")]' "$SNAP")|$SNAP_N" '["unknown","read_failed",false]|1'; fi
  chmod 600 "$US_DIR/noperm.jsonl"
fi

# ══════════════════════════════════════════════
suite "[US5] 判定と読み取りの間の差し替え競合: パスは 1 回だけ開き、fd 上で判定する（retry 2）"
# ══════════════════════════════════════════════
# 差し替え競合そのものは決定的に再現できない。名前での事前判定が無くても fd 上の判定だけで
# 拒否できること（静的検査 + 事前判定を素通りする入力の動作）を固定する。
#
# 契約（Coder へ）:
#   perl の sysopen($fh, $p, O_RDONLY|O_NONBLOCK|O_NOFOLLOW) を 1 回だけ → 失敗が ELOOP なら symlink、
#   不在は read_failed（既存どおり）、その他の失敗も read_failed。stat($fh) が通常ファイルでなければ
#   not_regular_file、サイズが上限超なら too_large、sysread で上限 + 1 バイトまで読み超えたら too_large。
#   読んだ内容は stdout 経由で jq へ（argv・一時ファイルに載せない）。perl / Fcntl が無ければ読まず read_failed。

HOOK_CODE="$WORK/hook-code.txt"
grep -v '^[[:space:]]*#' "$HOOK" >"$HOOK_CODE" 2>/dev/null

static_absent() { # <ラベル> <ERE>
  it "[US5] 静的: フック本体に ${1} が残っていない"
  if [ ! -s "$HOOK_CODE" ]; then fail "フックが読めない"; return; fi
  if grep -Eq -- "$2" "$HOOK_CODE"; then fail "残っている: $(grep -En -- "$2" "$HOOK_CODE" | head -3)"; else pass; fi
}
static_present() { # <ラベル> <ERE>
  it "[US5] 静的: フック本体に ${1} がある"
  if grep -Eq -- "$2" "$HOOK_CODE" 2>/dev/null; then pass; else fail "見つからない: $2"; fi
}
static_absent 'transcript パスの入力リダイレクト（<"$tpath"）' '<[[:space:]]*"?\$\{?tpath'
static_absent 'wc -c（サイズを名前で開いて数える）' '(^|[^[:alnum:]_])wc[[:space:]]+-c'
static_absent 'head -c（名前で開いて読む）' '(^|[^[:alnum:]_])head[[:space:]]+-c'
static_absent 'パスを名前で判定する [ -L|-e|-f "$tpath" ]' '\[[[:space:]]+!?[[:space:]]*-[LefdpSb][[:space:]]+"?\$\{?tpath'
static_present 'perl の sysopen' 'sysopen'
static_present 'sysopen の O_NOFOLLOW' 'O_NOFOLLOW'
static_present 'sysopen の O_NONBLOCK' 'O_NONBLOCK'
# sysopen と同じ文: 改行を空白に潰した上で `sysopen[^;]*<フラグ>` を見る。`[^;]*` は perl の文区切り `;` に依存し、
# sysopen の呼び出しと別の文にあるフラグ（他所の定数参照など）を拾わない。引数に `;` を書く変更をすると誤って落ちる。
sysopen_flag_same_stmt() { # <フラグ> ... （全てが同じ sysopen 文に要る）
  local f
  for f in "$@"; do
    tr '\n' ' ' <"$HOOK_CODE" | grep -Eq "sysopen[^;]*${f}" || return 1
  done
}
it "[US5] 静的: O_NOFOLLOW と O_NONBLOCK が sysopen と同じ文に指定されている（取り違えの防止）"
if sysopen_flag_same_stmt O_NOFOLLOW O_NONBLOCK; then pass
else fail "sysopen の引数に O_NOFOLLOW と O_NONBLOCK が両方無い"; fi
it "[US5] 静的: O_NOCTTY が sysopen と同じ文に指定されている（制御端末の奪取防止）"
if sysopen_flag_same_stmt O_NOCTTY; then pass
else fail "sysopen の引数に O_NOCTTY が無い"; fi
static_present 'fd 上の stat（stat($fh) 等）' 'stat[[:space:]]*\(?[[:space:]]*\$?[A-Za-z_]*(fh|FH|F)\b|-f[[:space:]]+\$?[A-Za-z_]*(fh|FH)\b|fstat'

# perl の入出力層を変える環境変数が利用者側にあっても、読み取りが壊れない（G5 低指摘）。
# PERL_UNICODE / PERLIO=:utf8 が sysopen の fd に :utf8 層を付け、sysread が致命的エラー → read_failed になっていた。
run_main "$TR_DIR/main.jsonl" X_UNUSED=1
PERLENV_BASE="$(jq -S -c . "$SNAP" 2>/dev/null)"
for penv in 'PERL_UNICODE=SDA' 'PERL_UNICODE=' 'PERL_UNICODE=D' 'PERLIO=:utf8'; do
  run_main "$TR_DIR/main.jsonl" "$penv"
  it "[US5] 環境に ${penv} があっても ok で、数値が環境変数なしと同一（read_failed にならない）"
  if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
  else
    assert_eq "$(jq -c '.usage_status' "$SNAP")|$(jq -S -c . "$SNAP")|$SNAP_N" "\"ok\"|${PERLENV_BASE}|1"
  fi
done

# 同じ入力で UsageSnapshot が届いてから 1.5 秒後に、フックと同じセッション（pgid）に残る生きたプロセス数を LEAK_N に。
# 残っていれば kill して後始末する。
LEAK_N=0
leak_run() { # <stdin ファイル>
  local in="$1" before i=0 pg alive
  before="$(body_count "$CAP_DIR")"
  pg="$(env LOOP_MONITOR_PORT="$CAP_PORT" "$PERL_BIN" -MPOSIX -e '
    my $p = fork();
    if ($p == 0) { setsid(); open(STDIN, "<", $ARGV[0]) or exit 1; open(STDOUT, ">", "/dev/null"); open(STDERR, ">", "/dev/null"); exec @ARGV[1..$#ARGV]; exit 1 }
    print $p; waitpid($p, 0);
  ' "$in" "$BASH_BIN" "$HOOK" 2>/dev/null)"
  snap_scan "$before"
  while [ -z "$SNAP" ] && [ "$i" -lt "$SNAP_ITERS_US5" ]; do sleep 0.02; i=$((i + 1)); snap_scan "$before"; done
  sleep 1.5
  LEAK_N=0
  case "$pg" in ''|*[!0-9]*) return 0 ;; esac
  alive="$(ps -A -o pgid=,stat= 2>/dev/null | awk -v g="$pg" '$1 == g && $2 !~ /^Z/ { n++ } END { print n + 0 }')"
  LEAK_N="$alive"
  if [ "$alive" -gt 0 ]; then kill -KILL -- "-$pg" 2>/dev/null; fi
}
SNAP_ITERS_US5=150   # 3 秒

US5_FIFO="$US_DIR/us5-fifo.jsonl"
mkfifo "$US5_FIFO"
mk_main "$IN" "$US5_FIFO"
leak_run "$IN"
unk_case "Stop: FIFO を直接渡してもハングせず（3 秒以内に届く）" not_regular_file
it "[US5] FIFO: 背景の読み取りプロセスが残らない（open でブロックしたままの bash が居ない）"
if [ "$LEAK_N" = "0" ]; then pass; else fail "残留 ${LEAK_N} 本"; fi
exec 9<>"$US5_FIFO"; exec 9>&-   # 念のため待ちを解く

ln -s /dev/zero "$US_DIR/us5-link-zero"
mk_main "$IN" "$US_DIR/us5-link-zero"
leak_run "$IN"
unk_case "Stop: /dev/zero への symlink（辿って無制限に読まない）" symlink
it "[US5] /dev/zero への symlink: 背景の読み取りプロセスが残らない"
if [ "$LEAK_N" = "0" ]; then pass; else fail "残留 ${LEAK_N} 本"; fi
mk_sub "$IN" "$US_DIR/us5-link-zero"
leak_run "$IN"
unk_case "SubagentStop: /dev/zero への symlink" symlink

mk_main "$IN" /dev/zero
leak_run "$IN"
unk_case "Stop: /dev/zero そのもの（キャラクタデバイス）" not_regular_file
it "[US5] /dev/zero そのもの: 背景の読み取りプロセスが残らない"
if [ "$LEAK_N" = "0" ]; then pass; else fail "残留 ${LEAK_N} 本"; fi
mk_sub "$IN" /dev/zero
leak_run "$IN"
unk_case "SubagentStop: /dev/zero そのもの" not_regular_file

# ══════════════════════════════════════════════
suite "[US2] 読み取り: サイズ上限（LOOP_MONITOR_MAX_TRANSCRIPT_BYTES）"
# ══════════════════════════════════════════════

ENV_MAX=LOOP_MONITOR_MAX_TRANSCRIPT_BYTES
SUB_SIZE="$(wc -c <"$TR_DIR/sub.jsonl" | tr -d ' ')"
MAIN_SIZE="$(wc -c <"$TR_DIR/main.jsonl" | tr -d ' ')"

run_sub "$TR_DIR/sub.jsonl" "$ENV_MAX=$SUB_SIZE"
it "[US3] 上限がファイルサイズちょうど（${SUB_SIZE} バイト）→ ok"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -S -c . "$SNAP")|$SNAP_N" "$(jq -S -c . "$EMITTED_DIR/UsageSnapshot.sub-ok.json")|1"; fi

run_sub "$TR_DIR/sub.jsonl" "$ENV_MAX=$((SUB_SIZE - 1))"
unk_case "上限がファイルサイズより 1 バイト小さい（$((SUB_SIZE - 1)) バイト）" too_large

run_main "$TR_DIR/main.jsonl" "$ENV_MAX=$MAIN_SIZE"
it "[US3] Stop: 上限がファイルサイズちょうど（${MAIN_SIZE} バイト）→ ok"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -S -c . "$SNAP")|$SNAP_N" "$(jq -S -c . "$EMITTED_DIR/UsageSnapshot.main-ok.json")|1"; fi

run_main "$TR_DIR/main.jsonl" "$ENV_MAX=$((MAIN_SIZE - 1))"
it "[US3] Stop: 上限が 1 バイト小さい → too_large（emitted/UsageSnapshot.unknown.json と一致）"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -S -c . "$SNAP")|$SNAP_N" "$(jq -S -c . "$EMITTED_DIR/UsageSnapshot.unknown.json")|1"; fi

run_main "$TR_DIR/main.jsonl" "$ENV_MAX=1"
unk_case "上限 1 バイト" too_large

# 不正値は無視して既定値（既定値はサイズ上限の実測後に決まる。ここでは小さい fixture が通ることだけを見る）
for bad in '' '0' '-1' '+5' '007' 'abc' '1e3' '0x10' '1.5' '5 ' ' 5' $'5\n6' '００５'; do
  label="$(printf '%s' "$bad" | tr '\n' '~')"
  run_sub "$TR_DIR/sub.jsonl" "$ENV_MAX=$bad"
  it "[US3] 上限の環境変数が不正値（'${label}'）→ 無視して既定値（sub.jsonl は ok のまま）"
  if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
  else assert_eq "$(jq -c '.usage_status' "$SNAP")|$SNAP_N" '"ok"|1'; fi
done

# 既定値より大きくはできない（疎ファイルで、既定値を十分に超えるサイズを作る）
SPARSE="$US_DIR/sparse.jsonl"
"$PERL_BIN" -e 'open(F, ">", $ARGV[0]) or exit 1; truncate(F, $ARGV[1]) or exit 1; close(F);' "$SPARSE" $((512 * 1024 * 1024))
for big in 1000000000000000 99999999999999999999999999 ''; do
  if [ -n "$big" ]; then envarg="$ENV_MAX=$big"; else envarg="X_UNUSED=1"; fi
  run_main "$SPARSE" "$envarg"
  unk_case "512MiB の疎ファイル、上限の環境変数 '${big:-未設定}' → 既定値は超えられず too_large（読み取り量を増やす向きには使えない）" too_large
done
check_quiet "疎ファイル" US4

# ══════════════════════════════════════════════
suite "[US3] 安全: 番兵・パス・プロンプトが送信ボディにも argv にも出ない"
# ══════════════════════════════════════════════
# transcript には SNT 始まりの番兵（本文・プロンプト・パス・id・ブランチ等）が入っている。
# 送信ボディに載ってよいのは数値・真偽値・列挙値・許可文字を満たしたモデル ID だけ。

cp "$TR_DIR/main.jsonl" "$PATHSENT/main.jsonl"
ALOG="$WORK/us-argv.log"; : >"$ALOG"
jq -c --arg p "$PATHSENT/main.jsonl" '.transcript_path = $p | .session_id = "ARGVSESS-US1" | .last_assistant_message = "ARGVLAST"' "$STDIN_DIR/Stop.json" >"$IN"
snap_run "$IN" PATH="$SHIM_PATH" SHIM_LOG="$ALOG"

it "[US3] 観測が送信を壊していない（ラッパー経由でも UsageSnapshot が届き、内容が正しい）"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -c '[.usage_status,(.models|length),.models[0].message_count]' "$SNAP")" '["ok",1,3]'; fi

body_text=""; [ -n "$SNAP" ] && body_text="$(cat "$SNAP")"
for s in SNT PATHSENT msg_ ARGVLAST; do
  it "[US3] UsageSnapshot のボディに '${s}' が現れない"
  if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
  else case "$body_text" in *"$s"*) fail "ボディに現れた: $body_text" ;; *) pass ;; esac; fi
done

it "[US3] 自己診断: argv の記録に jq と curl の起動が残っている（観測が効いている）"
if grep -qF "CMD curl" "$ALOG" && grep -qF "CMD jq" "$ALOG"; then pass; else fail "記録が無い"; fi

hits=""
for s in SNT PATHSENT msg_ ARGVLAST ARGVSESS SNTPROMPT SNTTEXT SNTBRANCH SNTUUID; do
  if grep -qF -- "$s" "$ALOG"; then hits="$hits $s"; fi
done
it "[US3] jq / curl / その他の子プロセスの argv に transcript の番兵・パス・プロンプトが現れない"
assert_eq "$(echo "$hits" | tr -s ' ')" ""

it "[US3] argv に transcript_path の値（ディレクトリ名）が現れない"
if grep -qF -- "$PATHSENT" "$ALOG"; then fail "パスが argv に載った"; else pass; fi

: >"$ALOG"
jq -c --arg p "$PATHSENT/main.jsonl" '.agent_transcript_path = $p | .agent_id = "ARGVAGENT1"' "$STDIN_DIR/SubagentStop.json" >"$IN"
snap_run "$IN" PATH="$SHIM_PATH" SHIM_LOG="$ALOG"
it "[US3] SubagentStop でも argv に番兵・パス・agent_id が現れない"
hits=""
for s in SNT PATHSENT msg_ ARGVAGENT1; do
  if grep -qF -- "$s" "$ALOG"; then hits="$hits $s"; fi
done
assert_eq "$(echo "$hits" | tr -s ' ')" ""

it "[US3] 一時ファイルを作らない（TMPDIR の差分が空）"
TD="$WORK/us-tmpdir"; mkdir -p "$TD"
mk_main "$IN" "$TR_DIR/main.jsonl"
snap_run "$IN" TMPDIR="$TD"
assert_eq "$(find "$TD" -mindepth 1 | wc -l | tr -d ' ')" "0"

# 全ての UsageSnapshot（unknown を含む）でパスが載らない
run_main "$US_DIR/link-to-file.jsonl"
it "[US3] unknown の UsageSnapshot にもパスが載らない（symlink のケース）"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else case "$(cat "$SNAP")" in */*|*"$US_DIR"*) fail "パスが載った: $(cat "$SNAP")" ;; *) pass ;; esac; fi

# モデル ID: 番兵入りは許可文字を満たさないので unknown。満たす場合だけそのまま載る
f="$(tr_path model-sentinel.jsonl)"
{ asst msg_1 "SNTMODEL evil" 1 1 0 0; asst msg_2 "SNTMODEL/path" 1 1 0 0; asst msg_3 "SNT-OK.model_1" 1 1 0 0; } >"$f"
run_main "$f"
it "[US3] 許可文字を外れたモデル ID（番兵入り）は unknown にまとめ、番兵はボディに出ない。許可文字のみなら載る"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -c '[.models[].model]' "$SNAP")" '["SNT-OK.model_1","unknown"]'; fi

# ══════════════════════════════════════════════
suite "[US3] 安全: agent_id と session_id の検証（属人性）"
# ══════════════════════════════════════════════

A65="\"$("$PERL_BIN" -e 'print "a" x 65')\""
for badid in '"a/b"' '""' '123' 'null' '"aaaa bbbb"' "$A65"; do
  label="$(printf '%s' "$badid" | head -c 20)"
  jq -c --argjson a "$badid" --arg p "$TR_DIR/sub.jsonl" '.agent_id = $a | .agent_transcript_path = $p' "$STDIN_DIR/SubagentStop.json" >"$IN"
  snap_run_none "$IN"
  it "[US3] SubagentStop: agent_id が検証に落ちる（${label}）→ UsageSnapshot ごと送らない（メインに付けない）"
  assert_eq "$SNAP_N" "0"
done

jq -c --arg p "$TR_DIR/sub.jsonl" 'del(.agent_id) | .agent_transcript_path = $p' "$STDIN_DIR/SubagentStop.json" >"$IN"
snap_run_none "$IN"
it "[US3] SubagentStop: agent_id が無い → UsageSnapshot を送らない"
assert_eq "$SNAP_N" "0"

jq -c --arg p "$TR_DIR/main.jsonl" '.agent_id = "a/b" | .transcript_path = $p' "$STDIN_DIR/Stop.json" >"$IN"
snap_run "$IN"
it "[US3] Stop: stdin の agent_id が不正でも、メインの UsageSnapshot は agent_id 無しで送る"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else assert_eq "$(jq -c 'has("agent_id")' "$SNAP")" "false"; fi

for badsid in '"a/b"' '""' '123' 'null' '"s s"'; do
  jq -c --argjson s "$badsid" --arg p "$TR_DIR/main.jsonl" '.session_id = $s | .transcript_path = $p' "$STDIN_DIR/Stop.json" >"$IN"
  snap_run_none "$IN"
  it "[US3] Stop: session_id が検証に落ちる（${badsid}）→ UsageSnapshot を送らない"
  assert_eq "$SNAP_N" "0"
done

jq -c 'del(.session_id)' "$STDIN_DIR/Stop.json" >"$IN"
snap_run_none "$IN"
it "[US3] Stop: session_id が無い → UsageSnapshot を送らない"
assert_eq "$SNAP_N" "0"

# 他のイベントは UsageSnapshot を生まない
for ev in SessionStart PreToolUse.bash PostToolUse.read UserPromptSubmit SubagentStart PreCompact; do
  jq -c --arg p "$TR_DIR/main.jsonl" '.transcript_path = $p | .agent_transcript_path = $p' "$STDIN_DIR/${ev}.json" >"$IN"
  snap_run_none "$IN"
  it "[US3] ${ev}: transcript_path があっても UsageSnapshot を送らない（Stop / SubagentStop だけ）"
  assert_eq "$SNAP_N" "0"
done

# ══════════════════════════════════════════════
suite "[US4] 契約: 無音・LOOP_MONITOR=0・サーバ停止・前景 1 秒"
# ══════════════════════════════════════════════

mk_main "$IN" "$TR_DIR/main.jsonl"
start_stub capture
ZU_DIR="$S_DIR"; ZU_PORT="$S_PORT"
timed_hook "$IN" LOOP_MONITOR=0 LOOP_MONITOR_PORT="$ZU_PORT"
check_quiet "LOOP_MONITOR=0 + Stop + transcript" US4
mk_sub "$IN" "$TR_DIR/sub.jsonl"
timed_hook "$IN" LOOP_MONITOR=0 LOOP_MONITOR_PORT="$ZU_PORT"
check_quiet "LOOP_MONITOR=0 + SubagentStop + transcript" US4
sleep 0.8
it "[US4] LOOP_MONITOR=0 なら UsageSnapshot も含めて接続 0 件"
assert_eq "$(conn_count "$ZU_DIR")" "0"

ULOG="$WORK/us-zero.log"; : >"$ULOG"
timed_hook "$IN" PATH="$SHIM_PATH" SHIM_LOG="$ULOG" LOOP_MONITOR=0 LOOP_MONITOR_PORT="$ZU_PORT"
sleep 0.3
it "[US4] LOOP_MONITOR=0 なら jq も curl も起動しない（transcript を読む処理も走らない）"
assert_eq "$(grep -c '^CMD ' "$ULOG" | tr -d ' ')" "0"

start_stub proxy
DOWN_PORT="$S_PORT"; stop_stub "$S_PID"
mk_main "$IN" "$TR_DIR/main.jsonl"
timed_hook "$IN" LOOP_MONITOR_PORT="$DOWN_PORT"
check_quiet "サーバ停止中 + Stop + transcript" US4
it "[US4] サーバ停止中でも前景は 1 秒未満"
if awk -v t="$T_ELAPSED" 'BEGIN { exit !(t < 1) }'; then pass; else fail "前景が ${T_ELAPSED} 秒"; fi
mk_sub "$IN" "$TR_DIR/sub.jsonl"
timed_hook "$IN" LOOP_MONITOR_PORT="$DOWN_PORT"
check_quiet "サーバ停止中 + SubagentStop + transcript" US4

start_stub hang
HANG_U_PORT="$S_PORT"; HANG_U_PID="$S_PID"
mk_main "$IN" "$TR_DIR/main.jsonl"
timed_hook "$IN" LOOP_MONITOR_PORT="$HANG_U_PORT"
check_quiet "応答しないサーバ + Stop + transcript" US4
it "[US4] 応答しないサーバでも前景は 1 秒未満（集計・送信は背景）"
if awk -v t="$T_ELAPSED" 'BEGIN { exit !(t < 1) }'; then pass; else fail "前景が ${T_ELAPSED} 秒"; fi
stop_stub "$HANG_U_PID"

# 10MB 級の transcript（テスト内で生成。コミットしない）
BIG="$US_DIR/big.jsonl"
"$PERL_BIN" -e '
  open(F, ">", $ARGV[0]) or exit 1;
  my ($size, $i) = (0, 0);
  my $pad = "x" x 3000;
  while ($size < 10.5 * 1024 * 1024) {
    $i++;
    my $id = "msg_G" . int($i / 2);
    my $line = qq({"type":"assistant","message":{"id":"$id","model":"claude-haiku-4-5","content":[{"type":"text","text":"$pad"}],"usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4,"cache_creation":{"ephemeral_5m_input_tokens":3,"ephemeral_1h_input_tokens":0}}}}\n);
    print F $line;
    $size += length($line);
  }
  close(F);' "$BIG"

it "[US4] 自己診断: 生成した transcript は 10MB 以上"
if [ "$(wc -c <"$BIG" | tr -d ' ')" -ge 10485760 ]; then pass; else fail "小さすぎる"; fi

start_stub proxy
DOWN2_PORT="$S_PORT"; stop_stub "$S_PID"
mk_main "$IN" "$BIG"
timed_hook "$IN" LOOP_MONITOR_PORT="$DOWN2_PORT"
check_quiet "10MB 級 transcript + サーバ停止中" US4
it "[US4] 10MB 級 transcript + サーバ停止中: 前景は 1 秒未満"
if awk -v t="$T_ELAPSED" 'BEGIN { exit !(t < 1) }'; then pass; else fail "前景が ${T_ELAPSED} 秒"; fi

SNAP_SAVED_ITERS="$SNAP_ITERS"
if [ "$SNAP_ITERS" -gt 3 ]; then SNAP_ITERS=500; fi   # 背景の集計は最大 10 秒待つ
snap_run "$IN"
SNAP_ITERS="$SNAP_SAVED_ITERS"
check_quiet "10MB 級 transcript + 稼働中のサーバ" US4
it "[US4] 10MB 級 transcript + 稼働中のサーバ: 前景は 1 秒未満"
if awk -v t="$T_ELAPSED" 'BEGIN { exit !(t < 1) }'; then pass; else fail "前景が ${T_ELAPSED} 秒"; fi
it "[US4] 10MB 級 transcript の UsageSnapshot は ok か unknown のどちらかで 1 通だけ届く（サイズ上限の既定値は実測後に決まるため、どちらでもよい）"
if [ -z "$SNAP" ]; then fail "UsageSnapshot が届かない"
else
  st10="$(jq -r '.usage_status' "$SNAP")"
  case "$st10|$SNAP_N" in
    "ok|1"|"unknown|1") pass ;;
    *) fail "usage_status|通数 = ${st10}|${SNAP_N}（ok か unknown が 1 通のはず）" ;;
  esac
fi

report
