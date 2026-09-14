#!/usr/bin/env bash
# pre-tool-guard.sh のテスト
#
# **これは検知を緩める変更に対するテストだ。** 緩めすぎれば実際の破壊的操作を通す。
# 検知漏れは誤爆より遥かに高コストなので、「ブロックされるべきケース」を先に固める。
#
# このファイルは危険コマンドの文字列を検査対象として大量に含むため、
# shell-lint.test.sh の走査からは除外されている（pre-tool-guard.sh 自身と同じ理由）。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

GUARD="$REPO_ROOT/.claude/hooks/pre-tool-guard.sh"
CODEX_GUARD="$REPO_ROOT/.codex/hooks/pre-tool-guard.sh"

# フックに Bash ツールの入力を模した JSON を流し込む。
# exit 2 = ブロック / exit 0 = 続行
guard() { # <コマンド文字列> [フックのパス]
  local cmd="$1" hook="${2:-$GUARD}"
  printf '%s' "$cmd" \
    | jq -R -s '{tool_name:"Bash", tool_input:{command:.}}' \
    | bash "$hook" >/dev/null 2>&1
}

assert_blocked() { # <コマンド> [フック]
  if guard "$1" "${2:-$GUARD}"; then
    fail "ブロックされるべきコマンドが通った" "コマンド: $1"
  else
    pass
  fi
}

assert_allowed() { # <コマンド> [フック]
  if guard "$1" "${2:-$GUARD}"; then
    pass
  else
    fail "通るべきコマンドがブロックされた" "コマンド: $1"
  fi
}

# ══════════════════════════════════════════════
suite "pre-tool-guard: ブロックされるべきコマンド（検知漏れを作らない）"
# ══════════════════════════════════════════════

it "再帰的な強制削除"
assert_blocked 'rm -rf /tmp/x'

it "ホームディレクトリの再帰削除"
assert_blocked 'rm -rf ~'

it "ルート直下の再帰削除"
assert_blocked 'rm -r /'

it "先行コマンドの後ろに続く場合"
assert_blocked 'cd /tmp && rm -rf build'

it "セミコロンで区切られた場合"
assert_blocked 'echo start; rm -rf build'

it "sudo 経由"
assert_blocked 'sudo rm -rf /var/log'

it "find -exec 経由"
assert_blocked 'find . -name "*.tmp" -exec rm -rf {} \;'

it "パイプの先"
assert_blocked 'echo x | xargs rm -rf'

it "コマンド置換の中"
assert_blocked 'echo $(rm -rf /tmp/x)'

it "強制 push（ロングオプション）"
assert_blocked 'git push --force origin main'

it "強制 push（ショートオプション）"
assert_blocked 'git push -f origin main'

it "ハードリセット"
assert_blocked 'git reset --hard HEAD~1'

it "作業ツリーの一掃"
assert_blocked 'git clean -fd'

it "全権限の再帰付与"
assert_blocked 'chmod -R 777 /var/www'

it "ブロックデバイスへの書き込み"
assert_blocked 'echo x > /dev/sda'

it "ファイルシステムの作成"
assert_blocked 'mkfs.ext4 /dev/sda1'

it "ディスクの直接書き込み"
assert_blocked 'dd if=/dev/zero of=/dev/sda'

it "フォークボム"
assert_blocked ':(){ :|:& };:'

it "ヒアドキュメントで DB に流し込む SQL"
# psql は本文を実行する消費側。本文は SQL の走査対象に残る
assert_blocked "$(printf 'psql -d app <<%sSQL%s\nDROP TABLE users;\nSQL\n' "'" "'")"

it "SQL のテーブル削除"
assert_blocked 'psql -c "DROP TABLE users"'

it "SQL のデータベース削除"
assert_blocked 'mysql -e "DROP DATABASE app"'

it "SQL の全行削除"
assert_blocked 'psql -c "TRUNCATE logs"'

it "大文字小文字を問わない"
assert_blocked 'psql -c "drop table users"'

# ══════════════════════════════════════════════
suite "pre-tool-guard: 展開されうる文字列は従来通り検査する"
# ══════════════════════════════════════════════
# ダブルクォートの中でもコマンド置換・変数展開が起きうる。
# 「クォートされているから安全」とは限らない。

it "コマンド置換を含むダブルクォートは検査対象のまま"
assert_blocked 'echo "result: $(rm -rf /tmp/x)"'

it "バッククォートを含むダブルクォートは検査対象のまま"
assert_blocked 'echo "result: `rm -rf /tmp/x`"'

it "変数展開を含むダブルクォートは検査対象のまま"
assert_blocked 'echo "$HOME rm -rf /tmp/x"'

# ══════════════════════════════════════════════
suite "pre-tool-guard: 誤爆してはいけないもの（Issue #9）"
# ══════════════════════════════════════════════
# 実行されないことが構造的に保証された部分だけを検査対象から外す。

it "ヒアドキュメント本文に危険コマンド名が出てくるだけ"
assert_allowed "$(printf 'cat > doc.md <<%sEOF%s\n危険な操作の例: rm -rf /\nEOF\n' "'" "'")"

it "ヒアドキュメント本文にフォークボムが出てくるだけ"
assert_allowed "$(printf 'cat > doc.md <<%sEOF%s\n:(){ :|:& };:\nEOF\n' "'" "'")"

it "ヒアドキュメント本文に SQL が出てくるだけ"
assert_allowed "$(printf 'cat > doc.md <<%sEOF%s\n禁止: DROP TABLE users\nEOF\n' "'" "'")"

it "クォートなしのヒアドキュメントでも本文は対象外"
assert_allowed "$(printf 'cat > doc.md <<EOF\n例: git push --force は禁止\nEOF\n')"

it "インデント付きヒアドキュメント（<<-）"
assert_allowed "$(printf 'cat > doc.md <<-%sEOF%s\n\t例: git reset --hard\n\tEOF\n' "'" "'")"

it "ヒアドキュメントの開始行自体は検査する"
# 本文を外しても、開始行に書かれたコマンドは実行される
assert_blocked "$(printf 'rm -rf /tmp/x && cat <<%sEOF%s\nsafe\nEOF\n' "'" "'")"

it "ヒアドキュメントの後ろに続くコマンドは検査する"
assert_blocked "$(printf 'cat > doc.md <<%sEOF%s\nsafe text\nEOF\nrm -rf /tmp/x\n' "'" "'")"

it "終端していないヒアドキュメントは本文を外さない"
# 落とした部分に危険コマンドが隠れる余地を作らない
assert_blocked "$(printf 'cat <<%sEOF%s\nrm -rf /tmp/x\n' "'" "'")"

it "別言語に渡すヒアドキュメントの本文（python）"
# print("rm -rf x") はシェルコマンドではない。シェル系パターンの走査からは外す
assert_allowed "$(printf 'python3 - <<%sPY%s\nprint("rm -rf /tmp/x")\nPY\n' "'" "'")"

it "シェルに渡すヒアドキュメントの本文は走査する（sh）"
assert_blocked "$(printf 'sh <<%sEOF%s\nrm -rf /tmp/x\nEOF\n' "'" "'")"

it "シェルに渡すヒアドキュメントの本文は走査する（bash）"
assert_blocked "$(printf 'bash <<%sEOF%s\nrm -rf /tmp/x\nEOF\n' "'" "'")"

it "判定できない消費側は安全側に寄せる（SQL は走査対象に残る）"
assert_blocked "$(printf 'mysql app <<%sSQL%s\nTRUNCATE logs;\nSQL\n' "'" "'")"

it "シングルクォート文字列の中に出てくるだけ"
assert_allowed "git commit -m 'docs: rm -rf を使うなと書いた'"

it "展開の無いダブルクォート文字列の中に出てくるだけ"
assert_allowed 'git commit -m "docs: rm -rf を使うなと書いた"'

it "シングルクォートの中の SQL"
assert_allowed "echo 'DROP TABLE は禁止' > note.md"

it "コミットメッセージで危険コマンドに言及できる"
# git commit -F - の本文は文章であってコードではない
assert_allowed "$(printf 'git commit -F - <<%sMSG%s\nfix: rm -rf の誤爆を直した\nMSG\n' "'" "'")"

it "コミットメッセージで SQL に言及できる"
assert_allowed "$(printf 'git commit -F - <<%sMSG%s\npsql -c "DROP TABLE x" を例として説明した\nMSG\n' "'" "'")"

it "Issue 本文で危険コマンドに言及できる"
assert_allowed "$(printf 'gh issue create --body-file - <<%sEOT%s\n禁止: rm -rf /\nEOT\n' "'" "'")"

it "通常の削除は通る"
assert_allowed 'rm file.txt'

it "再帰なしの強制削除は通る"
assert_allowed 'rm -f file.txt'

it "通常の push は通る"
assert_allowed 'git push origin main'

it "通常の commit は通る"
assert_allowed 'git commit -m "feat: add search"'

it "テストの実行は通る"
assert_allowed 'bash tests/run.sh'

# ══════════════════════════════════════════════
suite "pre-tool-guard: 入力の異常系"
# ══════════════════════════════════════════════

it "空のコマンドは通す"
assert_allowed ''

it "コマンドを含まない JSON でも落ちない"
assert_ok bash -c "printf '%s' '{\"tool_name\":\"Read\"}' | bash '$GUARD'"

it "壊れた JSON でも落ちない"
assert_ok bash -c "printf '%s' 'not json' | bash '$GUARD' 2>/dev/null"

# ══════════════════════════════════════════════
suite "pre-tool-guard: Codex 版も同じ振る舞いをする"
# ══════════════════════════════════════════════

it "Codex 版もヒアドキュメント本文で誤爆しない"
assert_allowed "$(printf 'cat > doc.md <<%sEOF%s\n危険な操作の例: rm -rf /\nEOF\n' "'" "'")" "$CODEX_GUARD"

it "Codex 版も実際の削除はブロックする"
assert_blocked 'rm -rf /tmp/x' "$CODEX_GUARD"

it "Codex 版も find -exec をブロックする"
assert_blocked 'find . -exec rm -rf {} \;' "$CODEX_GUARD"

it "Codex 版は sudo をブロックする"
assert_blocked 'sudo apt-get install foo' "$CODEX_GUARD"

it "Codex 版は --no-verify をブロックする"
assert_blocked 'git commit --no-verify -m x' "$CODEX_GUARD"

it "Codex 版もシングルクォート内の言及は通す"
assert_allowed "git commit -m 'docs: sudo は使うなと書いた'" "$CODEX_GUARD"

it "Codex 版も別言語のヒアドキュメント本文は通す"
assert_allowed "$(printf 'python3 - <<%sPY%s\nprint("rm -rf /tmp/x")\nPY\n' "'" "'")" "$CODEX_GUARD"

it "Codex 版もシェルに渡すヒアドキュメントはブロックする"
assert_blocked "$(printf 'sh <<%sEOF%s\nrm -rf /tmp/x\nEOF\n' "'" "'")" "$CODEX_GUARD"

it "Codex 版も DB に流し込む SQL はブロックする"
assert_blocked "$(printf 'psql -d app <<%sSQL%s\nDROP TABLE users;\nSQL\n' "'" "'")" "$CODEX_GUARD"

it "両版の検知結果が一致する"
# 片方だけ緩い／厳しい状態を作らない
mismatch=""
for c in 'rm -rf /tmp/x' 'git push --force' 'rm file.txt' 'git push origin main'; do
  if guard "$c" "$GUARD"; then a=allow; else a=block; fi
  if guard "$c" "$CODEX_GUARD"; then b=allow; else b=block; fi
  [ "$a" = "$b" ] || mismatch="$mismatch [$c: claude=$a codex=$b]"
done
assert_eq "$mismatch" ""

report
