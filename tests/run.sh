#!/usr/bin/env bash
# テンプレート自身のテストを全て実行する
#
#   bash tests/run.sh              全件
#   bash tests/run.sh loop-journal 名前でフィルタ
#
# 前提: bash / git / jq。外部のテストフレームワークには依存しない。

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export REPO_ROOT
FILTER="${1:-}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq が必要だ。" >&2; exit 1; }

FAILED_SUITES=()
RAN=0

for t in "$REPO_ROOT"/tests/scripts/*.test.sh; do
  [ -e "$t" ] || continue
  name="$(basename "$t" .test.sh)"
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
