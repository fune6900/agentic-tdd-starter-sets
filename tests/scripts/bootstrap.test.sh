#!/usr/bin/env bash
# bootstrap-project.sh のテスト
#
# 重点は「人のリポジトリを壊さないこと」。
# 既存ファイルを上書きしない・検出できなければ何もしない・冪等、の3点を機械で保証する。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

trap cleanup_sandboxes EXIT

CI_FILE=""

setup_target() { # 導入先プロジェクトを模したサンドボックスを作る
  new_sandbox
  CI_FILE="$SANDBOX_PROJ/.github/workflows/ci.yml"
}

write_pkg() { # <scripts の JSON>
  cat > "$SANDBOX_PROJ/package.json" <<EOF
{
  "name": "target-app",
  "version": "1.0.0",
  "scripts": $1
}
EOF
}

# ══════════════════════════════════════════════
suite "bootstrap: 何もしない条件"
# ══════════════════════════════════════════════

setup_target

it "package.json が無ければ CI を生成しない"
bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "package.json が無くても異常終了しない"
assert_ok bootstrap

it "スクリプトが1つも無ければ生成しない"
write_pkg '{}'
bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "対象外のスクリプトだけなら生成しない"
write_pkg '{"dev": "next dev", "start": "next start"}'
bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "壊れた package.json では生成しない"
printf '{ this is not json' > "$SANDBOX_PROJ/package.json"
bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "LOOP_BOOTSTRAP=0 で無効化できる"
write_pkg '{"lint": "eslint .", "build": "next build"}'
LOOP_BOOTSTRAP=0 bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

# ══════════════════════════════════════════════
suite "bootstrap: 既存ファイルを壊さない（最重要）"
# ══════════════════════════════════════════════

setup_target
write_pkg '{"lint": "eslint .", "test": "vitest", "build": "next build"}'
mkdir -p "$SANDBOX_PROJ/.github/workflows"
printf '# 人間が手で書いた CI\nname: My Own CI\n' > "$CI_FILE"

it "既存の ci.yml を上書きしない"
bootstrap >/dev/null 2>&1
assert_file_contains "$CI_FILE" "人間が手で書いた CI"

it "既存 ci.yml があっても異常終了しない"
assert_ok bootstrap

it "既存の他のワークフローを消さない"
printf 'name: Deploy\n' > "$SANDBOX_PROJ/.github/workflows/deploy.yml"
bootstrap >/dev/null 2>&1
assert_file "$SANDBOX_PROJ/.github/workflows/deploy.yml"

# ══════════════════════════════════════════════
suite "bootstrap: 検出したスクリプトだけを組み込む"
# ══════════════════════════════════════════════

setup_target
write_pkg '{"lint": "eslint .", "test": "vitest"}'
bootstrap >/dev/null 2>&1

it "ci.yml を生成する"
assert_file "$CI_FILE"

it "存在する lint を組み込む"
assert_file_contains "$CI_FILE" "npm run lint"

it "存在する test を組み込む"
assert_file_contains "$CI_FILE" "npm test -- --run"

it "存在しない build を組み込まない"
assert_file_not_contains "$CI_FILE" "npm run build"

it "存在しない typecheck を組み込まない"
assert_file_not_contains "$CI_FILE" "npm run typecheck"

it "e2e が無ければ E2E ジョブを作らない"
assert_file_not_contains "$CI_FILE" "playwright install"

setup_target
write_pkg '{"typecheck": "tsc --noEmit", "build": "next build", "e2e": "playwright test"}'
bootstrap >/dev/null 2>&1

it "typecheck を組み込む"
assert_file_contains "$CI_FILE" "npm run typecheck"

it "e2e があれば E2E ジョブを作る"
assert_file_contains "$CI_FILE" "playwright install"

it "e2e ジョブが失敗時にレポートを残す"
assert_file_contains "$CI_FILE" "playwright-report"

it "npm では npx でブラウザを取得する"
assert_file_contains "$CI_FILE" "npx playwright install --with-deps"

setup_target
write_pkg '{"e2e": "playwright test"}'
touch "$SANDBOX_PROJ/pnpm-lock.yaml"
bootstrap >/dev/null 2>&1

it "pnpm では pnpm exec でブラウザを取得する"
assert_file_contains "$CI_FILE" "pnpm exec playwright install --with-deps"

# ══════════════════════════════════════════════
suite "bootstrap: パッケージマネージャの検出"
# ══════════════════════════════════════════════

setup_target
write_pkg '{"build": "next build"}'
touch "$SANDBOX_PROJ/package-lock.json"
bootstrap >/dev/null 2>&1

it "package-lock.json があれば npm ci を使う"
assert_file_contains "$CI_FILE" "npm ci"

setup_target
write_pkg '{"build": "next build"}'
touch "$SANDBOX_PROJ/pnpm-lock.yaml"
bootstrap >/dev/null 2>&1

it "pnpm-lock.yaml があれば pnpm を使う"
assert_file_contains "$CI_FILE" "pnpm install --frozen-lockfile"

it "pnpm のセットアップ action を入れる"
assert_file_contains "$CI_FILE" "pnpm/action-setup"

setup_target
write_pkg '{"build": "next build"}'
touch "$SANDBOX_PROJ/yarn.lock"
bootstrap >/dev/null 2>&1

it "yarn.lock があれば yarn を使う"
assert_file_contains "$CI_FILE" "yarn install --frozen-lockfile"

it "yarn では run を挟まない"
assert_file_contains "$CI_FILE" "yarn build"

# ══════════════════════════════════════════════
suite "bootstrap: Node バージョンの決定"
# ══════════════════════════════════════════════

setup_target
write_pkg '{"build": "next build"}'
bootstrap >/dev/null 2>&1

it "既定は Node 22"
assert_file_contains "$CI_FILE" "node-version: '22'"

setup_target
write_pkg '{"build": "next build"}'
printf 'v20.11.0\n' > "$SANDBOX_PROJ/.nvmrc"
bootstrap >/dev/null 2>&1

it ".nvmrc があればそれに従う"
assert_file_contains "$CI_FILE" "node-version: '20.11.0'"

# ══════════════════════════════════════════════
suite "bootstrap: 冪等性と出力の妥当性"
# ══════════════════════════════════════════════

setup_target
write_pkg '{"lint": "eslint .", "test": "vitest", "build": "next build"}'
bootstrap >/dev/null 2>&1
first="$(cat "$CI_FILE")"
bootstrap >/dev/null 2>&1
second="$(cat "$CI_FILE")"

it "2回実行しても内容が変わらない"
assert_eq "$second" "$first"

it "生成された YAML が妥当である"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  assert_ok python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$CI_FILE"
else
  # PyYAML が無い環境では最低限の構造だけ見る
  assert_file_contains "$CI_FILE" "jobs:"
fi

it "GitHub Actions の式が展開されずに残っている"
assert_file_contains "$CI_FILE" 'group: ci-${{ github.ref }}'

it "--dry-run はファイルを作らない"
setup_target
write_pkg '{"build": "next build"}'
bootstrap --dry-run >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "--dry-run は生成予定の内容を表示する"
run bootstrap --dry-run
assert_contains "$LAST_OUTPUT" "name: CI"

it "未知の引数は拒否される"
assert_fails bootstrap --nonsense

report
