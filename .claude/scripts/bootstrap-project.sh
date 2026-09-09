#!/usr/bin/env bash
# 導入先プロジェクトの初期セットアップ
#
# このテンプレートを別プロジェクトへ導入した直後、そのプロジェクトで実際に動く
# CI ワークフローを1本だけ生成する。SessionStart フックから自動で呼ばれる。
#
# 原則:
#   1. **既存ファイルを絶対に上書きしない。** 人のリポジトリを壊さない
#   2. **検出できなければ何もしない。** 憶測でファイルを撒かない
#   3. **推測でフラグを足さない。** 事実（依存関係・ロックファイル）から決まるものだけ書く
#   4. **冪等。** 何度実行しても結果が変わらない
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

DEFAULT_NODE="22"

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
note() { echo "$@"; }   # 生成したとき・警告は quiet でも必ず知らせる

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
has_dep() {
  jq -e --arg d "$1" \
    '((.dependencies // {}) + (.devDependencies // {}))[$d] // empty' \
    "$PKG_JSON" >/dev/null 2>&1
}

# ---------- パッケージマネージャ ----------
# 宣言（packageManager フィールド）ではなくロックファイルで判定する。宣言はズレるが
# ロックファイルは事実だから。ただし pnpm のセットアップでは packageManager の有無も見る。

LOCKFILES=""
[ -f "$PROJECT_DIR/package-lock.json" ] && LOCKFILES="$LOCKFILES package-lock.json"
[ -f "$PROJECT_DIR/yarn.lock" ]         && LOCKFILES="$LOCKFILES yarn.lock"
[ -f "$PROJECT_DIR/pnpm-lock.yaml" ]    && LOCKFILES="$LOCKFILES pnpm-lock.yaml"
[ -f "$PROJECT_DIR/bun.lockb" ]         && LOCKFILES="$LOCKFILES bun.lockb"

LOCK_COUNT=0
for _lock in $LOCKFILES; do LOCK_COUNT=$((LOCK_COUNT + 1)); done

if [ "$LOCK_COUNT" -gt 1 ]; then
  note "WARN: ロックファイルが複数ある:$LOCKFILES"
  note "WARN: 後勝ちで決定する。意図しない場合は不要なロックファイルを消してから生成し直せ。"
fi

PM="npm"
INSTALL_CMD="npm install"
HAS_LOCK=0
[ -f "$PROJECT_DIR/package-lock.json" ] && { PM="npm";  INSTALL_CMD="npm ci"; HAS_LOCK=1; }
[ -f "$PROJECT_DIR/yarn.lock" ]         && { PM="yarn"; INSTALL_CMD="yarn install --frozen-lockfile"; HAS_LOCK=1; }
[ -f "$PROJECT_DIR/pnpm-lock.yaml" ]    && { PM="pnpm"; INSTALL_CMD="pnpm install --frozen-lockfile"; HAS_LOCK=1; }
[ -f "$PROJECT_DIR/bun.lockb" ]         && { PM="bun";  INSTALL_CMD="bun install --frozen-lockfile"; HAS_LOCK=1; }

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

# ---------- Node のバージョン ----------
# .nvmrc → engines.node → 既定。
# engines.node は範囲（">=18 <21"）や OR（"18.x || 20.x"）が書けるが1つには一意化できない。
# **推測せず既定へ倒す。** 数字だけ抜き出すと ">=18 <21" が "1821" になって CI が壊れる。

NODE_VERSION=""
NODE_SOURCE=""

if [ -s "$PROJECT_DIR/.nvmrc" ]; then
  # .nvmrc は setup-node がそのまま解釈する（lts/* エイリアスを含む）ので値は加工しない。
  # ただしこの値は YAML の引用符付き文字列に埋め込まれる。engines.node と同じく
  # allowlist で検証し、外れたら採用しない。シングルクォート1文字で生成物が壊れる。
  NVMRC_VALUE="$(head -1 "$PROJECT_DIR/.nvmrc" | tr -d ' \t\r' | sed 's/^v//')"
  if [ -n "$NVMRC_VALUE" ]; then
    # grep は行単位で判定するため複数行をすり抜ける。case で文字列全体を見る。
    # 文字種に加えて形式も見る。nvm が受け付けるのは数字始まりのバージョン、
    # lts エイリアス、node / stable の3種だけ。それ以外は生成しても CI が落ちるだけ。
    NVMRC_OK=0
    case "$NVMRC_VALUE" in
      [!A-Za-z0-9]* | *[!A-Za-z0-9._/*-]* ) NVMRC_OK=0 ;;
      node | stable | lts/* | [0-9]* )      NVMRC_OK=1 ;;
      * )                                   NVMRC_OK=0 ;;
    esac
    if [ "$NVMRC_OK" -eq 1 ]; then
      NODE_VERSION="$NVMRC_VALUE"
      NODE_SOURCE=".nvmrc"
    else
      note "WARN: .nvmrc の値を Node のバージョンとして解釈できない: '$NVMRC_VALUE'"
      note "WARN: Node $DEFAULT_NODE を使う。必要なら生成後の ci.yml を手で直せ。"
    fi
  fi
fi

if [ -z "$NODE_VERSION" ]; then
  ENGINES_NODE="$(jq -r '.engines.node // empty' "$PKG_JSON" 2>/dev/null)"
  if [ -n "$ENGINES_NODE" ]; then
    # 採用するのは単項の単純指定だけ: "22" / "22.1.0" / "18.x" / "^20.9" / ">=18"
    # grep は行単位で判定するので、まず改行を含む値を弾いてから形式を見る。
    # （"22\n>=18 <21" は grep だけだと1行目が通り '221821' を合成していた）
    ENGINES_SINGLE_LINE=1
    case "$ENGINES_NODE" in *[$'\n\r']* ) ENGINES_SINGLE_LINE=0 ;; esac
    if [ "$ENGINES_SINGLE_LINE" -eq 1 ] && printf '%s' "$ENGINES_NODE" \
        | grep -Eq '^[[:space:]]*[\^~]?(>=|>)?[[:space:]]*[0-9]+(\.[0-9x]+)*[[:space:]]*$'; then
      NODE_VERSION="$(printf '%s' "$ENGINES_NODE" | tr -cd '0-9.' | cut -d. -f1)"
      [ -n "$NODE_VERSION" ] && NODE_SOURCE="engines.node"
    else
      note "WARN: engines.node が範囲/OR 指定のため一意に決められない: '$ENGINES_NODE'"
      note "WARN: Node $DEFAULT_NODE を使う。必要なら生成後の ci.yml を手で直せ。"
    fi
  fi
fi

if [ -z "$NODE_VERSION" ]; then
  NODE_VERSION="$DEFAULT_NODE"
  NODE_SOURCE="既定"
fi

# ---------- ステップの決定 ----------

DETECTED=""
STEPS=""
add_step() { # <ステップ名> <コマンド>
  STEPS="$STEPS
      - name: $1
        run: $2"
  DETECTED="$DETECTED $1"
}

has_script lint      && add_step "lint"      "$(run_prefix) lint"
has_script typecheck && add_step "typecheck" "$(run_prefix) typecheck"

if has_script test; then
  # テストランナーを推測してフラグを足さない。Vitest 以外に --run を付けると落ちる
  # （Jest は Unrecognized CLI Parameter で必ず失敗する）。
  # 依存関係から Vitest だと確実に判定できるときだけ、明示的にワンショット実行させる。
  if has_dep vitest; then
    case "$PM" in
      npm|pnpm) add_step "test" "$PM test -- --run" ;;
      yarn)     add_step "test" "yarn test --run" ;;
      bun)      add_step "test" "bun run test -- --run" ;;
    esac
  else
    # CI では CI=true が立つため、主要なランナーは watch に入らない
    add_step "test" "$(run_prefix) test"
  fi
fi

has_script build && add_step "build" "$(run_prefix) build"

if [ -z "$STEPS" ] && ! has_script e2e; then
  say "package.json に lint / typecheck / test / build / e2e のいずれも無い。CI は生成しない。"
  exit 0
fi

# ---------- セットアップ手順 ----------

SETUP=""
case "$PM" in
  pnpm)
    SETUP="      - uses: pnpm/action-setup@v4
"
    # pnpm/action-setup は packageManager フィールドが無い場合 version 入力を必須とする。
    # 省略したまま生成すると Action 自体が落ちるので、ロックファイルから major を推定して明示する。
    if ! jq -e '.packageManager // empty' "$PKG_JSON" >/dev/null 2>&1; then
      LOCKFILE_VERSION="$(grep -m1 '^lockfileVersion:' "$PROJECT_DIR/pnpm-lock.yaml" 2>/dev/null \
        | tr -cd '0-9.')"
      case "$LOCKFILE_VERSION" in
        9*)   PNPM_MAJOR="9" ;;
        6*)   PNPM_MAJOR="8" ;;
        5.4*) PNPM_MAJOR="7" ;;
        *)    PNPM_MAJOR="10" ;;
      esac
      SETUP="      - uses: pnpm/action-setup@v4
        with:
          # package.json に packageManager が無いため version の明示が必須。
          # Corepack を使うなら packageManager を書いた上で、この2行を消してよい。
          version: $PNPM_MAJOR
"
    fi
    ;;
  bun)
    SETUP="      - uses: oven-sh/setup-bun@v2
"
    ;;
esac

# setup-node の cache はロックファイルの実在が前提。無いまま指定すると
# "Dependencies lock file is not found" でジョブが落ちる。
CACHE_LINE=""
if [ "$HAS_LOCK" -eq 1 ]; then
  CACHE_LINE="
          cache: $PM"
fi

if [ "$PM" = "bun" ]; then
  NODE_SETUP=""
else
  NODE_SETUP="      - uses: actions/setup-node@v4
        with:
          node-version: '$NODE_VERSION'$CACHE_LINE
"
fi

# ---------- 依存の脆弱性スキャン ----------
# security.md が「CI に npm audit を組み込む」と要求している。
# ロックファイルが無いと監査できないので、実在する場合のみジョブを作る。
# yarn / bun は系統（classic/berry, bun のバージョン）でコマンドが割れるため生成せず、
# 生成物にコメントを残して導入者に委ねる。憶測で動かないコマンドを書かない。

AUDIT_CMD=""
AUDIT_NOTE=""
if [ "$HAS_LOCK" -eq 1 ]; then
  case "$PM" in
    npm)  AUDIT_CMD="npm audit --audit-level=high" ;;
    pnpm) AUDIT_CMD="pnpm audit --audit-level high" ;;
    yarn) AUDIT_NOTE="yarn は classic と berry でコマンドが異なる（yarn audit --level high / yarn npm audit --severity high）" ;;
    bun)  AUDIT_NOTE="bun は 1.2 以降で bun audit が使える。導入先のバージョンに合わせて追加すること" ;;
  esac
fi

AUDIT_JOB=""
if [ -n "$AUDIT_CMD" ]; then
  AUDIT_JOB="
  audit:
    name: 依存の脆弱性スキャン
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v4
${SETUP}${NODE_SETUP}      - name: audit
        # security.md: critical / high の脆弱性があれば即座に修正する。
        # 既知の未修正脆弱性で止まる場合は --audit-level を critical に上げるか、
        # 個別に精査した上でこのステップに continue-on-error: true を付ける。
        run: $AUDIT_CMD
"
  DETECTED="$DETECTED audit"
elif [ -n "$AUDIT_NOTE" ]; then
  AUDIT_JOB="
  # 依存の脆弱性スキャンは自動生成していない。
  # $AUDIT_NOTE
  # security.md は CI への組み込みを要求しているので、手で追加すること。
"
fi

# ---------- ジョブの組み立て ----------

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

CONTENT="# このプロジェクトの CI
#
# .claude/scripts/bootstrap-project.sh が package.json の scripts を検出して生成した。
# 以後は手で管理してよい。ブートストラップは既存の ci.yml を上書きしない。
#
# 検出したパッケージマネージャ: $PM
# Node のバージョン: ${NODE_VERSION}（${NODE_SOURCE}）
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

jobs:${QUALITY_JOB}${E2E_JOB}${AUDIT_JOB}"

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
note "  パッケージマネージャ: $PM / Node: ${NODE_VERSION}（${NODE_SOURCE}）"
note "  検出したジョブ:$DETECTED"
note "  内容を確認してからコミットしろ。以後この生成は走らない（既存ファイルは上書きしない）。"
