#!/bin/bash
# 全イベント共通: フックの stdin を allowlist 抽出し、ローカル監視サーバへ送る
#
# 仕様は .claude/monitor/docs/event-schema.md だけ。ここに無いキーは送らない。
#
# fail open: 監視が原因で Claude Code を止めない・遅らせない・汚さない。
#   - 常に exit 0。stdout / stderr へは何も書かない（SessionStart / UserPromptSubmit の
#     stdout はコンテキストに入る）
#   - 失敗して黙って捨てるのはネットワーク失敗だけ。検証できなかった値は送らない側へ倒す
#   - 送信は背景化し、curl の fd1 / fd2 を /dev/null へ切り離す（握ったままだと EOF を待たれる）
#
# 値の行き先（lessons #11）:
#   送信ボディ  = jq が allowlist で作った JSON のみ（jq のプログラムは静的。ペイロードは
#                 stdin でだけ渡し、jq / curl の argv には一切載せない）
#   curl の argv = 固定 URL とオプションだけ
#   stderr      = 全て /dev/null。何も書かない
#   設定ファイル = curl は -q（第1引数）で .curlrc、jq は HOME 差し替えで ~/.jq を読ませない
#   一時ファイル = 作らない（ボディはシェル変数から組み込み printf でパイプへ渡す）
#   transcript パス = 環境変数 TPATH でだけ perl へ渡す（argv・一時ファイルに載せない）
#   transcript 本文 = perl の stdout から jq の stdin へ（上限+1 バイトで打ち切り）
set -u
# 文字数ではなくバイト数で数える（${#var}）。case のグロブも全角数字などを数字扱いしない
# このスクリプト内の設定。環境で既に export 済みなら子プロセス（jq / perl）にも効く
LC_ALL=C

[ "${LOOP_MONITOR:-1}" = "0" ] && exit 0

# ポートは case で検証する。1〜65535 の10進（先頭ゼロ・符号・空白・複数行は不正）以外は既定へ
port=4319
p="${LOOP_MONITOR_PORT:-}"
case "$p" in
  ''|*[!0-9]*|0*) ;;
  *) if [ "${#p}" -le 5 ] && [ "$p" -le 65535 ]; then port="$p"; fi ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

# 識別子の検証（イベント本体と UsageSnapshot の両方で使う）
# shellcheck disable=SC2016
JQ_VS='
def vs($re; $max):
  if type == "string" and test($re) and utf8bytelength <= $max then . else null end;
'

# shellcheck disable=SC2016
JQ_PROGRAM="$JQ_VS"'
# C0 / DEL / C1 / 双方向制御文字を落とし、バイト長で切る（多バイト文字は割らない）
def sane($n):
  explode
  | map(select(. > 31 and . != 127 and (. < 128 or . > 159)
               and . != 8206 and . != 8207
               and (. < 8234 or . > 8238) and (. < 8294 or . > 8297)))
  | reduce .[] as $c ({s: 0, o: [], d: false};
      if .d then .
      else ($c | if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end) as $w
        | if .s + $w > $n then .d = true else .s += $w | .o += [$c] end
      end)
  | .o | implode;

def base: split("/") | last;

def bashcmd:
  if type == "string" then
    .[0:4096] | [splits("[ \\t\\r\\n]+")] | map(select(length > 0)) | .[0]
    | if . == null then null
      elif test("\\A[A-Za-z0-9._/-]+\\z") then (base // "?") | if . == "" or utf8bytelength > 32 then "?" else . end
      else "?" end
  else null end;

def filepath:
  if type == "string" then
    base // "" | .[0:4096] | sane(128) | if . == "" then null else . end
  else null end;

# tool_name / agent_type / subagent_type 共通の識別子。\A…\z にする理由: Oniguruma の ^ $ は
# 行単位で、改行を含む複数行の値が1行目だけで通ってしまう
def ident: vs("\\A[A-Za-z0-9_-]+\\z"; 64);

def tool_evs: ["PreToolUse","PostToolUse"];
def agent_evs: ["SubagentStart","SubagentStop"];

# 受理する10イベント（event-schema.md）。settings.json の登録は9で、Notification は未発火
def evs: ["SessionStart","SessionEnd","UserPromptSubmit","PreToolUse","PostToolUse",
          "SubagentStart","SubagentStop","Stop","Notification","PreCompact"];

if type != "object" then empty else
  (.tool_input | if type == "object" then . else {} end) as $ti
  | (.hook_event_name | if type == "string" and IN(evs[]) then . else null end) as $e
  | if $e == null then empty else
      ({schema_version: 1, event: $e, session_id: (.session_id | vs("\\A[A-Za-z0-9-]+\\z"; 64))}
       + (if $e | IN(tool_evs[], agent_evs[]) then
            {agent_id: (.agent_id | vs("\\A[A-Za-z0-9]+\\z"; 64)),
             agent_type: (.agent_type | ident)}
          else {} end)
       + (if $e | IN(tool_evs[]) then
            {tool_name: (.tool_name | ident),
             tool_use_id: (.tool_use_id | vs("\\A[A-Za-z0-9_]+\\z"; 64)),
             file_path: ($ti.file_path | filepath)}
            + (if .tool_name == "Bash" then {bash_command: ($ti.command | bashcmd)} else {} end)
          else {} end)
       + (if $e == "PreToolUse" and .tool_name == "Agent" then
            {subagent_type: ($ti.subagent_type | ident)} else {} end)
       + (if $e == "PostToolUse" then
            {duration_ms: (.duration_ms | if type == "number" and . == floor and . >= 0 and . <= 3600000 then . else null end)}
          else {} end)
       + (if $e == "SessionStart" then
            {source: (.source | if type == "string" and IN("startup","resume","clear","compact","fork") then . else null end)}
          else {} end)
       # reason は event-schema.md の列挙外を送らない。"other" 以外は "unknown" へ丸める
       + (if $e == "SessionEnd" and has("reason") then
            {reason: (if .reason == "other" then "other" else "unknown" end)} else {} end)
       + (if $e == "PreCompact" then
            {trigger: (.trigger | if type == "string" and IN("manual","auto") then . else null end)} else {} end)
       + (if $e | IN("Stop","SubagentStop") then
            {stop_hook_active: (.stop_hook_active | if type == "boolean" then . else null end)} else {} end)
       | with_entries(select(.value != null))) as $o
      | (if $e | IN(tool_evs[]) then ["session_id","tool_name","tool_use_id"]
         elif $e | IN(agent_evs[]) then ["session_id","agent_id","agent_type"]
         else ["session_id"] end) as $req
      | if all($req[]; . as $k | $o | has($k)) then $o else empty end
    end
end
'

# UsageSnapshot（Issue #23）。仕様は event-schema.md「UsageSnapshot」。
# 1つ目: Stop / SubagentStop の stdin から「session_id・agent_id・読む transcript のパス」を取り出す。
#   出力は 1 行 `<ヘッダ JSON> <パス>`（パスは検証に落ちたら空）。session_id / agent_id が
#   検証に落ちたら何も出さない（agent_id を省略して送ると使用量がメインに付くため）。
# shellcheck disable=SC2016
JQ_USAGE_META="$JQ_VS"'
if type != "object" then empty else
  .hook_event_name as $e
  | if ($e | IN("Stop","SubagentStop")) | not then empty else
      (.session_id | vs("\\A[A-Za-z0-9-]+\\z"; 64)) as $sid
      | (if $e == "Stop" then null else (.agent_id | vs("\\A[A-Za-z0-9]+\\z"; 64)) end) as $aid
      | (if $e == "Stop" then .transcript_path else .agent_transcript_path end) as $p
      | if $sid == null or ($e == "SubagentStop" and $aid == null) then empty else
          ($p | if type == "string" and startswith("/") and utf8bytelength <= 4096
                   and (explode | any(. < 32 or . == 127) | not) then . else "" end) as $pp
          | (({sid: $sid} + (if $aid != null then {aid: $aid} else {} end)) | tojson) + " " + $pp
        end
    end
end
'

# 2つ目: 入力は 1 行目 = ヘッダ JSON、2 行目 = シェルが先に決めた unknown の理由（無ければ空行）、
#   3 行目以降 = transcript の生テキスト。集計規則は event-schema.md「集計規則」の 1〜9。
#   優先順位: parse_failed > invalid_usage > too_many_models > out_of_range（全行を見終えてから決める。
#   順序は def why に上から書いてある）
# 数値リテラルの上限は .claude/monitor/server/schema.mjs と同値:
#   8 = MAX_MODELS / 1000000 = MAX_MESSAGE_COUNT / 1000000000000 = MAX_USAGE_TOKENS
# shellcheck disable=SC2016
JQ_USAGE='
def isnn: type == "number" and . == floor and . >= 0;
def getn($o; $k): if ($o | has($k)) then $o[$k] else 0 end;
def unk($why): {usage_status: "unknown", unknown_reason: $why};
def tokkeys: ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"];

# 重複排除後の 1 件を、検証済みの数値・フラグへ。数値が不正なら {invalid: true}
def norm:
  .u as $u
  | ($u.cache_creation | if type == "object" then . else null end) as $c
  | (tokkeys | map(getn($u; .))) as $n
  | (if $c != null then [getn($c; "ephemeral_5m_input_tokens"), getn($c; "ephemeral_1h_input_tokens")] else [] end) as $cn
  | if ($n + $cn | all(isnn)) | not then {invalid: true} else
      ($n | map(floor)) as [$i, $o, $cc, $cr]
      | ($c != null and ($c | has("ephemeral_5m_input_tokens")) and ($c | has("ephemeral_1h_input_tokens"))
         and ($cn[0] + $cn[1] == $cc)) as $split
      | {model: (.m | if type == "string" and test("\\A[A-Za-z0-9._-]+\\z") and utf8bytelength <= 64 then . else "unknown" end),
         zero: ($i + $o + $cc + $cr == 0),
         i: $i, o: $o, cr: $cr,
         c5: (if $split then ($cn[0] | floor) else $cc end),
         c1: (if $split then ($cn[1] | floor) else 0 end),
         split_unknown: ($split | not),
         fast: ($u.speed == "fast"),
         us: ($u.inference_geo == "us"),
         variant: (($u.speed | IN(null, "standard", "fast") | not) or ($u.inference_geo | IN(null, "not_available", "global", "us") | not))}
    end;

# 段 1: transcript の全行を数える。入力 = なし（inputs を読む）。出力 = {bad, anon, ids}
def tally:
  reduce inputs as $l ({bad: false, anon: false, ids: {}};
    if ($l | test("\\A[ \\t\\r]*\\z")) then .
    else ($l | try [fromjson] catch null) as $w
      | if $w == null then .bad = true else
          $w[0] as $j
          | if ($j | type) == "object" and $j.type == "assistant"
               and ($j.message | type) == "object" and ($j.message.usage | type) == "object" then
              $j.message as $m
              | if ($m.id | type) == "string" and ($m.id | length) > 0 then .ids[$m.id] = {m: $m.model, u: $m.usage}
                elif ($m.usage as $u | tokkeys | map(getn($u; .)) | all(. == 0)) then .
                else .anon = true end
            else . end
        end
    end);

# 段 2: norm 済みの行（invalid を含みうる）をモデル別に集計する
def to_models:
  map(select(.zero | not)) | group_by(.model)
  | map({model: .[0].model, message_count: length,
         input_tokens: (map(.i) | add), output_tokens: (map(.o) | add),
         cache_creation_5m_input_tokens: (map(.c5) | add),
         cache_creation_1h_input_tokens: (map(.c1) | add),
         cache_read_input_tokens: (map(.cr) | add),
         fast_mode: any(.fast), us_inference: any(.us),
         variant_unknown: any(.variant), cache_split_unknown: any(.split_unknown)});

def out_of_range:
  any(.message_count > 1000000
      or ([.input_tokens, .output_tokens, .cache_creation_5m_input_tokens,
           .cache_creation_1h_input_tokens, .cache_read_input_tokens] | any(. > 1000000000000)));

# unknown の理由。優先順位は上から。全て当てはまらなければ null
def why($s; $rows; $ms):
  if $s.bad then "parse_failed"
  elif $s.anon or ($rows | any(.invalid)) then "invalid_usage"
  elif ($ms | length) > 8 then "too_many_models"
  elif ($ms | out_of_range) then "out_of_range"
  else null end;

(input | fromjson) as $h
| input as $r
| def out($o): {schema_version: 2, event: "UsageSnapshot", session_id: $h.sid}
                + (if $h.aid != null then {agent_id: $h.aid} else {} end) + $o;
  if $r != "" then out(unk($r)) else
    tally as $s
    | ([$s.ids[] | norm]) as $rows
    | ($rows | to_models) as $ms
    | why($s; $rows; $ms) as $why
    | if $why then out(unk($why)) else out({usage_status: "ok", models: $ms}) end
  end
'

# transcript を読む上限（バイト）。実測で決めた既定値（event-schema.md「1 秒予算とサイズ上限」）。
# 環境変数は下げる向きにだけ効く（読み取り量を増やす向きには使えない）
MAX_TRANSCRIPT_BYTES=16777216
max="$MAX_TRANSCRIPT_BYTES"
v="${LOOP_MONITOR_MAX_TRANSCRIPT_BYTES:-}"
case "$v" in
  ''|*[!0-9]*|0*) ;;
  *) if [ "${#v}" -le 15 ] && [ "$v" -lt "$max" ]; then max="$v"; fi ;;
esac

# stdin は 2 回使う（イベント本体 / UsageSnapshot のヘッダ）ので、先に変数へ取る
# bash 4.4 以降はコマンド置換が NUL で stderr に警告を出す。契約（stderr 空）を守るため警告だけ捨てる
# （NUL を落として読む挙動は bash 3.2 と同じ）
{ input="$(cat)"; } 2>/dev/null

# jq は $HOME/.jq を暗黙に読む（-L では止まらない）。HOME を /dev/null にして ~/.jq を読めなくする
body="$(printf '%s' "$input" | HOME=/dev/null jq -c "$JQ_PROGRAM" 2>/dev/null)"
[ -n "$body" ] || exit 0

{
  printf '%s' "$body" | curl -q -s --noproxy '*' --connect-timeout 1 --max-time 3 \
    -H 'Content-Type: application/json' --data-binary @- \
    "http://127.0.0.1:${port}/api/events"
} >/dev/null 2>&1 &

# transcript を読む perl（静的。パスは環境変数 TPATH、上限は MAXB で渡す。argv には載せない）。
#   1 行目 = 理由（空なら読めた）、2 行目以降 = transcript の本文。失敗時は理由の 1 行だけを出す
#   （読み取りが途中で失敗しても部分合計は出さない）。
#   パスは 1 回だけ開く（O_NOFOLLOW: 最終要素が symlink なら ELOOP / O_NONBLOCK: FIFO でも open で待たない）。
#   O_NOCTTY: 開いた対象を制御端末にしない。binmode($fh): PERL_UNICODE / PERLIO による :utf8 層を外す
#   （層が付くと sysread が致命的エラーになる）。env -u と二重で守る。
#   種別とサイズの判定は開いた fd 上（stat）で行う。名前では再判定しない（差し替え競合の排除）。
# shellcheck disable=SC2016
PERL_READ='
my $ok = eval { require Fcntl; Fcntl::O_NOFOLLOW(); Fcntl::O_NONBLOCK(); Fcntl::O_NOCTTY(); 1 };
$| = 1;
sub fin { print $_[0], "\n"; exit 0 }
fin("read_failed") unless $ok;
my $p = $ENV{TPATH};
my $max = $ENV{MAXB};
fin("read_failed") unless defined $p && length $p && defined $max && $max =~ /^[0-9]+$/;
my $fh;
unless (sysopen($fh, $p, Fcntl::O_RDONLY() | Fcntl::O_NONBLOCK() | Fcntl::O_NOFOLLOW() | Fcntl::O_NOCTTY())) {
  fin($!{ELOOP} ? "symlink" : "read_failed");
}
binmode($fh);
my @st = stat($fh);
fin("read_failed") unless @st;
fin("not_regular_file") unless -f $fh;
fin("too_large") if $st[7] > $max;
my ($buf, $n) = ("", 0);
while ($n <= $max) {
  my $r = sysread($fh, $buf, $max + 1 - $n, $n);
  fin("read_failed") unless defined $r;
  last if $r == 0;
  $n += $r;
}
fin("too_large") if $n > $max;
binmode(STDOUT);
print "\n", $buf;
'

# UsageSnapshot は別の背景グループ。前景は transcript に触れない（判定・読み取り・集計・送信は全て背景）。
#   - パスは環境変数と perl の中だけで扱う（jq / curl / perl の argv に載せない）。一時ファイルは作らない
#   - 開くのは perl の sysopen 1 回だけ。判定は fd 上（FIFO・デバイス・ディレクトリは読まない）
#   - 読み取りは上限 + 1 バイトで打ち切る。超過分が 1 バイトでも読めたら too_large
#   - perl の設定・モジュールの探索パスは外部の環境変数で変えさせない
case "$body" in
  *'"event":"Stop"'*|*'"event":"SubagentStop"'*)
    {
      meta="$(printf '%s' "$input" | HOME=/dev/null jq -r "$JQ_USAGE_META" 2>/dev/null)"
      [ -n "$meta" ] || exit 0
      hdr="${meta%% *}"
      tpath="${meta#* }"
      out="$({
        printf '%s\n' "$hdr"
        if [ -z "$tpath" ]; then printf 'no_path\n'
        elif command -v perl >/dev/null 2>&1; then
          TPATH="$tpath" MAXB="$max" env -u PERL5LIB -u PERL5OPT -u PERLLIB -u PERL5DB -u PERL_UNICODE -u PERLIO perl -e "$PERL_READ" 2>/dev/null \
            || printf 'read_failed\n'
        else printf 'read_failed\n'; fi
      } | HOME=/dev/null jq -nRc "$JQ_USAGE" 2>/dev/null)"
      [ -n "$out" ] || exit 0
      printf '%s' "$out" | curl -q -s --noproxy '*' --connect-timeout 1 --max-time 3 \
        -H 'Content-Type: application/json' --data-binary @- \
        "http://127.0.0.1:${port}/api/events"
    } >/dev/null 2>&1 </dev/null &
    ;;
esac

exit 0
