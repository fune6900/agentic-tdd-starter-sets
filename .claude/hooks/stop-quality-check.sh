#!/bin/bash
# Stop: エージェント停止時に品質チェックを自動実行
# TypeScript 型チェック + ESLint を走らせ、問題があれば報告

PROJECT_DIR="$CLAUDE_PROJECT_DIR"

# package.json が存在しない場合はスキップ
if [ ! -f "$PROJECT_DIR/package.json" ]; then
  exit 0
fi

# node_modules が存在しない場合はスキップ
if [ ! -d "$PROJECT_DIR/node_modules" ]; then
  exit 0
fi

ERRORS=""

# TypeScript 型チェック
if jq -e '.scripts.typecheck' "$PROJECT_DIR/package.json" &>/dev/null; then
  TYPECHECK_OUTPUT=$(cd "$PROJECT_DIR" && npm run typecheck 2>&1)
  if [ $? -ne 0 ]; then
    ERRORS="${ERRORS}\n[型チェック失敗]\n${TYPECHECK_OUTPUT}\n"
  fi
fi

# ESLint
if jq -e '.scripts.lint' "$PROJECT_DIR/package.json" &>/dev/null; then
  LINT_OUTPUT=$(cd "$PROJECT_DIR" && npm run lint 2>&1)
  if [ $? -ne 0 ]; then
    ERRORS="${ERRORS}\n[Lint 失敗]\n${LINT_OUTPUT}\n"
  fi
fi

if [ -n "$ERRORS" ]; then
  echo -e "⚠ 品質チェックで問題を検出しました:${ERRORS}" >&2
  exit 2
fi

exit 0
