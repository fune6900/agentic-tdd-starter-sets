#!/usr/bin/env bash
# bootstrap-project.sh のテスト
#
# 重点は2つ。
#   1. 人のリポジトリを壊さないこと（既存ファイル非破壊・検出できなければ何もしない・冪等）
#   2. 生成した CI が導入先で**実際に動く**こと
#
# 2 は独立レビューで重要度「高」3件が出た領域。構文的に妥当な YAML でも、
# 意味的に壊れていれば導入先の CI は赤くなる。回帰テストとして固定する。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

trap cleanup_sandboxes EXIT

CI_FILE=""

setup_target() { # 導入先プロジェクトを模したサンドボックスを作る
  new_sandbox
  CI_FILE="$SANDBOX_PROJ/.github/workflows/ci.yml"
}

write_pkg() { # <package.json の中身（scripts 等を含む完全な JSON）>
  printf '%s\n' "$1" > "$SANDBOX_PROJ/package.json"
}

write_scripts() { # <scripts の JSON> — 依存関係が要らないケース用の短縮形
  write_pkg "{\"name\":\"target-app\",\"version\":\"1.0.0\",\"scripts\":$1}"
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
write_scripts '{}'
bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "対象外のスクリプトだけなら生成しない"
write_scripts '{"dev": "next dev", "start": "next start"}'
bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "壊れた package.json では生成しない"
printf '{ this is not json' > "$SANDBOX_PROJ/package.json"
bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "壊れた package.json では理由を報告する"
run bootstrap
assert_contains "$LAST_OUTPUT" "妥当な JSON ではない"

it "jq が無ければ生成せず理由を報告する"
# jq だけを PATH から外した環境を作る（他のコマンドは symlink で通す）
write_scripts '{"build": "next build"}'
nojq="$SANDBOX_ROOT/nojq-bin"
mkdir -p "$nojq"
for c in bash sh env head sed tr cut grep date mkdir cat git basename dirname find; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$nojq/$c"
done
LAST_OUTPUT="$(PATH="$nojq" bash "$SANDBOX_PROJ/.claude/scripts/bootstrap-project.sh" 2>&1)"
assert_contains "$LAST_OUTPUT" "jq が無いため"

it "jq が無い場合に CI を生成していない"
assert_no_file "$CI_FILE"

it "LOOP_BOOTSTRAP=0 で無効化できる"
setup_target
write_scripts '{"lint": "eslint .", "build": "next build"}'
LOOP_BOOTSTRAP=0 bootstrap >/dev/null 2>&1
assert_no_file "$CI_FILE"

# ══════════════════════════════════════════════
suite "bootstrap: 既存ファイルを壊さない（最重要）"
# ══════════════════════════════════════════════

setup_target
write_scripts '{"lint": "eslint .", "test": "vitest", "build": "next build"}'
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
write_scripts '{"lint": "eslint .", "test": "vitest"}'
bootstrap >/dev/null 2>&1

it "ci.yml を生成する"
assert_file "$CI_FILE"

it "存在する lint を組み込む"
assert_file_contains "$CI_FILE" "npm run lint"

it "存在する test を組み込む"
assert_file_contains "$CI_FILE" "name: test"

it "存在しない build を組み込まない"
assert_file_not_contains "$CI_FILE" "npm run build"

it "存在しない typecheck を組み込まない"
assert_file_not_contains "$CI_FILE" "npm run typecheck"

it "e2e が無ければ E2E ジョブを作らない"
assert_file_not_contains "$CI_FILE" "playwright install"

setup_target
write_scripts '{"typecheck": "tsc --noEmit", "build": "next build", "e2e": "playwright test"}'
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
write_scripts '{"e2e": "playwright test"}'
printf "lockfileVersion: '9.0'\n" > "$SANDBOX_PROJ/pnpm-lock.yaml"
bootstrap >/dev/null 2>&1

it "pnpm では pnpm exec でブラウザを取得する"
assert_file_contains "$CI_FILE" "pnpm exec playwright install --with-deps"

it "e2e しか無くても E2E ジョブだけを生成する"
assert_file_not_contains "$CI_FILE" "quality:"

# ══════════════════════════════════════════════
suite "bootstrap: テストランナーを推測しない（回帰・重要度 高）"
# ══════════════════════════════════════════════
# `--run` は Vitest 専用フラグ。Jest に渡すと Unrecognized CLI Parameter で必ず落ちる。
# 依存関係から Vitest だと確認できるときだけ付ける。

setup_target
write_pkg '{"name":"a","scripts":{"test":"jest"},"devDependencies":{"jest":"^29.0.0"}}'
bootstrap >/dev/null 2>&1

it "Jest プロジェクトに --run を付けない"
assert_file_not_contains "$CI_FILE" -- "--run"

it "Jest でも test ステップ自体は生成する"
assert_file_contains "$CI_FILE" "npm run test"

setup_target
write_pkg '{"name":"a","scripts":{"test":"vitest"},"devDependencies":{"vitest":"^2.0.0"}}'
bootstrap >/dev/null 2>&1

it "Vitest プロジェクトには --run を付ける"
assert_file_contains "$CI_FILE" "npm test -- --run"

setup_target
write_pkg '{"name":"a","scripts":{"test":"node --test"}}'
bootstrap >/dev/null 2>&1

it "テストランナーが判別できなければフラグを付けない"
assert_file_not_contains "$CI_FILE" -- "--run"

setup_target
write_pkg '{"name":"a","scripts":{"test":"vitest"},"dependencies":{"vitest":"^2.0.0"}}'
bootstrap >/dev/null 2>&1

it "dependencies 側の vitest も検出する"
assert_file_contains "$CI_FILE" "npm test -- --run"

setup_target
write_pkg '{"name":"a","scripts":{"test":"vitest"},"devDependencies":{"vitest":"^2.0.0"}}'
touch "$SANDBOX_PROJ/bun.lockb"
bootstrap >/dev/null 2>&1

it "bun でも scripts.test を尊重する（組み込みランナーを直接叩かない）"
assert_file_contains "$CI_FILE" "bun run test"

# ══════════════════════════════════════════════
suite "bootstrap: pnpm のセットアップ（回帰・重要度 高）"
# ══════════════════════════════════════════════
# pnpm/action-setup は packageManager フィールドが無い場合 version 入力が必須。
# 省略すると Action 自体が落ちる。

setup_target
write_scripts '{"build": "next build"}'
printf "lockfileVersion: '9.0'\n" > "$SANDBOX_PROJ/pnpm-lock.yaml"
bootstrap >/dev/null 2>&1

it "packageManager が無ければ pnpm の version を明示する"
assert_file_contains "$CI_FILE" "version: 9"

setup_target
write_pkg '{"name":"a","scripts":{"build":"next build"},"packageManager":"pnpm@9.12.0"}'
printf "lockfileVersion: '9.0'\n" > "$SANDBOX_PROJ/pnpm-lock.yaml"
bootstrap >/dev/null 2>&1

it "packageManager があれば version を書かない"
# node-version: を誤検出しないよう、スクリプトが出す固有のコメント行で判定する
assert_file_not_contains "$CI_FILE" "packageManager が無いため"

setup_target
write_scripts '{"build": "next build"}'
printf "lockfileVersion: '6.0'\n" > "$SANDBOX_PROJ/pnpm-lock.yaml"
bootstrap >/dev/null 2>&1

it "古いロックファイルからは対応する pnpm メジャーを選ぶ"
assert_file_contains "$CI_FILE" "version: 8"

it "pnpm のセットアップは setup-node より前に置く"
# setup-node の cache: pnpm は pnpm が PATH 上にあることを前提にしている
assert_ok bash -c "grep -n 'pnpm/action-setup' '$CI_FILE' | head -1 | cut -d: -f1 | \
  { read -r a; grep -n 'setup-node' '$CI_FILE' | head -1 | cut -d: -f1 | { read -r b; [ \"\$a\" -lt \"\$b\" ]; }; }"

# ══════════════════════════════════════════════
suite "bootstrap: Node バージョン（回帰・重要度 高）"
# ══════════════════════════════════════════════
# engines.node の範囲指定から数字だけを抜くと ">=18 <21" が "1821" になり CI が壊れる。
# 一意に決められない指定は推測せず既定へ倒す。

setup_target
write_scripts '{"build": "next build"}'
bootstrap >/dev/null 2>&1

it "既定は Node 22"
assert_file_contains "$CI_FILE" "node-version: '22'"

setup_target
write_pkg '{"name":"a","scripts":{"build":"next build"},"engines":{"node":">=18 <21"}}'
bootstrap >/dev/null 2>&1

it "範囲指定では無効なバージョンを合成しない"
assert_file_not_contains "$CI_FILE" "1821"

it "範囲指定では既定へ倒す"
assert_file_contains "$CI_FILE" "node-version: '22'"

it "範囲指定であることを警告する"
setup_target
write_pkg '{"name":"a","scripts":{"build":"next build"},"engines":{"node":">=18 <21"}}'
run bootstrap
assert_contains "$LAST_OUTPUT" "一意に決められない"

setup_target
write_pkg '{"name":"a","scripts":{"build":"next build"},"engines":{"node":"18.x || 20.x"}}'
bootstrap >/dev/null 2>&1

it "OR 指定でも既定へ倒す"
assert_file_contains "$CI_FILE" "node-version: '22'"

setup_target
write_pkg '{"name":"a","scripts":{"build":"next build"},"engines":{"node":"^20.9.0"}}'
bootstrap >/dev/null 2>&1

it "単項の単純指定は採用する"
assert_file_contains "$CI_FILE" "node-version: '20'"

setup_target
write_pkg '{"name":"a","scripts":{"build":"next build"},"engines":{"node":">=18"}}'
bootstrap >/dev/null 2>&1

it "単項の比較指定も採用する"
assert_file_contains "$CI_FILE" "node-version: '18'"

setup_target
write_scripts '{"build": "next build"}'
printf 'v20.11.0\n' > "$SANDBOX_PROJ/.nvmrc"
bootstrap >/dev/null 2>&1

it ".nvmrc があればそれに従う"
assert_file_contains "$CI_FILE" "node-version: '20.11.0'"

setup_target
write_scripts '{"build": "next build"}'
printf 'lts/iron\n' > "$SANDBOX_PROJ/.nvmrc"
bootstrap >/dev/null 2>&1

it ".nvmrc の lts エイリアスをそのまま通す"
assert_file_contains "$CI_FILE" "node-version: 'lts/iron'"

setup_target
write_pkg '{"name":"a","scripts":{"build":"next build"},"engines":{"node":"20"}}'
printf 'v18.19.0\n' > "$SANDBOX_PROJ/.nvmrc"
bootstrap >/dev/null 2>&1

it ".nvmrc は engines.node より優先される"
assert_file_contains "$CI_FILE" "node-version: '18.19.0'"

# ══════════════════════════════════════════════
suite "bootstrap: パッケージマネージャとキャッシュ"
# ══════════════════════════════════════════════

setup_target
write_scripts '{"build": "next build"}'
touch "$SANDBOX_PROJ/package-lock.json"
bootstrap >/dev/null 2>&1

it "package-lock.json があれば npm ci を使う"
assert_file_contains "$CI_FILE" "npm ci"

it "ロックファイルがあれば cache を有効にする"
assert_file_contains "$CI_FILE" "cache: npm"

setup_target
write_scripts '{"build": "next build"}'
bootstrap >/dev/null 2>&1

it "ロックファイルが無ければ npm install を使う"
assert_file_contains "$CI_FILE" "npm install"

it "ロックファイルが無ければ cache を指定しない"
# setup-node の cache はロックファイルの実在が前提。無いとジョブが落ちる
assert_file_not_contains "$CI_FILE" "cache:"

setup_target
write_scripts '{"build": "next build"}'
printf "lockfileVersion: '9.0'\n" > "$SANDBOX_PROJ/pnpm-lock.yaml"
bootstrap >/dev/null 2>&1

it "pnpm-lock.yaml があれば pnpm を使う"
assert_file_contains "$CI_FILE" "pnpm install --frozen-lockfile"

it "pnpm のセットアップ action を入れる"
assert_file_contains "$CI_FILE" "pnpm/action-setup"

setup_target
write_scripts '{"build": "next build"}'
touch "$SANDBOX_PROJ/yarn.lock"
bootstrap >/dev/null 2>&1

it "yarn.lock があれば yarn を使う"
assert_file_contains "$CI_FILE" "yarn install --frozen-lockfile"

it "yarn では run を挟まない"
assert_file_contains "$CI_FILE" "yarn build"

setup_target
write_scripts '{"build": "next build"}'
touch "$SANDBOX_PROJ/bun.lockb"
bootstrap >/dev/null 2>&1

it "bun.lockb があれば bun をセットアップする"
assert_file_contains "$CI_FILE" "oven-sh/setup-bun"

setup_target
write_scripts '{"build": "next build"}'
touch "$SANDBOX_PROJ/package-lock.json" "$SANDBOX_PROJ/yarn.lock"

it "ロックファイルが複数あれば警告する"
run bootstrap
assert_contains "$LAST_OUTPUT" "ロックファイルが複数ある"

# ══════════════════════════════════════════════
suite "bootstrap: 冪等性と出力の妥当性"
# ══════════════════════════════════════════════

setup_target
write_pkg '{"name":"a","scripts":{"lint":"eslint .","test":"vitest","build":"next build","e2e":"playwright test"},"devDependencies":{"vitest":"^2.0.0"}}'
touch "$SANDBOX_PROJ/package-lock.json"
bootstrap >/dev/null 2>&1
first="$(cat "$CI_FILE")"
bootstrap >/dev/null 2>&1
second="$(cat "$CI_FILE")"

it "2回実行しても内容が変わらない"
assert_eq "$second" "$first"

it "生成された YAML が構文として妥当である"
if python3 -c 'import yaml' 2>/dev/null; then
  assert_ok python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" "$CI_FILE"
else
  # PyYAML が無い環境では構文検査ができない。黙って弱いチェックへ縮退させず、
  # 事実を明示した上で構造だけ見る（CI では PyYAML を明示的に入れて必ずパースさせている）
  echo "       （PyYAML が無いため構文検査をスキップ。構造のみ検証する）"
  assert_file_contains "$CI_FILE" "jobs:"
fi

it "GitHub Actions の式が展開されずに残っている"
assert_file_contains "$CI_FILE" 'group: ci-${{ github.ref }}'

it "node-version が妥当な形式である"
# 構文が通っても値が壊れていれば CI は動かない。意味の検証を構文検査に頼らない
nv="$(grep -m1 'node-version:' "$CI_FILE" | sed "s/.*node-version: '\\(.*\\)'.*/\\1/")"
assert_ok bash -c "printf '%s' '$nv' | grep -Eq '^(lts/[a-z]+|[0-9]+(\\.[0-9]+)*)$'"

it "quality ジョブに install ステップがある"
assert_file_contains "$CI_FILE" "run: npm ci"

it "--dry-run はファイルを作らない"
setup_target
write_scripts '{"build": "next build"}'
bootstrap --dry-run >/dev/null 2>&1
assert_no_file "$CI_FILE"

it "--dry-run は生成予定の内容を表示する"
run bootstrap --dry-run
assert_contains "$LAST_OUTPUT" "name: CI"

it "未知の引数は拒否される"
assert_fails bootstrap --nonsense

# ══════════════════════════════════════════════
suite "bootstrap: --quiet の無音性"
# ══════════════════════════════════════════════
# SessionStart フックの stdout はそのままコンテキストに入る。何もしないときは黙る。

setup_target

it "package.json が無いとき --quiet は無音"
run bootstrap --quiet
assert_eq "$LAST_OUTPUT" ""

it "対象スクリプトが無いとき --quiet は無音"
write_scripts '{"dev": "next dev"}'
run bootstrap --quiet
assert_eq "$LAST_OUTPUT" ""

it "既存 ci.yml があるとき --quiet は無音"
write_scripts '{"build": "next build"}'
mkdir -p "$SANDBOX_PROJ/.github/workflows"
printf 'name: existing\n' > "$CI_FILE"
run bootstrap --quiet
assert_eq "$LAST_OUTPUT" ""

it "生成したときは --quiet でも報告する"
setup_target
write_scripts '{"build": "next build"}'
run bootstrap --quiet
assert_contains "$LAST_OUTPUT" "CI ワークフローを生成した"

report
