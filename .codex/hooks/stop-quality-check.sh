#!/bin/bash
# Stop: エージェント停止時に品質チェックを自動実行
# Codex/Claude のどちらでも動くよう、プロジェクトディレクトリをフォールバック解決する。
# package.json に存在する品質チェックだけを実行し、問題があれば報告する。

PROJECT_DIR="${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"

# package.json が存在しない場合はスキップ
if [ ! -f "$PROJECT_DIR/package.json" ]; then
  exit 0
fi

# node_modules が存在しない場合はスキップ
if [ ! -d "$PROJECT_DIR/node_modules" ]; then
  exit 0
fi

ERRORS=""

run_script() {
  local script_name="$1"
  local label="$2"
  local output

  if jq -e ".scripts.${script_name}" "$PROJECT_DIR/package.json" &>/dev/null; then
    output=$(cd "$PROJECT_DIR" && npm run "$script_name" 2>&1)
    if [ $? -ne 0 ]; then
      ERRORS="${ERRORS}\n[${label} 失敗]\n${output}\n"
    fi
  fi
}

# ユニットテスト
if jq -e '.scripts.test' "$PROJECT_DIR/package.json" &>/dev/null; then
  TEST_OUTPUT=$(cd "$PROJECT_DIR" && npm test -- --run 2>&1)
  if [ $? -ne 0 ]; then
    ERRORS="${ERRORS}\n[テスト失敗]\n${TEST_OUTPUT}\n"
  fi
fi

# TypeScript 型チェック
run_script "typecheck" "型チェック"

# ESLint
run_script "lint" "Lint"

# ビルド
run_script "build" "ビルド"

if [ -n "$ERRORS" ]; then
  echo -e "⚠ 品質チェックで問題を検出しました:${ERRORS}" >&2
  exit 2
fi

exit 0
