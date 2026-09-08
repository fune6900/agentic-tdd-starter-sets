#!/usr/bin/env bash
# 導入先プロジェクトの初期セットアップ
#
# このテンプレートを別プロジェクトへ導入した直後、そのプロジェクトで実際に動く
# CI ワークフローを1本だけ生成する。SessionStart フックから自動で呼ばれる。
#
# 原則:
#   1. **既存ファイルを絶対に上書きしない。** 人のリポジトリを壊さない
#   2. **検出できなければ何もしない。** 憶測でファイルを撒かない
#   3. **冪等。** 何度実行しても結果が変わらない
#
# 使い方:
#   bootstrap-project.sh            生成して結果を表示する
#   bootstrap-project.sh --quiet    何もしなかった場合は黙る（フックからの既定）
#   bootstrap-project.sh --dry-run  生成せず、生成する内容を表示する
#
# 環境変数:
#   LOOP_BOOTSTRAP=0   ブートストラップを完全に無効化する

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
WORKFLOW_DIR="$PROJECT_DIR/.github/workflows"
WORKFLOW_FILE="$WORKFLOW_DIR/ci.yml"

QUIET=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --quiet)   QUIET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "ERROR: 未知の引数: $arg" >&2; exit 1 ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
note() { echo "$@"; }   # 生成したときは quiet でも必ず知らせる

# ---------- 早期離脱 ----------

if [ "${LOOP_BOOTSTRAP:-1}" = "0" ]; then
  say "ブートストラップは LOOP_BOOTSTRAP=0 で無効化されている。"
  exit 0
fi

if [ -f "$WORKFLOW_FILE" ]; then
  say "CI ワークフローは既に存在する: .github/workflows/ci.yml（上書きしない）"
  exit 0
fi

# ---------- スタック検出 ----------

PKG_JSON="$PROJECT_DIR/package.json"

if [ ! -f "$PKG_JSON" ]; then
  say "package.json が無い。対応スタックを検出できないので CI は生成しない。"
  say "（このテンプレート自身のリポジトリでは、これが正しい挙動）"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  note "WARN: jq が無いため package.json を解析できない。CI の生成を見送る。"
  exit 0
fi

if ! jq empty "$PKG_JSON" >/dev/null 2>&1; then
  note "WARN: package.json が妥当な JSON ではない。CI の生成を見送る。"
  exit 0
fi

has_script() { jq -e --arg s "$1" '.scripts[$s] // empty' "$PKG_JSON" >/dev/null 2>&1; }

# パッケージマネージャはロックファイルで判定する。宣言より事実を信じる。
PM="npm"
INSTALL_CMD="npm install"
[ -f "$PROJECT_DIR/package-lock.json" ] && { PM="npm"; INSTALL_CMD="npm ci"; }
[ -f "$PROJECT_DIR/yarn.lock" ]         && { PM="yarn"; INSTALL_CMD="yarn install --frozen-lockfile"; }
[ -f "$PROJECT_DIR/pnpm-lock.yaml" ]    && { PM="pnpm"; INSTALL_CMD="pnpm install --frozen-lockfile"; }
[ -f "$PROJECT_DIR/bun.lockb" ]         && { PM="bun";  INSTALL_CMD="bun install --frozen-lockfile"; }

run_prefix() {
  case "$PM" in
    npm)  echo "npm run" ;;
    yarn) echo "yarn" ;;
    pnpm) echo "pnpm run" ;;
    bun)  echo "bun run" ;;
  esac
}

# ローカルにインストールされた実行ファイルを起動する前置き。
# pnpm / yarn では npx がローカルの解決に失敗しうるため、各マネージャの exec を使う。
exec_prefix() {
  case "$PM" in
    npm)  echo "npx" ;;
    yarn) echo "yarn" ;;
    pnpm) echo "pnpm exec" ;;
    bun)  echo "bunx" ;;
  esac
}

# Node のバージョンは .nvmrc → engines.node → 22 の順で決める
NODE_VERSION="22"
if [ -f "$PROJECT_DIR/.nvmrc" ]; then
  NODE_VERSION="$(tr -d ' v\n\r' < "$PROJECT_DIR/.nvmrc")"
elif jq -e '.engines.node // empty' "$PKG_JSON" >/dev/null 2>&1; then
  NODE_VERSION="$(jq -r '.engines.node' "$PKG_JSON" | tr -d '^~>=<x* ' | cut -d. -f1)"
fi
[ -n "$NODE_VERSION" ] || NODE_VERSION="22"

# ---------- 生成する内容の決定 ----------

DETECTED=""
add_step() { # <ジョブ名> <コマンド>
  STEPS="$STEPS
      - name: $1
        run: $2"
  DETECTED="$DETECTED $1"
}

STEPS=""
has_script lint      && add_step "lint"      "$(run_prefix) lint"
has_script typecheck && add_step "typecheck" "$(run_prefix) typecheck"
if has_script test; then
  # Vitest / Jest を watch モードで回して CI をハングさせない
  case "$PM" in
    npm)  add_step "test" "npm test -- --run" ;;
    yarn) add_step "test" "yarn test --run" ;;
    pnpm) add_step "test" "pnpm test -- --run" ;;
    bun)  add_step "test" "bun test" ;;
  esac
fi
has_script build && add_step "build" "$(run_prefix) build"

if [ -z "$STEPS" ] && ! has_script e2e; then
  say "package.json に lint / typecheck / test / build / e2e のいずれも無い。CI は生成しない。"
  exit 0
fi

# パッケージマネージャのセットアップ手順
SETUP=""
CACHE="$PM"
case "$PM" in
  pnpm)
    SETUP="      - uses: pnpm/action-setup@v4
"
    ;;
  bun)
    SETUP="      - uses: oven-sh/setup-bun@v2
"
    CACHE=""
    ;;
esac

if [ "$PM" = "bun" ]; then
  NODE_SETUP=""
else
  NODE_SETUP="      - uses: actions/setup-node@v4
        with:
          node-version: '$NODE_VERSION'
          cache: $CACHE
"
fi

# E2E は別ジョブにする。ブラウザの取得が重く、失敗の切り分けもしやすい。
E2E_JOB=""
if has_script e2e; then
  E2E_JOB="
  e2e:
    name: E2E
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
${SETUP}${NODE_SETUP}      - name: install
        run: $INSTALL_CMD

      - name: install browsers
        run: $(exec_prefix) playwright install --with-deps

      - name: e2e
        run: $(run_prefix) e2e

      - uses: actions/upload-artifact@v4
        if: failure()
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 7
"
  DETECTED="$DETECTED e2e"
fi

QUALITY_JOB=""
if [ -n "$STEPS" ]; then
  QUALITY_JOB="
  quality:
    name: Lint / Types / Test / Build
    runs-on: ubuntu-latest
    timeout-minutes: 20
    steps:
      - uses: actions/checkout@v4
${SETUP}${NODE_SETUP}      - name: install
        run: $INSTALL_CMD
$STEPS
"
fi

CONTENT="# このプロジェクトの CI
#
# .claude/scripts/bootstrap-project.sh が package.json の scripts を検出して生成した。
# 以後は手で管理してよい。ブートストラップは既存の ci.yml を上書きしない。
#
# 検出したパッケージマネージャ: $PM
# 生成日: $(date +%Y-%m-%d)

name: CI

on:
  pull_request:
  push:
    branches: [main]

permissions:
  contents: read

concurrency:
  group: ci-\${{ github.ref }}
  cancel-in-progress: true

jobs:${QUALITY_JOB}${E2E_JOB}"

# ---------- 出力 ----------

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--- 生成される .github/workflows/ci.yml ---"
  printf '%s\n' "$CONTENT"
  exit 0
fi

mkdir -p "$WORKFLOW_DIR" || { note "ERROR: $WORKFLOW_DIR を作れない。"; exit 1; }

# 生成の直前に、競合していないかもう一度だけ確認する
if [ -f "$WORKFLOW_FILE" ]; then
  say "CI ワークフローは既に存在する: .github/workflows/ci.yml（上書きしない）"
  exit 0
fi

printf '%s\n' "$CONTENT" > "$WORKFLOW_FILE" || { note "ERROR: ci.yml を書き込めない。"; exit 1; }
[ -s "$WORKFLOW_FILE" ] || { note "ERROR: ci.yml の書き込みに失敗した。"; exit 1; }

note "CI ワークフローを生成した: .github/workflows/ci.yml"
note "  パッケージマネージャ: $PM / Node: $NODE_VERSION"
note "  検出したジョブ:$DETECTED"
note "  内容を確認してからコミットしろ。以後この生成は走らない（既存ファイルは上書きしない）。"
