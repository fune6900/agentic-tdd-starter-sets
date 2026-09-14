#!/usr/bin/env bash
# loop-journal.sh のテスト
#
# 重点は「記録を失わないこと」と「ジャーナル以外のファイルを触らないこと」。
# 正常系よりも異常系を厚くする。PR #4 の独立レビューで発覚した traversal は回帰テストとして固定する。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

trap cleanup_sandboxes EXIT

# ══════════════════════════════════════════════
suite "loop-journal: 接続と初期化"
# ══════════════════════════════════════════════

new_sandbox

it "init が Vault にプロジェクトファイルを作る"
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
assert_file "$SANDBOX_VAULT/projects/proj.md"

it "init がエントリマーカーを書き込む"
assert_file_contains "$SANDBOX_VAULT/projects/proj.md" "<!-- LOOP-JOURNAL:ENTRIES -->"

it "init が Vault パスのポインタを保存する"
assert_file "$SANDBOX_JOURNAL/.vault"

it "init は既存のプロジェクトファイルを上書きしない"
printf '\n## 手で書いた記録\n' >> "$SANDBOX_VAULT/projects/proj.md"
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
assert_file_contains "$SANDBOX_VAULT/projects/proj.md" "手で書いた記録"

it "存在しない Vault パスは拒否される"
assert_fails journal init "$SANDBOX_ROOT/no-such-vault"

# ══════════════════════════════════════════════
suite "loop-journal: 記録の書き込み"
# ══════════════════════════════════════════════

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1

it "start が内部ジャーナルを作る"
journal start article-search "記事検索" >/dev/null 2>&1
assert_file "$SANDBOX_JOURNAL/article-search.md"

it "inner が内部ジャーナルに追記する"
echo "- **やったこと**: 着手" | journal inner 42 start >/dev/null 2>&1
assert_file_contains "$SANDBOX_JOURNAL/article-search.md" "#42 / start"

it "inner は Vault には書かない"
assert_file_not_contains "$SANDBOX_VAULT/projects/proj.md" "#42 / start"

it "outer は Vault に直接書く"
echo "- 分解した" | journal outer plan >/dev/null 2>&1
assert_file_contains "$SANDBOX_VAULT/projects/proj.md" "epic: article-search / plan"

it "本文が空の inner は拒否される"
assert_fails eval 'printf "" | journal inner 42 impl'

it "未定義の phase は拒否される"
assert_fails eval 'echo body | journal inner 42 bogus'

it "未定義の outer phase は拒否される"
assert_fails eval 'echo body | journal outer bogus'

it "Issue 番号の先頭の # は落とされる"
echo "- x" | journal inner "#43" impl >/dev/null 2>&1
assert_file_contains "$SANDBOX_JOURNAL/article-search.md" "#43 / impl"

# ══════════════════════════════════════════════
suite "loop-journal: 読み取り先の判定"
# ══════════════════════════════════════════════

it "エピック進行中なら内部ジャーナルを読む"
run journal context
assert_contains "$LAST_OUTPUT" "読み取り元: プロジェクト内部ジャーナル"

it "内部ジャーナルが無ければ Vault を読む"
new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
run journal context
assert_contains "$LAST_OUTPUT" "読み取り元: 外部 Obsidian Vault"

it "Vault 未接続かつジャーナル無しなら記録なしと言う"
new_sandbox
run journal context
assert_contains "$LAST_OUTPUT" "記録なし"

# ══════════════════════════════════════════════
suite "loop-journal: flush（外部記憶への書き写し）"
# ══════════════════════════════════════════════

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
journal start ep1 >/dev/null 2>&1
echo "- **やったこと**: 実装した" | journal inner 1 impl >/dev/null 2>&1

it "flush が Vault に完了見出しを書く"
echo "- **結果**: 完了" | journal flush >/dev/null 2>&1
assert_file_contains "$SANDBOX_VAULT/projects/proj.md" "epic: ep1 / complete"

it "flush がインナーの経緯を Vault へ書き写す"
assert_file_contains "$SANDBOX_VAULT/projects/proj.md" "実装した"

it "flush が書き写した見出しを1段下げる"
assert_file_contains "$SANDBOX_VAULT/projects/proj.md" "#### "

it "flush が内部ジャーナルを削除する"
assert_no_file "$SANDBOX_JOURNAL/ep1.md"

# ══════════════════════════════════════════════
suite "loop-journal: 記録を失わないこと（最重要）"
# ══════════════════════════════════════════════

new_sandbox
journal start orphan >/dev/null 2>&1   # Vault 未接続のまま
echo "- **やったこと**: 消えては困る記録" | journal inner 1 impl >/dev/null 2>&1

it "Vault 未接続の flush は失敗する"
assert_fails eval 'echo summary | journal flush'

it "Vault 未接続で flush しても内部ジャーナルは残る"
assert_file "$SANDBOX_JOURNAL/orphan.md"

it "内部ジャーナルの中身も失われていない"
assert_file_contains "$SANDBOX_JOURNAL/orphan.md" "消えては困る記録"

it "Vault 未接続の outer は内部ジャーナルへ退避する"
echo "- 退避される記録" | journal outer plan >/dev/null 2>&1
assert_file_contains "$SANDBOX_JOURNAL/orphan.md" "退避される記録"

it "Vault が書き込み不能なら flush は失敗する"
new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
journal start locked >/dev/null 2>&1
echo "- 記録" | journal inner 1 impl >/dev/null 2>&1
chmod 444 "$SANDBOX_VAULT/projects/proj.md"
assert_fails eval 'echo summary | journal flush'

it "書き込み不能でも内部ジャーナルは残る"
assert_file "$SANDBOX_JOURNAL/locked.md"
chmod 644 "$SANDBOX_VAULT/projects/proj.md"

# ══════════════════════════════════════════════
suite "loop-journal: slug の入力検証（PR #4 の回帰テスト）"
# ══════════════════════════════════════════════
# 独立レビューで、'../' を含む slug によりジャーナル外の任意ファイルへ
# 追記・削除できることが再現された。二度と通さない。

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
printf 'これは消えても書き換えられてもいけない\n' > "$SANDBOX_PROJ/VICTIM.md"

it "'../' を含む slug の start は拒否される"
assert_fails journal start "../../../VICTIM"

it "traversal を試みても外部ファイルは書き換わらない"
assert_file_contains "$SANDBOX_PROJ/VICTIM.md" "これは消えても書き換えられてもいけない"

it "'../' を含む slug の inner は拒否される（環境変数経由）"
assert_fails eval 'echo body | LOOP_EPIC="../../../VICTIM" journal inner 99 start'

it "'../' を含む slug の flush は拒否される"
assert_fails eval 'echo summary | journal flush "../../../VICTIM"'

it "traversal を試みても外部ファイルは削除されない"
assert_file "$SANDBOX_PROJ/VICTIM.md"

it "スラッシュを含む slug は拒否される"
assert_fails journal start "sub/evil"

it "ドットで始まる slug は拒否される"
assert_fails journal start ".hidden"

it "空の slug は拒否される"
assert_fails journal start ""

it "LOOP_PROJECT_NAME の traversal は拒否される"
assert_fails eval 'LOOP_PROJECT_NAME="../escaped" journal init "$SANDBOX_VAULT"'

it "Vault の projects 外にファイルが作られていない"
assert_no_file "$SANDBOX_VAULT/escaped.md"

it "正当な slug は通る"
assert_ok journal start valid-slug-1.0

# ══════════════════════════════════════════════
suite "loop-journal: 記録への注入を防ぐ"
# ══════════════════════════════════════════════
# ジャーナルは次のセッションが読む記憶であり、flush で Vault へ永続化される。
# 偽の見出しを注入できると、記憶そのものを汚染できる。

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
journal start inject-probe >/dev/null 2>&1

it "改行を含む Issue 識別子は拒否される"
assert_fails eval 'echo body | journal inner "$(printf "1\n## 偽の見出し")" impl'

it "偽の見出しがジャーナルに入っていない"
assert_file_not_contains "$SANDBOX_JOURNAL/inject-probe.md" "偽の見出し"

it "空白を含む Issue 識別子は拒否される"
assert_fails eval 'echo body | journal inner "1 2" impl'

it "スラッシュを含む Issue 識別子は拒否される"
assert_fails eval 'echo body | journal inner "../evil" impl'

it "先頭の # は表記ゆれとして受け入れる"
assert_ok eval 'echo body | journal inner "#42" impl'

it "題名の改行は1行に潰される"
echo body | journal inner 43 impl "$(printf '題名\n## 偽の見出し')" >/dev/null 2>&1
# 改行が残っていれば "## 偽の見出し" が行頭に来て偽エントリになる。1行に潰れていること
assert_file_contains "$SANDBOX_JOURNAL/inject-probe.md" "題名 ## 偽の見出し"

it "見出しの数がエントリ数と一致する"
# start / #42 / #43 の3エントリ。注入があれば増える
assert_eq "$(grep -c '^## ' "$SANDBOX_JOURNAL/inject-probe.md")" "2"

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1

it "題名の引用符で frontmatter を壊さない"
journal start quoted "$(printf 'evil"\ninjected: true')" >/dev/null 2>&1
assert_ok python3 -c "
import sys,re
t=open(sys.argv[1],encoding='utf-8').read().split('---')[1]
assert t.count(chr(34)) % 2 == 0, 'frontmatter の引用符が閉じていない'
assert 'injected: true' not in t.split(chr(10))[0], '別の行が注入された'
" "$SANDBOX_JOURNAL/quoted.md"

it "複数行の slug は拒否される"
# grep は行単位で判定するため、1行目が正当なら通っていた（回帰テスト）
assert_fails journal start "$(printf 'ok\nevil')"

it "拒否された slug のファイルは作られていない"
assert_no_file "$SANDBOX_JOURNAL/ok.md"

it "LOOP_CONTEXT_EPICS が非数値でも既定で動く"
new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
# 内部ジャーナルを作らない＝ Vault を読む経路に入る
run env LOOP_CONTEXT_EPICS=abc bash "$SANDBOX_PROJ/.claude/scripts/loop-journal.sh" context
assert_contains "$LAST_OUTPUT" "直近 2 エピック分"

# ══════════════════════════════════════════════
suite "loop-journal: シンボリックリンクを追わない（G5 の回帰テスト）"
# ══════════════════════════════════════════════
# journal/*.md は Git 管理下（コミット対象）なので、悪意ある PR にリンクを1本混ぜられる。
# CLAUDE.md が「新しいタスクの最初の行動」と定める context が、
# そのまま秘密ファイルの読み出し装置に化ける。

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
printf 'SECRET_TOKEN=漏れてはいけない値\n' > "$SANDBOX_ROOT/secret.env"
mkdir -p "$SANDBOX_JOURNAL"
ln -s "$SANDBOX_ROOT/secret.env" "$SANDBOX_JOURNAL/leak.md"

it "リンクされたジャーナルの読み出しは拒否される"
assert_fails journal context leak

it "リンク先の中身がコンテキストへ出力されない"
run journal context leak
case "$LAST_OUTPUT" in
  *SECRET_TOKEN*) fail "リンク先の内容が出力された" ;;
  *) pass ;;
esac

it "リンクされたジャーナルへの追記は拒否される"
assert_fails eval 'echo body | LOOP_EPIC=leak journal inner 1 impl'

it "リンク先が書き換わっていない"
assert_file_not_contains "$SANDBOX_ROOT/secret.env" "body"

it "リンクされたジャーナルの flush は拒否される"
assert_fails eval 'echo summary | journal flush leak'

it "flush で外部ファイルが削除されない"
assert_file "$SANDBOX_ROOT/secret.env"

it "ジャーナルディレクトリ自体がリンクなら拒否される"
new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
mkdir -p "$SANDBOX_ROOT/elsewhere"
find "$SANDBOX_JOURNAL" -depth -delete 2>/dev/null
ln -s "$SANDBOX_ROOT/elsewhere" "$SANDBOX_JOURNAL"
assert_fails journal start linked-dir

# ══════════════════════════════════════════════
suite "loop-journal: 秘密情報を外へ出さない"
# ══════════════════════════════════════════════
# Vault はリポジトリ外＝.gitignore も権限設定も届かず、多くの場合クラウド同期される。
# 追記専用なので、一度書くと同期先の履歴から消せない。

new_sandbox
( cd "$SANDBOX_PROJ" && git remote add origin \
    "https://oauth2:ghp_FAKETOKENVALUE123@github.com/acme/private.git" ) 2>/dev/null
journal init "$SANDBOX_VAULT" >/dev/null 2>&1

it "リモート URL の認証情報を Vault に書かない"
assert_file_not_contains "$SANDBOX_VAULT/projects/proj.md" "ghp_FAKETOKENVALUE123"

it "認証情報を除いた URL は残す"
assert_file_contains "$SANDBOX_VAULT/projects/proj.md" "https://github.com/acme/private.git"

it "プロジェクト名の改行は拒否される"
# 通すと Vault の frontmatter に任意のキーを注入できる
assert_fails eval 'LOOP_PROJECT_NAME="$(printf "a\ninjected: true")" journal init "$SANDBOX_VAULT"'

it "相対パスの Vault ポインタは無視される"
new_sandbox
mkdir -p "$SANDBOX_JOURNAL"
printf 'relative/path\n' > "$SANDBOX_JOURNAL/.vault"
run journal where
assert_contains "$LAST_OUTPUT" "(未接続)"

# ══════════════════════════════════════════════
suite "loop-journal: 他プロジェクトから持ち込まれた Vault ポインタを拒む"
# ══════════════════════════════════════════════
# .vault は .gitignore 済みだが、作業ツリーごと cp でコピーすると付いてくる。
# 「手元のチェックアウトから .claude/ を直接コピーする」は現実によくやる手順で、
# そのとき別プロジェクトの記録が元の持ち主の Vault へ流れ込む。

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1

it "init はポインタにプロジェクト名を書く"
assert_file_contains "$SANDBOX_JOURNAL/.vault" "proj"

it "ポインタの1行目は Vault のパスのまま"
assert_eq "$(sed -n '1p' "$SANDBOX_JOURNAL/.vault")" "$SANDBOX_VAULT"

# 実際に別リポジトリへ .claude/ を丸ごとコピーして再現する。
# 環境変数で名前を変えるだけの擬似再現では、上書き可能な値を使った紐付けの
# 弱さ（.project ごとコピーされると照合が無意味になる）を検出できない。
copied="$SANDBOX_ROOT/copied-project"
mkdir -p "$copied"
cp -r "$SANDBOX_PROJ/.claude" "$copied/"
( cd "$copied" && git init -q ) 2>/dev/null
copied_journal() {
  CLAUDE_PROJECT_DIR="$copied" bash "$copied/.claude/scripts/loop-journal.sh" "$@"
}

it "コピー先ではポインタが引き継がれている"
assert_file "$copied/.claude/memory/journal/.vault"

it "別プロジェクトのポインタは使わない"
run copied_journal where
assert_contains "$LAST_OUTPUT" "(未接続)"

it "拒否した理由を報告する"
run copied_journal where
assert_contains "$LAST_OUTPUT" "別のプロジェクトのものだ"

it "別プロジェクトの記録が元の Vault に作られない"
copied_journal start borrowed >/dev/null 2>&1
printf -- '- x\n' | copied_journal outer plan >/dev/null 2>&1
assert_no_file "$SANDBOX_VAULT/projects/copied-project.md"

it "元の Vault ファイルにも書き込まれていない"
assert_file_not_contains "$SANDBOX_VAULT/projects/proj.md" "borrowed"

it "元のプロジェクトからは今まで通り使える"
run journal where
assert_contains "$LAST_OUTPUT" "$SANDBOX_VAULT"

# ── 紐付けは上書き可能な値であってはならない ──
# .project も LOOP_PROJECT_NAME も Vault のファイル名を決める上書き手段で、
# .project は .vault と同じ経路でコピーされる。これで照合を抜けられては意味が無い。

it ".project を一緒にコピーされても照合を抜けられない"
printf '%s\n' "proj" > "$SANDBOX_PROJ/.claude/memory/journal/.project"
cp "$SANDBOX_PROJ/.claude/memory/journal/.project" "$copied/.claude/memory/journal/.project"
run copied_journal where
assert_contains "$LAST_OUTPUT" "(未接続)"

it ".project 経由でも元の Vault に書き込めない"
copied_journal start sneak >/dev/null 2>&1
printf -- '- 侵入\n' | copied_journal outer plan >/dev/null 2>&1
assert_file_not_contains "$SANDBOX_VAULT/projects/proj.md" "侵入"

it "LOOP_PROJECT_NAME で名乗り直しても抜けられない"
run env LOOP_PROJECT_NAME=proj CLAUDE_PROJECT_DIR="$copied" \
  bash "$copied/.claude/scripts/loop-journal.sh" where
assert_contains "$LAST_OUTPUT" "(未接続)"

it "表示名の上書きは Vault のファイル名には効く（本来の用途）"
run journal where
assert_contains "$LAST_OUTPUT" "projects/proj.md"

it "ポインタの中身は制御文字を落としてから表示する"
printf '%s\n\033[31minjected\n' "$SANDBOX_VAULT" > "$copied/.claude/memory/journal/.vault"
run copied_journal where
case "$LAST_OUTPUT" in
  *$'\033'*) fail "制御文字がそのまま出力された" ;;
  *) pass ;;
esac

it "プロジェクト名の無い古い形式のポインタも使わない"
new_sandbox
mkdir -p "$SANDBOX_JOURNAL"
printf '%s\n' "$SANDBOX_VAULT" > "$SANDBOX_JOURNAL/.vault"
run journal where
assert_contains "$LAST_OUTPUT" "(未接続)"

it "古い形式でも繋ぎ直せば使える"
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
run journal where
assert_contains "$LAST_OUTPUT" "$SANDBOX_VAULT"

it "LOOP_VAULT_DIR は明示指定なので常に優先される"
new_sandbox
run env LOOP_VAULT_DIR="$SANDBOX_VAULT" \
  bash "$SANDBOX_PROJ/.claude/scripts/loop-journal.sh" where
assert_contains "$LAST_OUTPUT" "$SANDBOX_VAULT"

# ══════════════════════════════════════════════
suite "loop-journal: ポインタ自身もリンクを追わない（G5 の回帰テスト）"
# ══════════════════════════════════════════════
# journal/*.md に掛けたリンク検査と同じ脅威が .vault / .project / .active にも成立する。
# .gitignore 済みでも git add -f で追跡でき、mode 120000 として clone 後に復元される。

new_sandbox
printf 'https://alice:ghp_FAKETOKEN123@example.com\n' > "$SANDBOX_ROOT/creds"
mkdir -p "$SANDBOX_JOURNAL"
ln -s "$SANDBOX_ROOT/creds" "$SANDBOX_JOURNAL/.vault"

it ".vault がリンクなら中身を読まない"
run journal where
case "$LAST_OUTPUT" in
  *ghp_FAKETOKEN123*) fail "リンク先の秘密が出力された" ;;
  *) pass ;;
esac

it "リンクを検出したことを報告する"
run journal where
assert_contains "$LAST_OUTPUT" "シンボリックリンク"

rm -f "$SANDBOX_JOURNAL/.vault"
ln -s "$SANDBOX_ROOT/creds" "$SANDBOX_JOURNAL/.project"

it ".project がリンクなら中身を読まない"
run journal where
case "$LAST_OUTPUT" in
  *ghp_FAKETOKEN123*) fail "リンク先の秘密が出力された" ;;
  *) pass ;;
esac

rm -f "$SANDBOX_JOURNAL/.project"
ln -s "$SANDBOX_ROOT/creds" "$SANDBOX_JOURNAL/.active"

it ".active がリンクなら中身を読まない"
run journal status
case "$LAST_OUTPUT" in
  *ghp_FAKETOKEN123*) fail "リンク先の秘密が出力された" ;;
  *) pass ;;
esac
rm -f "$SANDBOX_JOURNAL/.active"

# ══════════════════════════════════════════════
suite "loop-journal: リンクされたポインタへ書き込まない（G5 再判定の回帰テスト）"
# ══════════════════════════════════════════════
# read_pointer は読みしか守っていなかった。書き込みは生のリダイレクトで
# リンクを追い、cmd_init はリンクを検知して警告を出した直後に書いていた。
# .active は追跡可能な通常ファイルとして PR で配送でき、.gitignore は効かない。

new_sandbox
printf 'export AWS_PROFILE=prod\nsource ~/work/env.sh\n' > "$SANDBOX_ROOT/victim-rc"
mkdir -p "$SANDBOX_JOURNAL"
ln -s "$SANDBOX_ROOT/victim-rc" "$SANDBOX_JOURNAL/.active"

it "リンクされた .active へ書き込まない"
journal start my-epic >/dev/null 2>&1
assert_file_contains "$SANDBOX_ROOT/victim-rc" "export AWS_PROFILE=prod"

it "リンク先が切り詰められていない"
assert_eq "$(wc -l < "$SANDBOX_ROOT/victim-rc" | tr -d ' ')" "2"

it "書き込みを拒否した理由を報告する"
rm -f "$SANDBOX_JOURNAL/.active"
ln -s "$SANDBOX_ROOT/victim-rc" "$SANDBOX_JOURNAL/.active"
run journal start other-epic
assert_contains "$LAST_OUTPUT" "リンク先には書かない"
rm -f "$SANDBOX_JOURNAL/.active"

new_sandbox
printf 'original\n' > "$SANDBOX_ROOT/victim2"
mkdir -p "$SANDBOX_JOURNAL"
ln -s "$SANDBOX_ROOT/victim2" "$SANDBOX_JOURNAL/.vault"

it "リンクされた .vault へ init が書き込まない"
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
assert_file_contains "$SANDBOX_ROOT/victim2" "original"

it "ジャーナル外へのポインタ書き込みを拒否する"
rm -f "$SANDBOX_JOURNAL/.vault"
assert_fails bash -c "
  . '$REPO_ROOT/tests/scripts/lib.sh' 2>/dev/null
  JOURNAL_DIR='$SANDBOX_JOURNAL'
  . /dev/stdin <<'FN'
$(sed -n '/^write_pointer()/,/^}/p' "$REPO_ROOT/.claude/scripts/loop-journal.sh")
FN
  write_pointer '$SANDBOX_ROOT/outside.txt' x
"

# ══════════════════════════════════════════════
suite "loop-journal: 制御文字を含むポインタは採用しない"
# ══════════════════════════════════════════════
# .active は通常ファイルなのでリンク検査では止まらない。
# /loop-status は常用コマンドで、出力はそのままコンテキストに入る。

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
printf 'evil\033[31mINJECTED\n' > "$SANDBOX_JOURNAL/.active"
run journal where

it "ANSI エスケープが出力に残らない"
case "$LAST_OUTPUT" in
  *$'\033'*) fail "ESC が出力された" ;;
  *) pass ;;
esac

it "制御文字を含む値を採用しない"
case "$LAST_OUTPUT" in
  *INJECTED*) fail "注入された値が採用された" ;;
  *) pass ;;
esac

it "双方向制御文字を落とす"
rm -f "$SANDBOX_JOURNAL/.active"
printf '%s\n' "$(printf 'A\342\200\256B')" > "$SANDBOX_JOURNAL/.project"
run journal where
case "$LAST_OUTPUT" in
  *$'\342\200\256'*) fail "RLO が出力された" ;;
  *) pass ;;
esac
rm -f "$SANDBOX_JOURNAL/.project"

# ══════════════════════════════════════════════
suite "loop-journal: 細工した .git で同一性を偽装できない"
# ══════════════════════════════════════════════
# 「検査対象が見つからなければ検査しない」はフェイルオープンだった。
# gitdir: /被害者/repo/.git と書いた .git ファイル1本で素通りできた。

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
( cd "$SANDBOX_PROJ" && git -c user.email=t@e.com -c user.name=t \
    commit -q --allow-empty -m init ) 2>/dev/null
mkdir -p "$SANDBOX_ROOT/fake"
cp -r "$SANDBOX_PROJ/.claude" "$SANDBOX_ROOT/fake/"
printf 'gitdir: %s/.git\n' "$SANDBOX_PROJ" > "$SANDBOX_ROOT/fake/.git"

it "手書きの .git ファイルでは接続できない"
run env CLAUDE_PROJECT_DIR="$SANDBOX_ROOT/fake" \
  bash "$SANDBOX_ROOT/fake/.claude/scripts/loop-journal.sh" where
assert_contains "$LAST_OUTPUT" "(未接続)"

it "偽装からの記録が元の Vault に混入しない"
CLAUDE_PROJECT_DIR="$SANDBOX_ROOT/fake" \
  bash "$SANDBOX_ROOT/fake/.claude/scripts/loop-journal.sh" start sneak >/dev/null 2>&1
printf -- '- 侵入\n' | CLAUDE_PROJECT_DIR="$SANDBOX_ROOT/fake" \
  bash "$SANDBOX_ROOT/fake/.claude/scripts/loop-journal.sh" outer plan >/dev/null 2>&1
assert_file_not_contains "$SANDBOX_VAULT/projects/proj.md" "侵入"

# ══════════════════════════════════════════════
suite "loop-journal: ポインタの中身を報告に載せない"
# ══════════════════════════════════════════════
# 2行目だけサニタイズして1行目を素通りさせていた。境界を越える全ての値に同じ処理を通す。

new_sandbox
mkdir -p "$SANDBOX_JOURNAL"
printf 'relative\033[31m%s\nx\n' "$(python3 -c 'print("Y"*200)')" > "$SANDBOX_JOURNAL/.vault"
run journal where

it "1行目の制御文字を落とす"
case "$LAST_OUTPUT" in
  *$'\033'*) fail "ESC がそのまま出力された" ;;
  *) pass ;;
esac

it "1行目を切り詰める"
longest="$(printf '%s' "$LAST_OUTPUT" | grep -o 'Y*' | awk '{print length}' | sort -rn | head -1)"
if [ "${longest:-0}" -le 40 ]; then pass; else fail "Y が ${longest} 文字通過した"; fi

# ══════════════════════════════════════════════
suite "loop-journal: worktree ごとコピーされても抜けられない"
# ══════════════════════════════════════════════
# worktree の .git は**ファイル**（gitdir ポインタ）で cp -r で付いてくる。
# --git-common-dir は「どのリポジトリか」には答えるが
# 「このディレクトリはそのリポジトリの一部か」には答えない。

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
( cd "$SANDBOX_PROJ" && git -c user.email=t@e.com -c user.name=t \
    commit -q --allow-empty -m init ) 2>/dev/null
git -C "$SANDBOX_PROJ" worktree add -q "$SANDBOX_ROOT/wt" -b feat/wt-x 2>/dev/null
mkdir -p "$SANDBOX_ROOT/wt/.claude"
cp -r "$SANDBOX_PROJ/.claude/scripts" "$SANDBOX_PROJ/.claude/memory" "$SANDBOX_ROOT/wt/.claude/"
wt_journal() { CLAUDE_PROJECT_DIR="$SANDBOX_ROOT/wt" \
  bash "$SANDBOX_ROOT/wt/.claude/scripts/loop-journal.sh" "$@"; }

it "正規の worktree からは接続できる"
run wt_journal where
assert_contains "$LAST_OUTPUT" "$SANDBOX_VAULT"

cp -r "$SANDBOX_ROOT/wt" "$SANDBOX_ROOT/stolen"
stolen_journal() { CLAUDE_PROJECT_DIR="$SANDBOX_ROOT/stolen" \
  bash "$SANDBOX_ROOT/stolen/.claude/scripts/loop-journal.sh" "$@"; }

it "worktree ごとコピーされた先からは接続できない"
run stolen_journal where
assert_contains "$LAST_OUTPUT" "(未接続)"

it "コピー先の記録が元の Vault に混入しない"
stolen_journal start sneak >/dev/null 2>&1
printf -- '- 侵入\n' | stolen_journal outer plan >/dev/null 2>&1
assert_file_not_contains "$SANDBOX_VAULT/projects/proj.md" "侵入"

# ══════════════════════════════════════════════
suite "loop-journal: 同名の別ディレクトリでも抜けられない"
# ══════════════════════════════════════════════
# リポジトリ名だけの一致で紐付けると、同名の場所へコピーされた時点で素通りする。
# 同一性には共通 .git の実パスを使う。

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1
mkdir -p "$SANDBOX_ROOT/elsewhere/proj"
cp -r "$SANDBOX_PROJ/.claude" "$SANDBOX_ROOT/elsewhere/proj/"

it "同名のディレクトリへコピーしても接続できない"
run env CLAUDE_PROJECT_DIR="$SANDBOX_ROOT/elsewhere/proj" \
  bash "$SANDBOX_ROOT/elsewhere/proj/.claude/scripts/loop-journal.sh" where
assert_contains "$LAST_OUTPUT" "(未接続)"

it "古い形式のポインタは形式の違いとして報告する"
# 名前で紐付いた旧ポインタを「別プロジェクト」と言うと、同じ名前が並んで意味が通らない
new_sandbox
mkdir -p "$SANDBOX_JOURNAL"
printf '%s\nproj\n' "$SANDBOX_VAULT" > "$SANDBOX_JOURNAL/.vault"
run journal where
assert_contains "$LAST_OUTPUT" "古い形式"

# ══════════════════════════════════════════════
suite "loop-journal: worktree でも同じプロジェクトとして扱う"
# ══════════════════════════════════════════════
# PROJECT_DIR の basename をそのまま使うと、worktree ではブランチ名になり、
# Vault の記録がブランチごとに散る。共通の .git を辿って本体名を得る。

new_sandbox
( cd "$SANDBOX_PROJ" && git -c user.email=t@e.com -c user.name=t \
    commit -q --allow-empty -m init ) 2>/dev/null
git -C "$SANDBOX_PROJ" worktree add -q "$SANDBOX_ROOT/wt-feat-99" -b feat/99-x 2>/dev/null
mkdir -p "$SANDBOX_ROOT/wt-feat-99/.claude/scripts"
cp "$SANDBOX_PROJ/.claude/scripts/loop-journal.sh" "$SANDBOX_ROOT/wt-feat-99/.claude/scripts/"

it "worktree でも本体と同じプロジェクト名になる"
main_name="$(journal where | sed -n 's/^プロジェクト名 *: *//p')"
wt_name="$(CLAUDE_PROJECT_DIR="$SANDBOX_ROOT/wt-feat-99" \
  bash "$SANDBOX_ROOT/wt-feat-99/.claude/scripts/loop-journal.sh" where \
  | sed -n 's/^プロジェクト名 *: *//p')"
assert_eq "$wt_name" "$main_name"

# ══════════════════════════════════════════════
suite "loop-journal: ブランチ名からの slug 導出"
# ══════════════════════════════════════════════

new_sandbox
journal init "$SANDBOX_VAULT" >/dev/null 2>&1

it "ネストしたブランチ名はスラッシュが '-' に潰される"
( cd "$SANDBOX_PROJ" && git symbolic-ref HEAD refs/heads/epic/search/filter )
run journal where
assert_contains "$LAST_OUTPUT" "search-filter"

it "epic/ 以外のブランチでは slug を特定しない"
( cd "$SANDBOX_PROJ" && git symbolic-ref HEAD refs/heads/feat/12-something )
run journal where
assert_contains "$LAST_OUTPUT" "(未特定)"

report
