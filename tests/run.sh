#!/usr/bin/env bash
# テンプレート自身のテストを全て実行する
#
#   bash tests/run.sh              全件
#   bash tests/run.sh loop-journal 名前でフィルタ
#   RUN_EXCLUDE='monitor-image-smoke' bash tests/run.sh
#                                  スイートを除外（スペース区切り・完全一致）
#
# RUN_EXCLUDE: tests/scripts/<名前>.test.sh の拡張子抜きの名前。
#   使える文字は英数字と . _ -（先頭は英数字）。存在しない名前・不正な値は
#   1件も実行せずに非0で終わる（除外が黙って効かない事態を防ぐ）。
#   フィルタ引数とは独立に、全スイートに対して名前を検証する。
#
# 前提: bash / git / jq。外部のテストフレームワークには依存しない。

set -uo pipefail

# 個別のテストファイルと同じく環境変数を尊重する。
# ここで無条件に上書きすると、隔離コピーへの変異テストが実物を走らせてしまう。
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export REPO_ROOT
FILTER="${1:-}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq が必要だ。" >&2; exit 1; }

# 除外指定の検証。検証は case で文字種だけを見る。比較は文字列等価（グロブに埋めない）。
EXCLUDES=()
EXCLUDE_RAW="${RUN_EXCLUDE:-}"
case "$EXCLUDE_RAW" in
  *[!a-zA-Z0-9._\ -]*)
    echo "ERROR: RUN_EXCLUDE に使えない文字がある（英数字と . _ - のスペース区切りのみ）。" >&2
    exit 1
    ;;
esac
for ex in $EXCLUDE_RAW; do
  case "$ex" in
    [a-zA-Z0-9]*) ;;
    *)
      echo "ERROR: RUN_EXCLUDE の名前は英数字で始める。" >&2
      exit 1
      ;;
  esac
  found=0
  for t in "$REPO_ROOT"/tests/scripts/*.test.sh; do
    [ -e "$t" ] || continue
    [ "$(basename "$t" .test.sh)" = "$ex" ] && found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "ERROR: RUN_EXCLUDE に存在しないスイート名がある: ${ex}" >&2
    exit 1
  fi
  EXCLUDES+=("$ex")
done

is_excluded() {
  local e
  for e in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    [ "$e" = "$1" ] && return 0
  done
  return 1
}

FAILED_SUITES=()
RAN=0

for t in "$REPO_ROOT"/tests/scripts/*.test.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t" .test.sh)"
  if is_excluded "$name"; then continue; fi
  if [ -n "$FILTER" ]; then
    case "$name" in
      *"$FILTER"*) ;;
      *) continue ;;
    esac
  fi

  echo
  echo "════════════════════════════════════════"
  echo "  $name"
  echo "════════════════════════════════════════"
  RAN=$((RAN + 1))
  bash "$t" || FAILED_SUITES+=("$name")
done

echo
echo "════════════════════════════════════════"
if [ "$RAN" -eq 0 ]; then
  echo "  実行対象のテストが無い（フィルタ: '${FILTER}'）"
  echo "════════════════════════════════════════"
  exit 1
fi

if [ "${#FAILED_SUITES[@]}" -eq 0 ]; then
  echo "  全 $RAN スイート PASS"
  echo "════════════════════════════════════════"
  exit 0
fi

echo "  $RAN スイート中 ${#FAILED_SUITES[@]} スイート FAIL:"
for s in "${FAILED_SUITES[@]}"; do echo "    - $s"; done
echo "════════════════════════════════════════"
exit 1
