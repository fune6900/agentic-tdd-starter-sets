#!/usr/bin/env bash
# シェルスクリプトの静的検査
#
# 静的解析ツール（shellcheck）が拾えない、このリポジトリ固有の地雷を検出する。
# 全て過去に実際に踏んだもの。踏んだ罠は二度と踏まないよう機械化する。
#
# 移植性のため grep -P は使わない（macOS の BSD grep が非対応）。perl は両環境にある。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

cd "$REPO_ROOT" || exit 1

# 検査対象。このファイル自身と pre-tool-guard.sh は「踏んではいけない書き方」を
# 検出パターンとして本文に含むため、必ず除外する。
shell_files() {
  find .claude .codex tests -name '*.sh' -type f \
    ! -name 'shell-lint.test.sh' \
    ! -name 'pre-tool-guard.sh' \
    ! -name 'pre-tool-guard.test.sh' | sort
}

# 出荷されるスクリプト（テストコードを除く）
shipped_files() {
  find .claude/scripts .codex -name '*.sh' -type f | sort
}

# ══════════════════════════════════════════════
suite "shell-lint: 多バイト文字に隣接する変数展開"
# ══════════════════════════════════════════════
# bash は全角括弧の直前の変数展開で、括弧までを変数名の一部として解釈し、
# set -u 下では unbound variable で即死する。日本語メッセージ内では ${var} で囲むこと。
# 過去に loop-journal.sh と loop-state.sh の2回踏んでいる。

it "裸の変数展開が多バイト文字に隣接していない"
hits="$(shell_files | xargs perl -ne 'print "$ARGV:$.\n" if /\$[A-Za-z_]\w*[^\x00-\x7F]/' 2>/dev/null)"
assert_eq "$hits" ""

# ══════════════════════════════════════════════
suite "shell-lint: コマンド置換の中の die"
# ══════════════════════════════════════════════
# コマンド置換の中で exit しても死ぬのはサブシェルだけで、親は何事もなく続行する。
# これで一度、Vault 未接続なのに削除まで到達して記録を失っている。
# 破壊的操作の手前の判定は必ず親シェルで行うこと。

it "die / exit をコマンド置換の中で呼んでいない"
hits="$(shell_files | xargs perl -ne 'print "$ARGV:$.\n" if /\$\(\s*[^)]*\b(?:die|exit)\b/' 2>/dev/null)"
assert_eq "$hits" ""

# ══════════════════════════════════════════════
suite "shell-lint: 破壊的操作の前提"
# ══════════════════════════════════════════════

it "スクリプトが再帰的な強制削除を使っていない"
# このリポジトリの禁止操作。pre-tool-guard.sh は検知パターンとして保持するので対象外。
hits="$(shell_files | xargs perl -ne 'print "$ARGV:$.\n" if /\brm\s+-[a-z]*r[a-z]*f|\brm\s+-[a-z]*f[a-z]*r/' 2>/dev/null)"
assert_eq "$hits" ""

it "出荷される全スクリプトが set -u を宣言している"
# フックは stdin を読んで早期 exit する構造なので対象外。テストコードも対象外。
missing=""
while IFS= read -r f; do
  case "$f" in
    */hooks/*) continue ;;
  esac
  grep -qE '^set -[a-z]*u' "$f" || missing="$missing $f"
done < <(shipped_files)
assert_eq "$(echo "$missing" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "shell-lint: 基本構文"
# ══════════════════════════════════════════════

it "全スクリプトが bash -n を通る"
bad=""
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || bad="$bad $f"
done < <(shell_files)
assert_eq "$(echo "$bad" | tr -s ' ')" ""

it "全スクリプトに shebang がある"
missing=""
while IFS= read -r f; do
  head -1 "$f" | grep -q '^#!' || missing="$missing $f"
done < <(shell_files)
assert_eq "$(echo "$missing" | tr -s ' ')" ""

report
