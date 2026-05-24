#!/bin/bash
# PostToolUse: ファイル編集後に自動フォーマットを実行
# Write / Edit ツール実行後に発火

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# 対象拡張子のみフォーマット
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.json|*.css|*.md)
    ;;
  *)
    exit 0
    ;;
esac

# ファイルの存在確認
if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

PROJECT_DIR="$CLAUDE_PROJECT_DIR"

# prettier が使える場合は prettier、なければ npx で実行
if [ -f "$PROJECT_DIR/node_modules/.bin/prettier" ]; then
  "$PROJECT_DIR/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null
elif command -v npx &>/dev/null && [ -f "$PROJECT_DIR/package.json" ]; then
  npx --yes prettier --write "$FILE_PATH" 2>/dev/null
fi

exit 0
