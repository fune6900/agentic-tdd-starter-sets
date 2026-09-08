#!/usr/bin/env bash
# ドキュメントと実体の整合テスト
#
# このリポジトリの成果物はドキュメントそのものだ。
# 「ルールに書いてあるファイルが存在しない」「コマンド表に載っているのに定義が無い」は
# 機能不全そのものなので、機械で検出する。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

cd "$REPO_ROOT" || exit 1

# ══════════════════════════════════════════════
suite "docs: @参照の解決"
# ══════════════════════════════════════════════

# CLAUDE.md / AGENTS.md / rules が `@.claude/...` で参照するファイルは実在しなければならない
missing=""
while IFS= read -r ref; do
  [ -f "$ref" ] || missing="$missing $ref"
done < <(grep -rhoE '@\.claude/[A-Za-z0-9._/-]+\.md' CLAUDE.md AGENTS.md .claude/rules/*.md .claude/memory/*.md 2>/dev/null \
         | sed 's/^@//' | sort -u)

it "@参照されたファイルが全て実在する"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "docs: スラッシュコマンドの定義"
# ══════════════════════════════════════════════

missing=""
while IFS= read -r cmd; do
  [ -f ".claude/commands/${cmd}.md" ] || missing="$missing /$cmd"
done < <(grep -oE '^\| `/[a-z-]+`' CLAUDE.md | sed 's/^| `\///; s/`$//' | sort -u)

it "CLAUDE.md のコマンド表に載る全コマンドに定義がある"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "Claude と Codex のコマンド定義が同数ある"
assert_eq "$(find .codex/commands -name '*.md' | wc -l | tr -d ' ')" \
          "$(find .claude/commands -name '*.md' | wc -l | tr -d ' ')"

missing=""
for f in .claude/commands/*.md; do
  base="$(basename "$f")"
  [ -f ".codex/commands/$base" ] || missing="$missing $base"
done

it "全 Claude コマンドに対応する Codex 版がある"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "docs: サブエージェントの定義"
# ══════════════════════════════════════════════

missing=""
while IFS= read -r agent; do
  [ -f ".claude/agents/${agent}.md" ] || missing="$missing $agent"
done < <(grep -rhoE 'sub-agent-[a-z-]+' CLAUDE.md .claude/rules/*.md .claude/commands/*.md 2>/dev/null | sort -u)

it "参照される全サブエージェントに定義がある"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "Claude と Codex のエージェント定義が同数ある"
assert_eq "$(find .codex/agents -name '*.toml' | wc -l | tr -d ' ')" \
          "$(find .claude/agents -name '*.md' | wc -l | tr -d ' ')"

# ══════════════════════════════════════════════
suite "docs: スクリプト参照"
# ══════════════════════════════════════════════

missing=""
while IFS= read -r script; do
  [ -f "$script" ] || missing="$missing $script"
done < <(grep -rhoE '\.claude/scripts/[a-z-]+\.sh' CLAUDE.md AGENTS.md README.md .claude .codex 2>/dev/null | sort -u)

it "ドキュメントが参照する全スクリプトが実在する"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "全スクリプトに実行権がある"
noexec=""
for f in .claude/scripts/*.sh; do
  [ -x "$f" ] || noexec="$noexec $f"
done
assert_eq "$(echo "$noexec" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "docs: フック設定の実体"
# ══════════════════════════════════════════════

missing=""
while IFS= read -r hook; do
  [ -f "$hook" ] || missing="$missing $hook"
done < <(grep -oE '\.claude/(hooks|scripts)/[a-z-]+\.sh' .claude/settings.json | sort -u)

it "settings.json が参照する全フック・スクリプトが実在する"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "settings.json が妥当な JSON である"
assert_ok jq empty .claude/settings.json

# ══════════════════════════════════════════════
suite "docs: 外部記憶の記載整合"
# ══════════════════════════════════════════════

it "ジャーナルの一時ポインタが .gitignore されている"
assert_ok git check-ignore -q .claude/memory/journal/.vault

it "ジャーナル本体は .gitignore されていない"
assert_fails git check-ignore -q .claude/memory/journal/README.md

it "loop-journal.sh のサブコマンドがドキュメントと一致する"
undocumented=""
for sub in init context start inner outer flush status where; do
  grep -qF "loop-journal.sh $sub" .claude/rules/loop-engineering.md \
    .claude/commands/*.md .claude/memory/journal/README.md README.md 2>/dev/null \
    || undocumented="$undocumented $sub"
done
assert_eq "$(echo "$undocumented" | tr -s ' ')" ""

report
