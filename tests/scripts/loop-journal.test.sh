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
