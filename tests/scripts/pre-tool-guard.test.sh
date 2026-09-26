#!/usr/bin/env bash
# pre-tool-guard.sh（Claude / Codex）のテスト
#
# 重点は .env 系ファイルへの Bash 経由のアクセス。
# settings.json の Edit / Read の deny はファイル操作ツールにしか効かず、
# allow 済みの `cat` `echo` `cp` `mv` を通せば素通りになる。フックで止める。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

GUARDS=(".claude/hooks/pre-tool-guard.sh" ".codex/hooks/pre-tool-guard.sh")

guard() { # <フックのパス> <コマンド文字列>
  jq -n --arg c "$2" '{tool_input: {command: $c}}' | bash "$REPO_ROOT/$1"
}

for g in "${GUARDS[@]}"; do

# ══════════════════════════════════════════════
suite "$g: .env 系ファイルへのアクセスを止める"
# ══════════════════════════════════════════════

for cmd in \
  'cat .env' \
  'echo DATABASE_URL=x > .env' \
  'cp attacker.txt .env.production' \
  'mv .env.local /tmp/leak' \
  'grep KEY apps/web/.env' \
  'cat "./.env.development"' \
  'echo x | tee .env.test' \
  'cat .ENV' \
  'cp .env.example .env'; do
  it "ブロック: $cmd"
  assert_fails guard "$g" "$cmd"
done

it "ブロック時の終了コードは 2（フックの拒否）"
guard "$g" 'cat .env' >/dev/null 2>&1
assert_eq "$?" "2"

# ══════════════════════════════════════════════
suite "$g: .env を含むが別物は通す"
# ══════════════════════════════════════════════

for cmd in \
  'cat .env.example' \
  'cp .env.example /tmp/template' \
  'echo $NODE_ENV' \
  'node -e "console.log(process.env.HOME)"' \
  'cat .envrc' \
  'git status'; do
  it "通過: $cmd"
  assert_ok guard "$g" "$cmd"
done

# 名前で検知する方式の限界。security.md に書いた「塞いでいない経路」をテストで固定する。
# ここが落ちたら、限界の記述を実態に合わせて更新すること。
it "既知の限界: ファイル名を書かない再帰 grep は通る"
assert_ok guard "$g" 'grep -rn API_KEY .'

# ══════════════════════════════════════════════
suite "$g: 既存の危険パターン"
# ══════════════════════════════════════════════

it "git reset --hard は引き続きブロックされる"
assert_fails guard "$g" 'git reset --hard HEAD~1'

done

report
