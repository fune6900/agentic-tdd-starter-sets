#!/usr/bin/env bash
# ループ状態管理 / ハードストップの実体
#
# インナーループの retry 回数・ゲート結果・経過時間を .claude/memory/loop-state.json に永続化し、
# 上限到達を機械的に判定する。判定は人間の気分ではなくこのスクリプトが行う。
#
# 使い方:
#   loop-state.sh init <issue> [branch] [epic]  ループ開始（状態を初期化）
#   loop-state.sh show                       現在の状態を表示
#   loop-state.sh gate <G1..G5> <pass|fail> [reason]
#                                            ゲート結果を記録
#   loop-state.sh retry [note]               差し戻し（retry を1加算）
#   loop-state.sh check                      ハードストップ判定（到達で exit 1）
#   loop-state.sh stop <reason>              強制停止（halted にする）
#   loop-state.sh complete                   正常完了
#   loop-state.sh clear                      状態を削除
#
# 上限の既定値（環境変数で上書き可）:
#   LOOP_MAX_RETRY=3  LOOP_MAX_MINUTES=60  LOOP_MAX_SAME_GATE_FAIL=2

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
STATE_DIR="$PROJECT_DIR/.claude/memory"
STATE_FILE="$STATE_DIR/loop-state.json"

MAX_RETRY="${LOOP_MAX_RETRY:-3}"
MAX_MINUTES="${LOOP_MAX_MINUTES:-60}"
MAX_SAME_GATE_FAIL="${LOOP_MAX_SAME_GATE_FAIL:-2}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq が必要だ。インストールしてから出直せ。" >&2
  exit 1
fi

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date -u +%s; }

require_state() {
  if [ ! -f "$STATE_FILE" ]; then
    echo "ERROR: ループ状態が無い。先に 'loop-state.sh init <issue>' を実行しろ。" >&2
    exit 1
  fi
}

write_state() { # stdin から JSON を受けて原子的に書く
  local tmp="$STATE_FILE.tmp.$$"
  cat > "$tmp" && mv "$tmp" "$STATE_FILE"
}

refuse_if_halted() {
  if [ "$(jq -r '.status' "$STATE_FILE")" = "halted" ]; then
    echo "HALTED: $(jq -r '.halt_reason' "$STATE_FILE")" >&2
    echo "ハードストップ済みだ。マスターの指示を仰ぐまでループを再開するな。" >&2
    exit 1
  fi
}

cmd_init() {
  local issue="${1:-unknown}"
  local branch="${2:-$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo unknown)}"
  # epic は外部記憶（loop-journal.sh）がジャーナルの宛先を特定するのに使う
  local epic="${3:-${LOOP_EPIC:-}}"
  mkdir -p "$STATE_DIR"
  jq -n \
    --arg issue "$issue" \
    --arg branch "$branch" \
    --arg epic "$epic" \
    --arg started_at "$(now_iso)" \
    --argjson started_epoch "$(now_epoch)" \
    --argjson max_retry "$MAX_RETRY" \
    --argjson max_minutes "$MAX_MINUTES" \
    --argjson max_same_gate_fail "$MAX_SAME_GATE_FAIL" \
    '{
      issue: $issue,
      branch: $branch,
      epic: $epic,
      status: "running",
      started_at: $started_at,
      started_epoch: $started_epoch,
      limits: {
        max_retry: $max_retry,
        max_minutes: $max_minutes,
        max_same_gate_fail: $max_same_gate_fail
      },
      retry: 0,
      gates: {},
      consecutive_gate_fail: {},
      halt_reason: null,
      history: []
    }' | write_state
  echo "ループ開始: issue=$issue branch=$branch${epic:+ epic=$epic} (retry上限=$MAX_RETRY / 時間上限=${MAX_MINUTES}分)"
}

cmd_show() {
  require_state
  local elapsed
  elapsed=$(( ( $(now_epoch) - $(jq -r '.started_epoch' "$STATE_FILE") ) / 60 ))
  jq --argjson elapsed "$elapsed" '. + {elapsed_minutes: $elapsed}' "$STATE_FILE"
}

cmd_gate() {
  require_state
  refuse_if_halted
  local gate="${1:-}" result="${2:-}" reason="${3:-}"
  case "$gate" in
    G1|G2|G3|G4|G5) ;;
    *) echo "ERROR: ゲート名は G1..G5 のいずれか。指定値: '$gate'" >&2; exit 1 ;;
  esac
  case "$result" in
    pass|fail) ;;
    *) echo "ERROR: 結果は pass または fail。指定値: '$result'" >&2; exit 1 ;;
  esac

  jq \
    --arg gate "$gate" \
    --arg result "$result" \
    --arg reason "$reason" \
    --arg at "$(now_iso)" \
    '
    .gates[$gate] = {result: $result, reason: $reason, at: $at}
    | .consecutive_gate_fail[$gate] =
        (if $result == "fail"
         then ((.consecutive_gate_fail[$gate] // 0) + 1)
         else 0 end)
    | .history += [{type: "gate", gate: $gate, result: $result, reason: $reason, at: $at}]
    ' "$STATE_FILE" | write_state

  echo "$gate: $result${reason:+ — $reason}"
  cmd_check
}

cmd_retry() {
  require_state
  refuse_if_halted
  local note="${1:-}"
  jq \
    --arg note "$note" \
    --arg at "$(now_iso)" \
    '
    .retry += 1
    | .gates = {}
    | .history += [{type: "retry", retry: .retry, note: $note, at: $at}]
    ' "$STATE_FILE" | write_state
  echo "差し戻し: retry=$(jq -r '.retry' "$STATE_FILE") / 上限 $(jq -r '.limits.max_retry' "$STATE_FILE")"
  cmd_check
}

cmd_stop() {
  require_state
  local reason="${1:-理由未記載}"
  jq \
    --arg reason "$reason" \
    --arg at "$(now_iso)" \
    '.status = "halted" | .halt_reason = $reason
     | .history += [{type: "halt", reason: $reason, at: $at}]' "$STATE_FILE" | write_state
  cat >&2 <<MSG

════════════════════════════════════════════════
  ハードストップ発動
  理由: $reason
════════════════════════════════════════════════
  実装・コミット・PR 作成を全て停止しろ。
  マスターに以下を報告して指示を仰げ:
    1. 何回目のリトライで、どのゲートで、何が落ちたか
    2. 各リトライで何を変えたか（同じ修正の繰り返しになっていないか）
    3. 推定原因と、判断を仰ぎたい選択肢
  併せて .claude/memory/lessons.md に事実を記録しろ（/loop-retro）。
════════════════════════════════════════════════
MSG
  return 1
}

cmd_complete() {
  require_state
  jq --arg at "$(now_iso)" \
    '.status = "completed" | .history += [{type: "complete", at: $at}]' "$STATE_FILE" | write_state
  echo "ループ完了: issue=$(jq -r '.issue' "$STATE_FILE") retry=$(jq -r '.retry' "$STATE_FILE")"
}

cmd_check() {
  require_state

  local status retry max_retry max_minutes max_gate_fail started elapsed
  status=$(jq -r '.status' "$STATE_FILE")
  retry=$(jq -r '.retry' "$STATE_FILE")
  max_retry=$(jq -r '.limits.max_retry' "$STATE_FILE")
  max_minutes=$(jq -r '.limits.max_minutes' "$STATE_FILE")
  max_gate_fail=$(jq -r '.limits.max_same_gate_fail' "$STATE_FILE")
  started=$(jq -r '.started_epoch' "$STATE_FILE")
  elapsed=$(( ( $(now_epoch) - started ) / 60 ))

  if [ "$status" = "halted" ]; then
    echo "HALTED: $(jq -r '.halt_reason' "$STATE_FILE")" >&2
    return 1
  fi

  if [ "$retry" -ge "$max_retry" ]; then
    cmd_stop "リトライ上限に到達（$retry/$max_retry 回）。自力解決の見込みなし。"
    return 1
  fi

  if [ "$elapsed" -ge "$max_minutes" ]; then
    cmd_stop "時間上限に到達（${elapsed}分 / 上限 ${max_minutes}分）。"
    return 1
  fi

  local worst_gate
  worst_gate=$(jq -r --argjson lim "$max_gate_fail" \
    '.consecutive_gate_fail | to_entries | map(select(.value >= $lim)) | .[0].key // empty' "$STATE_FILE")
  if [ -n "$worst_gate" ]; then
    local n
    n=$(jq -r --arg g "$worst_gate" '.consecutive_gate_fail[$g]' "$STATE_FILE")
    cmd_stop "同一ゲート $worst_gate が $n 回連続で失敗（上限 ${max_gate_fail}）。修正方針が的外れな可能性が高い。"
    return 1
  fi

  echo "OK: retry=$retry/$max_retry 経過=${elapsed}分/${max_minutes}分"
  return 0
}

cmd_clear() {
  rm -f "$STATE_FILE"
  echo "ループ状態を削除した。"
}

case "${1:-}" in
  init)     shift; cmd_init "$@" ;;
  show)     cmd_show ;;
  gate)     shift; cmd_gate "$@" ;;
  retry)    shift; cmd_retry "$@" ;;
  check)    cmd_check ;;
  stop)     shift; cmd_stop "$@" ;;
  complete) cmd_complete ;;
  clear)    cmd_clear ;;
  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
