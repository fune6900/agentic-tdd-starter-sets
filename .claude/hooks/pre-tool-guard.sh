#!/bin/bash
# PreToolUse: 危険なコマンド実行前の警告表示
# exit 2 = ブロック（stderrがClaudeに表示される）
# exit 0 = 続行

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# 危険パターンの定義
DANGEROUS_PATTERNS=(
  "rm -rf"
  "rm -r /"
  "DROP TABLE"
  "DROP DATABASE"
  "TRUNCATE"
  "git push --force"
  "git push -f"
  "git reset --hard"
  "git clean -fd"
  "chmod -R 777"
  "> /dev/sda"
  "mkfs"
  "dd if="
  ":(){ :|:& };:"
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -qi "$pattern"; then
    echo "⚠ 危険なコマンドを検知しました: $COMMAND" >&2
    echo "パターン: $pattern" >&2
    echo "このコマンドはブロックされました。メイド長の判断により実行を拒否します。" >&2
    exit 2
  fi
done

exit 0
