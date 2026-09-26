#!/bin/bash
# PreToolUse: 危険なコマンド実行前の警告表示
# Claude/Codex どちらのフック入力でも動くよう、複数の JSON 形状を許容する。
# exit 2 = ブロック（stderrがエージェントに表示される）
# exit 0 = 続行

INPUT=$(cat)
COMMAND=$(
  echo "$INPUT" | jq -r '
    .tool_input.command //
    .tool_input.cmd //
    .arguments.command //
    .arguments.cmd //
    .command //
    .cmd //
    empty
  '
)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# 危険パターンの定義
DANGEROUS_PATTERNS=(
  "rm -rf"
  "rm -r /"
  "DROP TABLE"
  "DROP DATABASE"
  "TRUNCATE"
  "git push --force"
  "git push -f"
  "git reset --hard"
  "git clean -fd"
  "chmod -R 777"
  "> /dev/sda"
  "mkfs"
  "dd if="
  ":(){ :|:& };:"
  "sudo "
  "--no-verify"
)

for pattern in "${DANGEROUS_PATTERNS[@]}"; do
  if echo "$COMMAND" | grep -Fqi -- "$pattern"; then
    echo "⚠ 危険なコマンドを検知しました: $COMMAND" >&2
    echo "パターン: $pattern" >&2
    echo "このコマンドはブロックされました。Codex ガードレールにより実行を拒否します。" >&2
    exit 2
  fi
done

# .env 系ファイルへのアクセス。permissions.md の禁止はシェル経由でも守らせる。
# 部分一致だと process.env まで止まるので、パス区切り・クォート・リダイレクトで語に割って語全体で判定する。
# .env.example はキー名だけのテンプレートなので通す。
while IFS= read -r word; do
  case "$word" in
    .env.example) ;;
    .env|.env.*|.env-*)
      echo "⚠ .env 系ファイルへのアクセスを検知しました: $word" >&2
      echo "このコマンドはブロックされました。シークレットはシェルから読み書きしません。" >&2
      exit 2
      ;;
  esac
done < <(printf '%s\n' "$COMMAND" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -c 'a-z0-9_.-' '\n')

exit 0
