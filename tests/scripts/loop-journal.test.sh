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
