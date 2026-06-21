#!/bin/bash
# PostToolUse: ファイル編集後に自動フォーマットを実行
# Claude/Codex どちらのフック入力でも動くよう、複数の JSON 形状を許容する。

INPUT=$(cat)
FILE_PATH=$(
  echo "$INPUT" | jq -r '
    .tool_input.file_path //
    .tool_input.path //
    .arguments.file_path //
    .arguments.path //
    .file_path //
    .path //
    empty
  '
)

if [ -z "$FILE_PATH" ]; then
  exit 0
fi

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"

case "$FILE_PATH" in
  /*)
    ;;
  *)
    FILE_PATH="$PROJECT_DIR/$FILE_PATH"
    ;;
esac

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

# prettier が使える場合は prettier、なければ npx で実行
if [ -f "$PROJECT_DIR/node_modules/.bin/prettier" ]; then
  "$PROJECT_DIR/node_modules/.bin/prettier" --write "$FILE_PATH" 2>/dev/null
elif command -v npx &>/dev/null && [ -f "$PROJECT_DIR/package.json" ]; then
  npx --yes prettier --write "$FILE_PATH" 2>/dev/null
fi

exit 0
