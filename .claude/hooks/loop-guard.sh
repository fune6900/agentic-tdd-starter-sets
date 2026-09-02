#!/bin/bash
# PreToolUse: ハードストップ到達後のループ続行をブロックする
#
# サブエージェント起動（Task）とコミット/PR 系の Bash を対象に、
# .claude/memory/loop-state.json が halted なら実行を止める。
# exit 2 = ブロック（stderr が Claude に渡る） / exit 0 = 続行

INPUT=$(cat)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
STATE_FILE="$PROJECT_DIR/.claude/memory/loop-state.json"

# 状態が無ければループ外の作業。素通しする。
[ -f "$STATE_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

STATUS=$(jq -r '.status // "running"' "$STATE_FILE" 2>/dev/null)
[ "$STATUS" = "halted" ] || exit 0

REASON=$(jq -r '.halt_reason // "理由未記載"' "$STATE_FILE" 2>/dev/null)
RETRY=$(jq -r '.retry // 0' "$STATE_FILE" 2>/dev/null)
ISSUE=$(jq -r '.issue // "unknown"' "$STATE_FILE" 2>/dev/null)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

BLOCK=0
case "$TOOL_NAME" in
  Task) BLOCK=1 ;;
  Bash)
    if echo "$COMMAND" | grep -qE "git commit|git push|gh pr create|gh pr merge"; then
      BLOCK=1
    fi
    ;;
esac

[ "$BLOCK" -eq 1 ] || exit 0

cat >&2 <<MSG
⛔ ハードストップ発動中（Issue: $ISSUE / retry: $RETRY）
理由: $REASON

ループの続行・コミット・PR 作成は全てブロックされた。
マスターに以下を報告して指示を仰げ。勝手に別アプローチを試すな。
  1. 何回目のリトライで、どのゲートで、何が落ちたか
  2. 各リトライで何を変えたか
  3. 推定原因と、判断を仰ぎたい選択肢

教訓の記録: /loop-retro
マスターの許可を得て再開する場合のみ:
  bash .claude/scripts/loop-state.sh clear && bash .claude/scripts/loop-state.sh init <issue>
MSG
exit 2
