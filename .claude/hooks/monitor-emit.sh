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
set -u

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

# shellcheck disable=SC2016
JQ_PROGRAM='
def vs($re; $max):
  if type == "string" and test($re) and utf8bytelength <= $max then . else null end;

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

# jq は $HOME/.jq を暗黙に読む（-L では止まらない）。HOME を /dev/null にして ~/.jq を読めなくする
body="$(HOME=/dev/null jq -c "$JQ_PROGRAM" 2>/dev/null)"
[ -n "$body" ] || exit 0

{
  printf '%s' "$body" | curl -q -s --noproxy '*' --connect-timeout 1 --max-time 3 \
    -H 'Content-Type: application/json' --data-binary @- \
    "http://127.0.0.1:${port}/api/events"
} >/dev/null 2>&1 &

exit 0
