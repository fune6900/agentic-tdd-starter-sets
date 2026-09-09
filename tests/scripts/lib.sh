#!/usr/bin/env bash
# テンプレート自身のシェルテスト用ハーネス
#
# 外部依存を持たない。bash と coreutils だけで動く。
# 各テストは隔離した一時ディレクトリで実行し、実リポジトリと実 Vault には一切触れない。

TESTS_RUN=0
TESTS_FAILED=0
CURRENT=""
SANDBOXES=()

# ---------- 進行表示 ----------

suite() { echo; echo "── $* ──"; }

it() {
  CURRENT="$1"
  TESTS_RUN=$((TESTS_RUN + 1))
}

pass() { echo "  ok   $CURRENT"; }

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL $CURRENT"
  while [ $# -gt 0 ]; do echo "       $1"; shift; done
}

# ---------- アサーション ----------

assert_eq() { # <実際> <期待>
  if [ "$1" = "$2" ]; then pass; else fail "期待: '$2'" "実際: '$1'"; fi
}

assert_contains() { # <文字列> <部分文字列>
  case "$1" in
    *"$2"*) pass ;;
    *) fail "'$2' を含むはずが含まれていない" "実際: '$1'" ;;
  esac
}

assert_file() { # <パス>
  if [ -f "$1" ]; then pass; else fail "ファイルが存在しない: $1"; fi
}

assert_no_file() { # <パス>
  if [ ! -f "$1" ]; then pass; else fail "ファイルが残っている: $1"; fi
}

assert_file_contains() { # <パス> <部分文字列>
  if [ ! -f "$1" ]; then fail "ファイルが存在しない: $1"; return; fi
  if grep -qF -- "$2" "$1"; then pass; else fail "'$2' が $1 に無い"; fi
}

assert_file_not_contains() { # <パス> <部分文字列>
  if [ ! -f "$1" ]; then fail "ファイルが存在しない: $1"; return; fi
  if grep -qF -- "$2" "$1"; then fail "'$2' が $1 に混入している"; else pass; fi
}

# コマンドの終了コードを検査する。出力は $LAST_OUTPUT に入る。
LAST_OUTPUT=""
run() {
  LAST_OUTPUT="$("$@" 2>&1)"
}

assert_ok() { # <コマンド...>
  if run "$@"; then pass; else fail "成功するはずが失敗した" "出力: $LAST_OUTPUT"; fi
}

assert_fails() { # <コマンド...>
  if run "$@"; then fail "失敗するはずが成功した" "出力: $LAST_OUTPUT"; else pass; fi
}

# ---------- サンドボックス ----------

# 擬似プロジェクトと擬似 Vault を隔離した一時ディレクトリに作る。
# 実リポジトリと実 Vault には絶対に触れない。
new_sandbox() {
  local root
  root="$(mktemp -d)" || { echo "mktemp に失敗した" >&2; exit 1; }
  SANDBOXES+=("$root")

  # source した側のテストファイルが参照する
  export SANDBOX_ROOT="$root"
  export SANDBOX_PROJ="$root/proj"
  export SANDBOX_VAULT="$root/vault"
  export SANDBOX_JOURNAL="$SANDBOX_PROJ/.claude/memory/journal"

  mkdir -p "$SANDBOX_PROJ/.claude/scripts" "$SANDBOX_PROJ/.claude/memory" "$SANDBOX_VAULT"

  local s
  for s in loop-journal.sh loop-state.sh bootstrap-project.sh; do
    [ -f "$REPO_ROOT/.claude/scripts/$s" ] && cp "$REPO_ROOT/.claude/scripts/$s" "$SANDBOX_PROJ/.claude/scripts/"
  done

  # 実リポジトリのブランチ名・ループ状態・環境変数を拾わせない
  export CLAUDE_PROJECT_DIR="$SANDBOX_PROJ"
  unset LOOP_EPIC LOOP_VAULT_DIR LOOP_PROJECT_NAME
  ( cd "$SANDBOX_PROJ" && git init -q && git symbolic-ref HEAD refs/heads/main ) || true
}

journal() { bash "$SANDBOX_PROJ/.claude/scripts/loop-journal.sh" "$@"; }
loopstate() { bash "$SANDBOX_PROJ/.claude/scripts/loop-state.sh" "$@"; }
bootstrap() { bash "$SANDBOX_PROJ/.claude/scripts/bootstrap-project.sh" "$@"; }

# 後始末。再帰的な強制削除は使わない（このリポジトリの禁止操作に合わせる）。
cleanup_sandboxes() {
  local d
  for d in "${SANDBOXES[@]:-}"; do
    [ -n "$d" ] || continue
    [ -d "$d" ] || continue
    case "$d" in
      /tmp/*|/var/folders/*|/private/var/folders/*|/private/tmp/*)
        find "$d" -depth -delete 2>/dev/null
        ;;
      *)
        echo "WARN: 想定外のサンドボックスパスなので削除しない: $d" >&2
        ;;
    esac
  done
}

report() {
  echo
  echo "════════════════════════════════════════"
  if [ "$TESTS_FAILED" -eq 0 ]; then
    echo "  全 $TESTS_RUN 件 PASS"
    echo "════════════════════════════════════════"
    return 0
  fi
  echo "  $TESTS_RUN 件中 $TESTS_FAILED 件 FAIL"
  echo "════════════════════════════════════════"
  return 1
}
