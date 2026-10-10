#!/usr/bin/env bash
# bootstrap-monitor.sh のテスト（Issue #24）
#
# 導入先に監視用 compose（compose.monitor.yml と、候補が無ければ include だけの compose.yaml）を
# 生成するスクリプト。SessionStart から無確認で自動実行されるため、重点は2つ。
#   1. 人のリポジトリを壊さない（既存候補は直下も祖先も不変・リンクは書かない・冪等）
#   2. 生成物が導入先で実際に動く（docker compose config の build context が実体を指す）
#
# 各テストは lessons #22 に従い「他を全部正しくして 1 項目だけ壊した入力」で書く。
#
# ── 変異対応表（防御を1つ外した隔離コピーでこのテストが FAIL すること。実施は実装後）──
#   防御                         外したときに FAIL するテスト名（接頭辞）
#   symlink: 生成先 compose.monitor.yml   [symlink/valid] compose.monitor.yml / [symlink/dangling] compose.monitor.yml
#   symlink: 生成先 compose.yaml          [symlink/valid] compose.yaml / [symlink/dangling] compose.yaml
#   symlink: 原本                         [symlink/valid] .claude/monitor/compose.monitor.yml / [symlink/dangling] 同
#   symlink: 候補（直下 6 名）             [symlink/valid] <候補名> / [symlink/dangling] <候補名>
#   symlink: 候補（祖先）                  [祖先symlink]
#   読み取りの O_NOFOLLOW                 [静的/読み取り] O_NOFOLLOW / [原本/競合/通常ファイルへのリンク]
#   読み取りの O_NONBLOCK                 [静的/読み取り] O_NONBLOCK / [原本/競合/FIFO]（ハング検出）
#   読み取りの O_NOCTTY                   [静的/読み取り] O_NOCTTY
#   サイズ上限 65536                      [静的/上限] / [原本/65537 バイト（上限超過）] / [原本/競合/65537 バイト]
#   fd 上の -f $fh                        [静的/fd 検査]（動的は [原本/競合/FIFO(書き手あり)] が補助。実装次第で検出できない）
#   書き込みの O_EXCL                     [静的/書き込み] O_EXCL / [書込競合/*/通常ファイル] / [書込競合/valid・dangling・devnull]
#   書き込みの O_NOFOLLOW                 [静的/書き込み] O_NOFOLLOW / [書込競合/valid・dangling・devnull]
#   書き込みの O_NONBLOCK                 [静的/書き込み] O_NONBLOCK のみ（O_EXCL が FIFO を先に弾くため動的には出ない）
#   名前で開き直す読み書き（cat・>）       [静的/名前で開かない]
#   env -u（PERL5OPT 等）                 [静的/env] / [perl] PERL5OPT / PERL5LIB ...
#   既存候補検出（直下）                   [直下候補]
#   既存候補検出（祖先）                   [祖先候補]
#   冪等判定                              [冪等]
#   生成条件                              [条件]
#   出力が固定文字列のみ                   [出力]
#   （noclobber は O_EXCL に置き換えた。通常ファイル以外を指すリンク（/dev/null 等）を拒めないため。より強い原子的な検査への置換）
#
# 決めたこと（Coder への契約の補足）:
#   - 直下に symlink の対象（生成先・原本・直下候補）があれば、何も書かずに WARN を出して exit 0
#     （compose.monitor.yml の生成も含めて一切書かない）
#   - 祖先の symlink 候補は「候補あり」として扱う: compose.yaml を作らない・リンク先を作らない
#     （compose.monitor.yml を作るかは問わない）
#   - 案内は「include」と「compose.monitor.yml」を両方含む行で出す
#   - 非 quiet では何もしない時も 1 行以上出す。--quiet は何もしなかった時だけ黙る
#   - 原本・生成先は名前で開かない。perl の sysopen で fd を 1 回だけ開く（読み取り: O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_NOCTTY、
#     fd 上で -f とサイズ確認、上限 64KB（65536）・sysread は上限 + 1 まで。書き込み: O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK|O_NOCTTY, 0644）
#   - sysopen のフラグは sysopen の文の中に直接書く（変数に逃がさない）。読み取りの fd 変数は $fh
#   - 競合は PATH 先頭の perl shim で再現する（cat shim は廃止）。スクリプトが最初に呼ぶ perl の直前に差し替える

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

trap cleanup_sandboxes EXIT

ORIG="$REPO_ROOT/.claude/monitor/compose.monitor.yml"
SCRIPT_SRC="$REPO_ROOT/.claude/scripts/bootstrap-monitor.sh"
CAND_NAMES="compose.yaml compose.yml docker-compose.yml docker-compose.yaml compose.override.yml compose.override.yaml docker-compose.override.yml docker-compose.override.yaml"
OLD_STAMP="202001010000"
P=""
RC=0

unset LOOP_BOOTSTRAP COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PATH_SEPARATOR LOOP_MONITOR_PORT

# ---------- ヘルパ ----------

bm() { bash "$P/.claude/scripts/bootstrap-monitor.sh" "$@"; }

# 実行して終了コードを RC に、出力を LAST_OUTPUT に入れる
runbm() {
  LAST_OUTPUT="$(bm "$@" 2>&1)"
  RC=$?
}

mtime_of() { perl -e 'my @s = lstat($ARGV[0]); print $s[9]' "$1"; }

# 通常ファイル 1 つのバイト内容と mtime
fsnap() { echo "$(cksum < "$1") $(mtime_of "$1")"; }

# ツリー全体（.git を除く）の名前・リンク先・内容・mtime
snap() {
  local root="$1" f
  find "$root" -path "$root/.git" -prune -o -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then
      echo "L $f -> $(readlink "$f")"
    elif [ -f "$f" ]; then
      echo "F $f $(fsnap "$f")"
    else
      echo "D $f"
    fi
  done
}

old() { touch -t "$OLD_STAMP" "$1"; }

# プロジェクトを用意する（package.json あり・スクリプトと原本をコピー）
mkproj() { # <dir>
  P="$1"
  mkdir -p "$P/.claude/scripts" "$P/.claude/monitor"
  [ -f "$SCRIPT_SRC" ] && cp "$SCRIPT_SRC" "$P/.claude/scripts/"
  cp "$ORIG" "$P/.claude/monitor/compose.monitor.yml"
  printf '{"name":"target-app"}\n' > "$P/package.json"
  export CLAUDE_PROJECT_DIR="$P"
}

fresh() { # 既定のサンドボックス（new_sandbox のコピー対象に依存する）
  new_sandbox
  P="$SANDBOX_PROJ"
  printf '{"name":"target-app"}\n' > "$P/package.json"
  export CLAUDE_PROJECT_DIR="$P"
}

# 候補ファイルを置く（中身は名前ごとに違う）
put_cand() { # <dir> <name>
  printf 'services:\n  app:\n    image: busybox # %s\n' "$2" > "$1/$2"
  old "$1/$2"
}

# ══════════════════════════════════════════════
suite "前提と静的検査"
# ══════════════════════════════════════════════

it "[前提] bootstrap-monitor.sh が存在する"
assert_file "$SCRIPT_SRC"

it "[前提] 原本 compose.monitor.yml が存在する"
assert_file "$ORIG"

# 契約（Issue #24 retry 3）: 原本・生成先は名前で開き直さず、perl の sysopen で fd を 1 回だけ開く。
# 判定対象はコメント行を除いたスクリプト本体。perl 部分も同じ（sysopen の文は ; までを 1 文とみなす）。
CODE_SRC="$( [ -f "$SCRIPT_SRC" ] && grep -v '^[[:space:]]*#' "$SCRIPT_SRC" )"
CODE_FLAT="$(printf '%s\n' "$CODE_SRC" | tr '\n' ' ')"
SYSOPENS="$(printf '%s' "$CODE_FLAT" | grep -o 'sysopen[^;]*;')"
READ_OPEN="$(printf '%s\n' "$SYSOPENS" | grep 'O_RDONLY')"
WRITE_OPEN="$(printf '%s\n' "$SYSOPENS" | grep 'O_WRONLY')"

it "[静的/名前で開かない] cat / cp / tee / dd / install で原本・生成先を開かない"
if [ -f "$SCRIPT_SRC" ] && ! printf '%s\n' "$CODE_SRC" | grep -Eq '(^|[^[:alnum:]_./-])(cat|cp|tee|dd|install)([^[:alnum:]_-]|$)'; then pass; else fail "名前で開く外部コマンドが残っている"; fi

it "[静的/名前で開かない] 変数へのリダイレクト書き込み（> / >> \"\$VAR\"）が無い"
if [ -f "$SCRIPT_SRC" ] && ! printf '%s\n' "$CODE_SRC" | grep -Eq '(^|[^<0-9&>])>>?[[:space:]]*("\$|\$\{?[A-Z_][A-Z0-9_]*)'; then pass; else fail "名前での書き込みが残っている"; fi

it "[静的/名前で開かない] 変数からのリダイレクト読み取り（< \"\$ORIG\" 等）が無い"
if [ -f "$SCRIPT_SRC" ] && ! printf '%s\n' "$CODE_SRC" | grep -Eq '(^|[^<0-9&])<[[:space:]]*("\$|\$\{?[A-Z_][A-Z0-9_]*)'; then pass; else fail "名前での読み取りが残っている"; fi

it "[静的/sysopen] sysopen の読み取り文（O_RDONLY）と書き込み文（O_WRONLY）がそれぞれある"
if [ -n "$READ_OPEN" ] && [ -n "$WRITE_OPEN" ]; then pass; else fail "読み取り=${READ_OPEN:+あり} 書き込み=${WRITE_OPEN:+あり}"; fi

it "[静的/sysopen] sysopen の文は読み取りか書き込みのどちらかで、フラグを変数に逃がしていない"
if [ -n "$SYSOPENS" ] && [ "$(printf '%s\n' "$SYSOPENS" | grep -c 'O_RDONLY\|O_WRONLY')" = "$(printf '%s\n' "$SYSOPENS" | grep -c .)" ]; then pass; else fail "$SYSOPENS"; fi

for fl in O_NOFOLLOW O_NONBLOCK O_NOCTTY; do
  it "[静的/読み取り] 読み取りの sysopen に $fl がある"
  if printf '%s' "$READ_OPEN" | grep -q "$fl"; then pass; else fail "読み取り文: ${READ_OPEN:-なし}"; fi
done

for fl in O_CREAT O_EXCL O_NOFOLLOW O_NONBLOCK O_NOCTTY; do
  it "[静的/書き込み] 書き込みの sysopen に $fl がある（O_EXCL は noclobber より強い原子的な「作る」）"
  if printf '%s' "$WRITE_OPEN" | grep -q "$fl"; then pass; else fail "書き込み文: ${WRITE_OPEN:-なし}"; fi
done

it "[静的/書き込み] 書き込みの sysopen の権限が 0644"
if printf '%s' "$WRITE_OPEN" | grep -Eq '0644'; then pass; else fail "書き込み文: ${WRITE_OPEN:-なし}"; fi

it "[静的/fd 検査] 開いた fd 上で通常ファイルか確認する (-f \$fh)"
if printf '%s' "$CODE_FLAT" | grep -Eq -e '-f[[:space:]]+\$fh'; then pass; else fail "-f \$fh が無い"; fi

it "[静的/fd 検査] fd 上の stat（stat(\$fh)）でサイズを見る"
if printf '%s' "$CODE_FLAT" | grep -Eq 'stat[[:space:]]*\(?[[:space:]]*\$fh'; then pass; else fail "stat(\$fh) が無い"; fi

it "[静的/上限] 上限 65536 バイトを持ち、sysread は上限 + 1 バイトまで"
if printf '%s' "$CODE_FLAT" | grep -q '65536' && printf '%s' "$CODE_FLAT" | grep -Eq 'sysread[^;]*\+[[:space:]]*1'; then pass; else fail "65536 または sysread の上限 + 1 が無い"; fi

it "[静的/binmode] 読み取り fd を binmode にする（NUL・改行を保つ）"
if printf '%s' "$CODE_FLAT" | grep -Eq 'binmode[[:space:]]*\(?[[:space:]]*\$fh'; then pass; else fail "binmode(\$fh) が無い"; fi

for v in PERL5LIB PERL5OPT PERLLIB PERL5DB PERL_UNICODE PERLIO; do
  it "[静的/env] perl は env -u $v で起動する"
  if printf '%s' "$CODE_FLAT" | grep -Eq -e "env([[:space:]]+-u[[:space:]]+[A-Z0-9_]+)*[[:space:]]+-u[[:space:]]+$v([[:space:]]|\$)"; then pass; else fail "-u $v が無い"; fi
done

it "[静的] シンボリックリンク検査（-L）を使っている"
if [ -f "$SCRIPT_SRC" ] && grep -Eq '\[ -L ' "$SCRIPT_SRC"; then pass; else fail "-L 検査が無い"; fi

it "[静的] LOOP_BOOTSTRAP=0 の早期離脱がある"
if [ -f "$SCRIPT_SRC" ] && grep -q 'LOOP_BOOTSTRAP' "$SCRIPT_SRC"; then pass; else fail "LOOP_BOOTSTRAP を見ていない"; fi

it "[前提] このテストの実行場所の祖先に compose 候補が無い（あると祖先テストの結論が崩れる）"
new_sandbox
hits=""
d="$SANDBOX_ROOT"
while :; do
  for n in $CAND_NAMES; do
    if [ -e "$d/$n" ] || [ -L "$d/$n" ]; then hits="$hits $d/$n"; fi
  done
  [ "$d" = "/" ] && break
  d="$(dirname "$d")"
done
assert_eq "$hits" ""

# ══════════════════════════════════════════════
suite "lib.sh: new_sandbox のコピー対象"
# ══════════════════════════════════════════════

it "new_sandbox が bootstrap-monitor.sh をコピーする"
new_sandbox
assert_file "$SANDBOX_PROJ/.claude/scripts/bootstrap-monitor.sh"

it "new_sandbox が原本 compose.monitor.yml をコピーし、バイト一致する"
new_sandbox
if cmp -s "$ORIG" "$SANDBOX_PROJ/.claude/monitor/compose.monitor.yml"; then pass; else fail "原本が無い、または内容が違う"; fi

# ══════════════════════════════════════════════
suite "条件: 生成する条件としない条件"
# ══════════════════════════════════════════════

it "[条件] package.json も候補も無ければ何も生成しない（テンプレート本体と同じ状態）"
fresh
find "$P" -name package.json -delete
before="$(snap "$P")"
runbm
assert_eq "$(snap "$P")" "$before"

it "[条件] package.json も候補も無くても exit 0"
assert_eq "$RC" "0"

it "[条件] テンプレート本体のルートに package.json・compose 候補・compose.monitor.yml が無い"
found=""
for n in package.json compose.monitor.yml $CAND_NAMES; do
  if [ -e "$REPO_ROOT/$n" ] || [ -L "$REPO_ROOT/$n" ]; then found="$found $n"; fi
done
assert_eq "$found" ""

it "[条件] package.json だけがある（候補なし）: compose.monitor.yml と compose.yaml を生成する"
fresh
runbm
if [ -f "$P/compose.monitor.yml" ] && [ -f "$P/compose.yaml" ]; then pass; else fail "どちらかが生成されていない"; fi

it "[条件] package.json が無く候補だけある: compose.monitor.yml は生成し、候補は不変"
fresh
find "$P" -maxdepth 1 -name package.json -delete
put_cand "$P" compose.yml
b="$(fsnap "$P/compose.yml")"
runbm
if [ -f "$P/compose.monitor.yml" ] && [ "$(fsnap "$P/compose.yml")" = "$b" ] && [ ! -f "$P/compose.yaml" ]; then pass; else fail "条件を満たさない"; fi

it "[条件] 近い名前（compose.txt 等）は候補とみなさず compose.yaml を生成する"
fresh
printf 'x\n' > "$P/compose.txt"
printf 'x\n' > "$P/docker-compose.json"
printf 'x\n' > "$P/compose.yaml.bak"
runbm
assert_file "$P/compose.yaml"

it "[条件] 子ディレクトリや兄弟ディレクトリの compose.yaml は候補とみなさない"
fresh
mkdir -p "$P/sub" "$SANDBOX_ROOT/other"
put_cand "$P/sub" compose.yaml
put_cand "$SANDBOX_ROOT/other" compose.yaml
runbm
assert_file "$P/compose.yaml"

# ══════════════════════════════════════════════
suite "生成: 候補が無い場合"
# ══════════════════════════════════════════════

it "compose.monitor.yml が原本とバイト一致する"
fresh
runbm
if cmp -s "$ORIG" "$P/compose.monitor.yml"; then pass; else fail "原本と一致しない"; fi

it "生成の終了コードは 0"
assert_eq "$RC" "0"

it "compose.yaml が include と project_directory を持つ"
assert_file_contains "$P/compose.yaml" "include:"

it "compose.yaml が compose.monitor.yml を参照する"
assert_file_contains "$P/compose.yaml" "compose.monitor.yml"

it "compose.yaml が project_directory を指定する（無いと build context が壊れる）"
assert_file_contains "$P/compose.yaml" "project_directory"

it "compose.yaml は include だけで services を持たない"
assert_file_not_contains "$P/compose.yaml" "services:"

it "生成したことを --quiet でも報告する"
fresh
runbm --quiet
if [ -n "$LAST_OUTPUT" ]; then pass; else fail "出力が空"; fi

# ══════════════════════════════════════════════
suite "既存候補（直下）: 8 名それぞれ"
# ══════════════════════════════════════════════
# 他は全部正しい（package.json あり・原本あり）。候補を 1 つ置いただけで挙動が変わること

for name in $CAND_NAMES; do
  fresh
  put_cand "$P" "$name"
  before="$(fsnap "$P/$name")"
  runbm

  it "[直下候補] $name: exit 0"
  assert_eq "$RC" "0"

  it "[直下候補] $name: バイトと mtime が不変"
  assert_eq "$(fsnap "$P/$name")" "$before"

  it "[直下候補] $name: compose.yaml を新たに作らない（候補が compose.yaml 自身なら内容が候補のまま）"
  if [ "$name" = "compose.yaml" ]; then
    assert_file_contains "$P/compose.yaml" "# compose.yaml"
  else
    assert_no_file "$P/compose.yaml"
  fi

  it "[直下候補] $name: include 追記の案内が出る"
  case "$LAST_OUTPUT" in
    *include*compose.monitor.yml*|*compose.monitor.yml*include*) pass ;;
    *) fail "include と compose.monitor.yml を含む案内が無い" "出力: $LAST_OUTPUT" ;;
  esac

  it "[直下候補] $name: compose.monitor.yml は原本とバイト一致で生成する"
  if cmp -s "$ORIG" "$P/compose.monitor.yml"; then pass; else fail "生成されていない、または原本と違う"; fi
done

it "[直下候補] 8 名が全て揃っていても全て不変で compose.yaml を上書きしない"
fresh
for n in $CAND_NAMES; do put_cand "$P" "$n"; done
before="$(snap "$P" | grep -v 'compose.monitor.yml')"
runbm
assert_eq "$(snap "$P" | grep -v 'compose.monitor.yml')" "$before"

# ══════════════════════════════════════════════
suite "既存候補（祖先ディレクトリ）: 1〜3 階層上 x 8 名"
# ══════════════════════════════════════════════
# Compose は作業ディレクトリと全ての親ディレクトリを探索する。直下に compose.yaml を作ると
# 祖先の既存ファイルより優先されて挙動が変わる

for depth in 1 2 3; do
  for name in $CAND_NAMES; do
    new_sandbox
    top="$SANDBOX_ROOT"
    case "$depth" in
      1) mkproj "$top/proj1" ; holder="$top" ;;
      2) mkproj "$top/m1/proj2" ; holder="$top" ;;
      3) mkproj "$top/m1/m2/proj3" ; holder="$top" ;;
    esac
    put_cand "$holder" "$name"
    before="$(fsnap "$holder/$name")"
    runbm

    it "[祖先候補] ${depth}階層上の $name: exit 0"
    assert_eq "$RC" "0"

    it "[祖先候補] ${depth}階層上の $name: バイトと mtime が不変"
    assert_eq "$(fsnap "$holder/$name")" "$before"

    it "[祖先候補] ${depth}階層上の $name: プロジェクト直下に compose.yaml を作らない"
    assert_no_file "$P/compose.yaml"

    it "[祖先候補] ${depth}階層上の $name: include 追記の案内が出る"
    case "$LAST_OUTPUT" in
      *include*compose.monitor.yml*|*compose.monitor.yml*include*) pass ;;
      *) fail "案内が無い" "出力: $LAST_OUTPUT" ;;
    esac
  done
done

it "[祖先候補] 途中の階層（中間ディレクトリ）にある候補も検出する"
new_sandbox
mkproj "$SANDBOX_ROOT/m1/m2/proj"
put_cand "$SANDBOX_ROOT/m1" docker-compose.override.yaml
runbm
assert_no_file "$P/compose.yaml"

it "[祖先候補] 祖先に近い名前（compose.txt）しか無ければ compose.yaml を生成する"
new_sandbox
mkproj "$SANDBOX_ROOT/m1/proj"
printf 'x\n' > "$SANDBOX_ROOT/compose.txt"
printf 'x\n' > "$SANDBOX_ROOT/m1/docker-compose.json"
runbm
assert_file "$P/compose.yaml"

# ══════════════════════════════════════════════
suite "祖先の symlink 候補（ダングリング含む）"
# ══════════════════════════════════════════════

for kind in valid dangling; do
  new_sandbox
  mkproj "$SANDBOX_ROOT/m1/proj"
  mkdir -p "$SANDBOX_ROOT/outside"
  tgt="$SANDBOX_ROOT/outside/anc-target.yml"
  if [ "$kind" = "valid" ]; then printf 'services: {}\n' > "$tgt"; old "$tgt"; fi
  ln -s "$tgt" "$SANDBOX_ROOT/compose.yaml"
  before="$(snap "$SANDBOX_ROOT/outside")"
  runbm

  it "[祖先symlink/$kind] exit 0"
  assert_eq "$RC" "0"

  it "[祖先symlink/$kind] プロジェクト直下に compose.yaml を作らない"
  if [ ! -e "$P/compose.yaml" ] && [ ! -L "$P/compose.yaml" ]; then pass; else fail "作られた"; fi

  it "[祖先symlink/$kind] リンク先に書かない（内容・存在が不変）"
  assert_eq "$(snap "$SANDBOX_ROOT/outside")" "$before"

  it "[祖先symlink/$kind] リンク自体が残っている"
  if [ -L "$SANDBOX_ROOT/compose.yaml" ]; then pass; else fail "リンクが消えた"; fi
done

# ══════════════════════════════════════════════
suite "symlink: 直下の生成先・原本・候補（通常リンクとダングリング）"
# ══════════════════════════════════════════════
# 1 つでもリンクなら一切書かない。リンク先にファイルが作られてはならない

VICTIMS="compose.monitor.yml compose.yaml .claude/monitor/compose.monitor.yml compose.yml docker-compose.yml docker-compose.yaml compose.override.yml compose.override.yaml docker-compose.override.yml docker-compose.override.yaml"

for victim in $VICTIMS; do
  for kind in valid dangling; do
    fresh
    mkdir -p "$SANDBOX_ROOT/outside"
    tgt="$SANDBOX_ROOT/outside/SENT_target_$(echo "$victim" | tr '/' '_')"
    if [ "$kind" = "valid" ]; then printf 'ORIGINAL-TARGET\n' > "$tgt"; old "$tgt"; fi
    find "$P/$victim" -maxdepth 0 -type f -delete 2>/dev/null
    ln -s "$tgt" "$P/$victim"
    before_p="$(snap "$P")"
    before_o="$(snap "$SANDBOX_ROOT/outside")"
    runbm

    it "[symlink/$kind] $victim: exit 0"
    assert_eq "$RC" "0"

    it "[symlink/$kind] $victim: プロジェクトに何も書かない"
    assert_eq "$(snap "$P")" "$before_p"

    it "[symlink/$kind] $victim: リンク先が作られない・変わらない"
    assert_eq "$(snap "$SANDBOX_ROOT/outside")" "$before_o"

    it "[symlink/$kind] $victim: WARN を出す"
    assert_contains "$LAST_OUTPUT" "WARN"
  done
done

it "[symlink] --quiet でも警告は出る"
fresh
ln -s "$SANDBOX_ROOT/nowhere" "$P/compose.monitor.yml"
runbm --quiet
assert_contains "$LAST_OUTPUT" "WARN"

it "[symlink] リンクは 2 回目も触らない（冪等）"
b="$(snap "$P")"
runbm --quiet
assert_eq "$(snap "$P")" "$b"

# ══════════════════════════════════════════════
suite "既存の compose.monitor.yml は上書きしない"
# ══════════════════════════════════════════════

fresh
printf '# user edited\nservices: {}\n' > "$P/compose.monitor.yml"
old "$P/compose.monitor.yml"
b="$(fsnap "$P/compose.monitor.yml")"
runbm

it "既存 compose.monitor.yml: バイトと mtime が不変"
assert_eq "$(fsnap "$P/compose.monitor.yml")" "$b"

it "既存 compose.monitor.yml: 候補が無ければ compose.yaml は作る（compose.monitor.yml は候補ではない）"
assert_file "$P/compose.yaml"

it "既存 compose.monitor.yml: exit 0"
assert_eq "$RC" "0"

fresh
printf '# user edited\nservices: {}\n' > "$P/compose.monitor.yml"
put_cand "$P" compose.yml
old "$P/compose.monitor.yml"
b="$(snap "$P")"
runbm

it "既存 compose.monitor.yml と既存候補が両方ある: 何も変わらない"
assert_eq "$(snap "$P")" "$b"

# ══════════════════════════════════════════════
suite "冪等"
# ══════════════════════════════════════════════

fresh
runbm
it "[冪等] 前提: 1 回目で 2 つとも生成されている"
if [ -f "$P/compose.monitor.yml" ] && [ -f "$P/compose.yaml" ]; then pass; else fail "1 回目で生成されていない"; fi
old "$P/compose.monitor.yml"
old "$P/compose.yaml"
b="$(snap "$P")"
runbm --quiet

it "[冪等] 2 回目は何も変更しない（内容・mtime・ファイル集合）"
assert_eq "$(snap "$P")" "$b"

it "[冪等] 2 回目も exit 0"
assert_eq "$RC" "0"

it "[冪等] 2 回目の --quiet は黙る"
assert_eq "$LAST_OUTPUT" ""

it "[冪等] 3 回目も不変"
runbm
assert_eq "$(snap "$P")" "$b"

fresh
put_cand "$P" compose.yml
runbm
old "$P/compose.monitor.yml"
b="$(snap "$P")"
runbm --quiet

it "[冪等] 候補ありの場合も 2 回目は何も変更しない"
assert_eq "$(snap "$P")" "$b"

it "[冪等] 候補ありの場合も 2 回目の --quiet は黙る"
assert_eq "$LAST_OUTPUT" ""

# ══════════════════════════════════════════════
suite "フラグと環境変数"
# ══════════════════════════════════════════════

fresh
b="$(snap "$P")"
runbm --dry-run

it "--dry-run: 何も書かない"
assert_eq "$(snap "$P")" "$b"

it "--dry-run: exit 0"
assert_eq "$RC" "0"

it "--dry-run: 生成する compose.yaml の内容（include）を出す"
assert_contains "$LAST_OUTPUT" "include:"

it "--dry-run: 生成する compose.monitor.yml の内容（原本）を出す"
assert_contains "$LAST_OUTPUT" "monitor-net"

fresh
put_cand "$P" compose.yml
b="$(snap "$P")"
runbm --dry-run

it "--dry-run: 候補ありでも何も書かない"
assert_eq "$(snap "$P")" "$b"

it "--dry-run: 候補ありなら include 追記の案内を出す"
assert_contains "$LAST_OUTPUT" "include"

fresh
find "$P" -maxdepth 1 -name package.json -delete
runbm --quiet

it "--quiet: 何もしなかった（条件を満たさない）時は黙る"
assert_eq "$LAST_OUTPUT" ""

it "非 quiet: 何もしなかった時は理由を 1 行以上出す"
runbm
if [ -n "$LAST_OUTPUT" ]; then pass; else fail "出力が空"; fi

fresh
b="$(snap "$P")"
LAST_OUTPUT="$(LOOP_BOOTSTRAP=0 bm 2>&1)"
RC=$?

it "LOOP_BOOTSTRAP=0: 何も書かない"
assert_eq "$(snap "$P")" "$b"

it "LOOP_BOOTSTRAP=0: exit 0"
assert_eq "$RC" "0"

for badargs in "--bogus" "--quiet --bogus" "foo" "--dry-run=1"; do
  fresh
  b="$(snap "$P")"
  LAST_OUTPUT="$(bm $badargs 2>&1)"
  RC=$?

  it "未知の引数 '$badargs': exit 1"
  assert_eq "$RC" "1"

  it "未知の引数 '$badargs': 何も書かない"
  assert_eq "$(snap "$P")" "$b"
done

# ══════════════════════════════════════════════
suite "出力は固定文字列のみ（外部由来の値を載せない）"
# ══════════════════════════════════════════════
# ディレクトリ名・リンク先に番兵を仕込み、どの経路の出力にも漏れないこと。
# stdout はセッションのコンテキストにそのまま入る

check_no_leak() { # <ラベル> <出力>
  it "[出力] $1: 番兵とパスを含まない"
  case "$2" in
    *SENTINEL*|*INJECT*|*"$SANDBOX_ROOT"*) fail "外部由来の値が出力に載った" "出力: $2" ;;
    *) pass ;;
  esac
}

new_sandbox
SENT="$SANDBOX_ROOT/SENTINEL_A
INJECT_B"
mkproj "$SENT/proj"
runbm
check_no_leak "生成" "$LAST_OUTPUT"
runbm
check_no_leak "2 回目（冪等）" "$LAST_OUTPUT"
runbm --dry-run
check_no_leak "--dry-run" "$LAST_OUTPUT"

new_sandbox
mkproj "$SANDBOX_ROOT/SENTINEL_A
INJECT_B/proj"
put_cand "$SANDBOX_ROOT/SENTINEL_A
INJECT_B" compose.yaml
runbm
check_no_leak "祖先候補（番兵の名前の祖先）" "$LAST_OUTPUT"

new_sandbox
mkproj "$SANDBOX_ROOT/SENTINEL_A
INJECT_B/proj"
put_cand "$P" docker-compose.override.yaml
runbm
check_no_leak "直下候補" "$LAST_OUTPUT"

new_sandbox
mkproj "$SANDBOX_ROOT/SENTINEL_A
INJECT_B/proj"
ln -s "$SANDBOX_ROOT/SENTINEL_link_target
INJECT_B" "$P/compose.monitor.yml"
runbm
check_no_leak "symlink（ダングリング・リンク先に番兵）" "$LAST_OUTPUT"

new_sandbox
mkproj "$SANDBOX_ROOT/SENTINEL_A
INJECT_B/proj"
printf 'x\n' > "$SANDBOX_ROOT/SENTINEL_valid"
find "$P/.claude/monitor" -name compose.monitor.yml -delete
ln -s "$SANDBOX_ROOT/SENTINEL_valid" "$P/.claude/monitor/compose.monitor.yml"
runbm
check_no_leak "原本が symlink（リンク先に番兵）" "$LAST_OUTPUT"

new_sandbox
mkproj "$SANDBOX_ROOT/SENTINEL_A
INJECT_B/proj"
runbm --quiet --dry-run
check_no_leak "--quiet --dry-run" "$LAST_OUTPUT"

it "[出力] 番兵ディレクトリでも終了コードは 0"
assert_eq "$RC" "0"

# ══════════════════════════════════════════════
suite "生成条件は直下だけで決める（祖先の候補だけでは動かない）"
# ══════════════════════════════════════════════
# 祖先の候補は「package.json 等で動く場合に compose.yaml を作らない」抑止にだけ使う。
# ホーム直下に docker-compose.yml を置いた開発者の配下の全リポジトリ・テンプレート本体でも生成されてはならない

for depth in 1 2 3; do
  for name in compose.yaml docker-compose.override.yaml; do
    new_sandbox
    case "$depth" in
      1) mkproj "$SANDBOX_ROOT/proj1" ;;
      2) mkproj "$SANDBOX_ROOT/m1/proj2" ;;
      3) mkproj "$SANDBOX_ROOT/m1/m2/proj3" ;;
    esac
    find "$P" -maxdepth 1 -name package.json -delete
    put_cand "$SANDBOX_ROOT" "$name"
    before_p="$(snap "$P")"
    before_a="$(fsnap "$SANDBOX_ROOT/$name")"
    runbm

    it "[条件/祖先のみ] ${depth}階層上の $name だけ（package.json 無し・直下候補無し）: exit 0"
    assert_eq "$RC" "0"

    it "[条件/祖先のみ] ${depth}階層上の $name だけ: プロジェクトに何も書かない"
    assert_eq "$(snap "$P")" "$before_p"

    it "[条件/祖先のみ] ${depth}階層上の $name だけ: 祖先の候補は不変"
    assert_eq "$(fsnap "$SANDBOX_ROOT/$name")" "$before_a"

    it "[条件/祖先のみ] ${depth}階層上の $name だけ: compose.monitor.yml も compose.yaml も存在しない"
    if [ ! -e "$P/compose.monitor.yml" ] && [ ! -L "$P/compose.monitor.yml" ] && [ ! -e "$P/compose.yaml" ] && [ ! -L "$P/compose.yaml" ]; then pass; else fail "生成された"; fi
  done
done

it "[条件/祖先のみ] 祖先がダングリング symlink の候補だけでも何も書かない"
new_sandbox
mkproj "$SANDBOX_ROOT/m1/proj"
find "$P" -maxdepth 1 -name package.json -delete
ln -s "$SANDBOX_ROOT/nowhere" "$SANDBOX_ROOT/compose.yaml"
before_p="$(snap "$P")"
runbm
if [ "$RC" -eq 0 ] && [ "$(snap "$P")" = "$before_p" ] && [ ! -e "$SANDBOX_ROOT/nowhere" ]; then pass; else fail "rc=$RC" "$LAST_OUTPUT"; fi

it "[条件/祖先のみ] 非 quiet では何もしない理由を 1 行以上出す"
if [ -n "$LAST_OUTPUT" ]; then pass; else fail "出力が空"; fi

it "[条件/祖先のみ] --quiet では黙る（テンプレート本体相当: package.json 無し・祖先に候補あり）"
new_sandbox
mkproj "$SANDBOX_ROOT/m1/tpl"
find "$P" -maxdepth 1 -name package.json -delete
find "$P/.claude/monitor" -name compose.monitor.yml -delete
put_cand "$SANDBOX_ROOT" docker-compose.yml
before_p="$(snap "$P")"
runbm --quiet
if [ "$LAST_OUTPUT" = "" ] && [ "$RC" -eq 0 ] && [ "$(snap "$P")" = "$before_p" ]; then pass; else fail "rc=$RC" "出力: $LAST_OUTPUT"; fi

it "[条件/祖先のみ] --dry-run でも何も出さず何も書かない（生成対象が無い）"
runbm --quiet --dry-run
if [ "$LAST_OUTPUT" = "" ] && [ "$(snap "$P")" = "$before_p" ]; then pass; else fail "出力: $LAST_OUTPUT"; fi

it "[条件/祖先のみ] package.json があり祖先に候補がある: compose.monitor.yml だけ生成し、compose.yaml は作らず案内を出す"
new_sandbox
mkproj "$SANDBOX_ROOT/m1/proj"
put_cand "$SANDBOX_ROOT" compose.yml
runbm
case "$LAST_OUTPUT" in
  *include*compose.monitor.yml*|*compose.monitor.yml*include*) guide_ok=1 ;;
  *) guide_ok=0 ;;
esac
if [ "$RC" -eq 0 ] && cmp -s "$ORIG" "$P/compose.monitor.yml" && [ ! -e "$P/compose.yaml" ] && [ ! -L "$P/compose.yaml" ] && [ "$guide_ok" -eq 1 ]; then pass; else fail "rc=$RC guide=$guide_ok" "出力: $LAST_OUTPUT"; fi

it "[条件/祖先のみ] 直下に候補があれば package.json が無くても動く（直下は生成条件）"
new_sandbox
mkproj "$SANDBOX_ROOT/m1/proj"
find "$P" -maxdepth 1 -name package.json -delete
put_cand "$P" compose.yml
runbm
if cmp -s "$ORIG" "$P/compose.monitor.yml" && [ ! -e "$P/compose.yaml" ]; then pass; else fail "生成されない" "出力: $LAST_OUTPUT"; fi

# ══════════════════════════════════════════════
suite "原本の位置への差し込み（fd で 1 回だけ開く。名前では開き直さない）"
# ══════════════════════════════════════════════
# 名前での事前判定（[ -f ] / [ -L ]）の後に原本が FIFO・リンク・巨大ファイルへ差し替わっても、
# 読み取りは sysopen(O_NONBLOCK|O_NOFOLLOW) の fd 上で判定し、ハング・無制限読みをしない。
# 競合は PATH 先頭の perl shim が再現する（スクリプトが最初に呼ぶ perl の直前で差し替え、本物へ exec で委譲）。

REAL_PERL="$(command -v perl)"
REAL_PS="$(command -v ps)"
MAX_ORIG=65536

# 子を新しいセッションで起動し、3 秒を超えたら打ち切る。終了後に同じ pgid の生き残りを数える。
# 出力: "<timeout 0|1> <exit code|-> <生き残り数>"
BOUNDED_PL='
use POSIX qw(setsid :sys_wait_h);
my ($out, @cmd) = @ARGV;
my $p = fork();
if ($p == 0) { setsid(); open(STDIN, "<", "/dev/null"); open(STDOUT, ">", $out); open(STDERR, ">&", \*STDOUT); exec @cmd; exit 127 }
my ($t, $rc, $to) = (0, "-", 0);
while (1) {
  my $w = waitpid($p, WNOHANG);
  if ($w == $p) { $rc = $? >> 8; last }
  select(undef, undef, undef, 0.05); $t += 0.05;
  if ($t > 3) { $to = 1; last }
}
select(undef, undef, undef, 0.5);
my $n = 0;
open(my $ps, "-|", $ENV{TEST_PS}, "-A", "-o", "pgid=,stat=") or die;
while (<$ps>) { my ($g, $s) = split; $n++ if defined $s && $g == $p && $s !~ /^Z/ }
close($ps);
kill("KILL", -$p);
print "$to $rc $n\n";
'

bounded() { # <出力ファイル> <コマンド...> → BO_TIMEOUT BO_RC BO_ALIVE
  local r
  r="$(TEST_PS="$REAL_PS" "$REAL_PERL" -e "$BOUNDED_PL" "$@" 2>/dev/null)"
  set -- $r
  BO_TIMEOUT="${1:-?}"; BO_RC="${2:-?}"; BO_ALIVE="${3:-?}"
}

direct_run() { # [スクリプト引数...]
  bounded "$SANDBOX_ROOT/out.txt" "$BASH" "$P/.claude/scripts/bootstrap-monitor.sh" "$@"
  LAST_OUTPUT="$(cat "$SANDBOX_ROOT/out.txt" 2>/dev/null)"
  RC="$BO_RC"
}

mk_perl_shim() { # <shim dir> — 最初の perl 呼び出しで SHIM_MODE の差し替えをして、本物の perl に委譲する
  mkdir -p "$1"
  {
    printf '#!%s\n' "$BASH"  # 実行中の bash の絶対パス（env bash は PATH 先頭の shim 等を拾いうる）
    cat <<'SHIM'
[ "${SHIM_MODE:-}" = broken ] && exit 3
printf '%s\n' "$@" >> "${SHIM_DIR:-/dev/null}/argv.log"
if [ -n "${SHIM_DIR:-}" ] && [ ! -e "$SHIM_DIR/.fired" ]; then
  : > "$SHIM_DIR/.fired"
  O="$SHIM_PLANT/.claude/monitor/compose.monitor.yml"
  case "${SHIM_MODE:-}" in
    link) ln -s "$SHIM_TARGET" "$SHIM_PLANT/$SHIM_NAME" ;;
    file) printf 'USER-RACE-FILE\n' > "$SHIM_PLANT/$SHIM_NAME" ;;
    fifo) mkfifo "$SHIM_PLANT/$SHIM_NAME" ;;
    orig-fifo) rm -f "$O"; mkfifo "$O" ;;
    orig-fifo-data) rm -f "$O"; mkfifo "$O"; exec 8<>"$O"; printf 'FIFO-DATA\n' >&8 ;;
    orig-link) rm -f "$O"; ln -s "$SHIM_TARGET" "$O" ;;
    orig-big) rm -f "$O"; head -c 65537 /dev/zero > "$O" ;;
  esac
fi
SHIM
    printf 'exec "%s" "$@"\n' "$REAL_PERL"
  } > "$1/perl"
  chmod +x "$1/perl"
}

shim_run() { # <mode> — SHIM_NAME / SHIM_TARGET は呼び出し側で設定。$P は用意済み
  SHIM_BASE="$SANDBOX_ROOT/shim"
  mk_perl_shim "$SHIM_BASE"
  PATH="$SHIM_BASE:$PATH" SHIM_DIR="$SHIM_BASE" SHIM_MODE="$1" SHIM_NAME="${SHIM_NAME:-}" SHIM_PLANT="$P" SHIM_TARGET="${SHIM_TARGET:-}" \
    bounded "$SANDBOX_ROOT/out.txt" "$BASH" "$P/.claude/scripts/bootstrap-monitor.sh"
  LAST_OUTPUT="$(cat "$SANDBOX_ROOT/out.txt" 2>/dev/null)"
  RC="$BO_RC"
  SHIM_FIRED=0
  [ -e "$SHIM_BASE/.fired" ] && SHIM_FIRED=1
}

bytes_file() { # <パス> <バイト数> — 0..255 を繰り返す（NUL を含み、末尾改行なし）
  "$REAL_PERL" -e 'binmode STDOUT; print map { chr($_ % 256) } 0 .. $ARGV[1] - 1' _ "$2" > "$1"
}

# 何も生成せず、ハングせず、孤児を残さず、WARN + exit 0
expect_nothing() { # <label>
  it "[$1] 3 秒以内に終わる（ハングしない）"
  assert_eq "$BO_TIMEOUT" "0"
  it "[$1] 背景・孤児プロセスが残らない"
  assert_eq "$BO_ALIVE" "0"
  it "[$1] compose.monitor.yml も compose.yaml も生成しない"
  if [ ! -e "$P/compose.monitor.yml" ] && [ ! -L "$P/compose.monitor.yml" ] && [ ! -e "$P/compose.yaml" ] && [ ! -L "$P/compose.yaml" ]; then pass; else fail "生成された"; fi
  it "[$1] WARN を出して exit 0"
  if [ "$RC" = "0" ]; then assert_contains "$LAST_OUTPUT" "WARN"; else fail "rc=$RC" "$LAST_OUTPUT"; fi
}

# <文字列> が <部分文字列> を含まないこと（lib.sh に無いのでここで定義する）
assert_not_contains() { # <文字列> <部分文字列>
  case "$1" in
    *"$2"*) fail "'$2' を含まないはずが含まれている" "実際: '$1'" ;;
    *) pass ;;
  esac
}

# ---- 最初から原本がそうなっている場合（名前での事前判定でも止まるが、結論は同じ） ----

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
rm -f "$OPATH"; mkfifo "$OPATH"
direct_run
expect_nothing "原本/FIFO"

it "[原本/FIFO] WARN は「通常ファイルではない」旨で、「原本が無い」旨ではない"
assert_contains "$LAST_OUTPUT" "が通常ファイルではない"
it "[原本/FIFO] 「原本 ... が無い」の文言を出さない"
assert_not_contains "$LAST_OUTPUT" "compose.monitor.yml が無い"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
rm -f "$OPATH"; mkdir "$OPATH"
direct_run
expect_nothing "原本/ディレクトリ"
it "[原本/ディレクトリ] WARN は「通常ファイルではない」旨で、「原本が無い」旨ではない"
assert_contains "$LAST_OUTPUT" "が通常ファイルではない"
it "[原本/ディレクトリ] 「原本 ... が無い」の文言を出さない"
assert_not_contains "$LAST_OUTPUT" "compose.monitor.yml が無い"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
rm -f "$OPATH"
direct_run
expect_nothing "原本/存在しない"
it "[原本/存在しない] WARN は「原本が無い」旨"
assert_contains "$LAST_OUTPUT" "compose.monitor.yml が無い"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
rm -f "$OPATH"; ln -s /dev/zero "$OPATH"
direct_run
expect_nothing "原本//dev/zero へのリンク"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
rm -f "$OPATH"; bytes_file "$OPATH" $((MAX_ORIG + 1))
direct_run
expect_nothing "原本/65537 バイト（上限超過）"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
rm -f "$OPATH"; bytes_file "$OPATH" $((MAX_ORIG + 1))
direct_run --dry-run

it "[原本/65537 バイト/dry-run] 内容を表示せず WARN を出して exit 0"
if [ "$RC" = "0" ] && [ "${#LAST_OUTPUT}" -lt 4096 ]; then assert_contains "$LAST_OUTPUT" "WARN"; else fail "rc=$RC len=${#LAST_OUTPUT}"; fi

it "[原本/65537 バイト/dry-run] 「生成される compose.monitor.yml」の見出しを出さない"
assert_not_contains "$LAST_OUTPUT" "生成される compose.monitor.yml"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
rm -f "$OPATH"; bytes_file "$OPATH" "$MAX_ORIG"
direct_run

it "[原本/ちょうど 64KB] 生成する（上限は超過のみ拒否）: バイト一致・exit 0・ハングしない"
if [ "$RC" = "0" ] && [ "$BO_TIMEOUT" = "0" ] && cmp -s "$OPATH" "$P/compose.monitor.yml"; then pass; else fail "rc=$RC timeout=$BO_TIMEOUT" "$LAST_OUTPUT"; fi

it "[原本/ちょうど 64KB] 孤児プロセスが残らない"
assert_eq "$BO_ALIVE" "0"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
printf 'a\0b\nservices:\0' > "$OPATH"
direct_run

it "[原本/NUL を含む] NUL も末尾（改行なし）もバイト一致で複製する"
if [ "$RC" = "0" ] && cmp -s "$OPATH" "$P/compose.monitor.yml" && [ "$(wc -c < "$P/compose.monitor.yml" | tr -d ' ')" = "14" ]; then pass; else fail "rc=$RC" "$LAST_OUTPUT"; fi

# ---- 事前判定の後に差し替わる場合（perl shim。名前で開き直す実装はここで落ちる） ----

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
shim_run orig-fifo
it "[原本/競合/FIFO] shim が実際に発火している（空振りの検出）"
assert_eq "$SHIM_FIRED" "1"
expect_nothing "原本/競合/FIFO"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
shim_run orig-fifo-data
it "[原本/競合/FIFO(書き手あり)] shim が実際に発火している"
assert_eq "$SHIM_FIRED" "1"
expect_nothing "原本/競合/FIFO(書き手あり)"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
SHIM_TARGET=/dev/zero
shim_run orig-link
it "[原本/競合//dev/zero へのリンク] shim が実際に発火している"
assert_eq "$SHIM_FIRED" "1"
expect_nothing "原本/競合//dev/zero へのリンク"

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
mkdir -p "$SANDBOX_ROOT/outside"
cp "$ORIG" "$SANDBOX_ROOT/outside/real.yml"
SHIM_TARGET="$SANDBOX_ROOT/outside/real.yml"
shim_run orig-link
it "[原本/競合/通常ファイルへのリンク] shim が実際に発火している"
assert_eq "$SHIM_FIRED" "1"
expect_nothing "原本/競合/通常ファイルへのリンク（O_NOFOLLOW で拒否する）"
unset SHIM_TARGET

fresh; OPATH="$P/.claude/monitor/compose.monitor.yml"
shim_run orig-big
it "[原本/競合/65537 バイト] shim が実際に発火している"
assert_eq "$SHIM_FIRED" "1"
expect_nothing "原本/競合/65537 バイト"

# ---- perl の起動条件 ----

fresh
shim_run none
it "[perl] perl の argv にパスを載せない（環境変数と stdin/stdout だけで渡す）"
if [ -s "$SHIM_BASE/argv.log" ] && ! grep -qF -e "$P" -e "$SANDBOX_ROOT" "$SHIM_BASE/argv.log"; then pass; else fail "perl が呼ばれていない、または argv にパスがある"; fi

it "[perl] 通常の生成が perl 経由で成功する（原本とバイト一致・compose.yaml も生成）"
if [ "$RC" = "0" ] && cmp -s "$ORIG" "$P/compose.monitor.yml" && [ -f "$P/compose.yaml" ]; then pass; else fail "rc=$RC" "$LAST_OUTPUT"; fi

fresh
LAST_OUTPUT="$(PERL5OPT=-MNoSuchModuleXYZ PERL5LIB=/nonexistent PERLLIB=/nonexistent PERL_UNICODE=SDA PERLIO=:utf8 bm 2>&1)"
RC=$?
it "[perl] PERL5OPT / PERL5LIB / PERL_UNICODE 等が汚れていても生成する（env -u で外して起動する）"
if [ "$RC" = "0" ] && cmp -s "$ORIG" "$P/compose.monitor.yml" && [ -f "$P/compose.yaml" ]; then pass; else fail "rc=$RC" "$LAST_OUTPUT"; fi

fresh
shim_run broken
it "[perl] perl（または Fcntl）が使えない: 何も生成せず WARN・exit 0"
if [ "$RC" = "0" ] && [ ! -e "$P/compose.monitor.yml" ] && [ ! -e "$P/compose.yaml" ]; then assert_contains "$LAST_OUTPUT" "WARN"; else fail "rc=$RC" "$LAST_OUTPUT"; fi

fresh
NOPERL_BIN="$SANDBOX_ROOT/noperl-bin"
mkdir -p "$NOPERL_BIN"
ln -s "$(command -v env)" "$NOPERL_BIN/env"
PATH="$NOPERL_BIN" bounded "$SANDBOX_ROOT/out.txt" "$BASH" "$P/.claude/scripts/bootstrap-monitor.sh"
LAST_OUTPUT="$(cat "$SANDBOX_ROOT/out.txt" 2>/dev/null)"
RC="$BO_RC"
expect_nothing "perl が PATH に無い"

# ══════════════════════════════════════════════
suite "書き込みの差し込み（O_EXCL|O_NOFOLLOW で原子的に作る）"
# ══════════════════════════════════════════════
# 初回判定の後、スクリプトが呼ぶ最初の perl の直前に、PATH 先頭の perl shim が生成先へ
# リンク・通常ファイル・FIFO を仕込み、本物の perl に委譲する。
# 変異: 書き込みの O_EXCL または O_NOFOLLOW を外すと、リンク先への書き込み・既存の上書きで FAIL する。
#       O_NONBLOCK は O_EXCL が FIFO を先に弾くため動的には再現できず、静的検査 [静的/書き込み] で固定する

for victim in compose.monitor.yml compose.yaml; do
  for kind in dangling valid devnull; do
    fresh
    mkdir -p "$SANDBOX_ROOT/outside"
    case "$kind" in
      dangling) SHIM_TARGET="$SANDBOX_ROOT/outside/RACE_target" ;;
      valid)    SHIM_TARGET="$SANDBOX_ROOT/outside/RACE_target"; printf 'ORIGINAL-TARGET\n' > "$SHIM_TARGET"; old "$SHIM_TARGET" ;;
      devnull)  SHIM_TARGET=/dev/null ;;
    esac
    before_o="$(snap "$SANDBOX_ROOT/outside")"
    SHIM_NAME="$victim"
    shim_run link

    it "[書込競合/$kind] $victim: shim が実際に発火している（空振りの検出）"
    assert_eq "$SHIM_FIRED" "1"

    it "[書込競合/$kind] $victim: 3 秒以内に終わる・孤児が残らない"
    if [ "$BO_TIMEOUT" = "0" ] && [ "$BO_ALIVE" = "0" ]; then pass; else fail "timeout=$BO_TIMEOUT alive=$BO_ALIVE"; fi

    it "[書込競合/$kind] $victim: 仕込まれたリンクの先に書かない（作られない・内容不変）"
    assert_eq "$(snap "$SANDBOX_ROOT/outside")" "$before_o"

    it "[書込競合/$kind] $victim: リンク自体が残っている"
    if [ -L "$P/$victim" ]; then pass; else fail "リンクが消えた/置換された"; fi

    it "[書込競合/$kind] $victim: WARN を出して exit 0（成功したと報告しない）"
    if [ "$RC" = "0" ]; then assert_contains "$LAST_OUTPUT" "WARN"; else fail "rc=$RC" "$LAST_OUTPUT"; fi

    if [ "$kind" = "devnull" ]; then
      it "[書込競合/devnull] $victim: /dev/null が通常ファイルに置き換わっていない"
      if [ -c /dev/null ]; then pass; else fail "/dev/null が壊れた"; fi
    fi
    unset SHIM_TARGET
  done

  fresh
  SHIM_NAME="$victim"
  shim_run file

  it "[書込競合/通常ファイル] $victim: shim が実際に発火している"
  assert_eq "$SHIM_FIRED" "1"

  it "[書込競合/通常ファイル] $victim: 仕込まれた通常ファイルを上書きしない"
  assert_eq "$(cat "$P/$victim")" "USER-RACE-FILE"

  it "[書込競合/通常ファイル] $victim: exit 0・3 秒以内・孤児なし"
  if [ "$RC" = "0" ] && [ "$BO_TIMEOUT" = "0" ] && [ "$BO_ALIVE" = "0" ]; then pass; else fail "rc=$RC timeout=$BO_TIMEOUT alive=$BO_ALIVE"; fi

  fresh
  SHIM_NAME="$victim"
  shim_run fifo

  it "[書込競合/FIFO] $victim: shim が実際に発火している"
  assert_eq "$SHIM_FIRED" "1"

  it "[書込競合/FIFO] $victim: ブロックしない（3 秒以内）・孤児が残らない"
  if [ "$BO_TIMEOUT" = "0" ] && [ "$BO_ALIVE" = "0" ]; then pass; else fail "timeout=$BO_TIMEOUT alive=$BO_ALIVE"; fi

  it "[書込競合/FIFO] $victim: FIFO のまま・exit 0（WARN の有無は問わない: 書く直前の存在確認で黙って見送る実装も可）"
  if [ "$RC" = "0" ] && [ -p "$P/$victim" ]; then pass; else fail "rc=$RC" "$LAST_OUTPUT"; fi
done
unset SHIM_NAME

# ══════════════════════════════════════════════
suite "既知の限界（通ってしまう代表経路。security.md に記載する）"
# ══════════════════════════════════════════════

it "[既知の限界] プロジェクトディレクトリ自体が symlink の場合は辿って書き込む（最終要素だけを見る設計）"
new_sandbox
mkproj "$SANDBOX_ROOT/real"
ln -s "$SANDBOX_ROOT/real" "$SANDBOX_ROOT/link"
P="$SANDBOX_ROOT/link"
export CLAUDE_PROJECT_DIR="$P"
runbm
assert_ok bash -c '[ "$1" -eq 0 ] && [ -f "$2/real/compose.monitor.yml" ] && [ -f "$2/real/compose.yaml" ]' _ "$RC" "$SANDBOX_ROOT"

it "[既知の限界] COMPOSE_FILE が設定されていても、直下に候補が無ければ compose.yaml を生成する（スクリプトは COMPOSE_FILE を見ない）"
fresh
LAST_OUTPUT="$(COMPOSE_FILE="$SANDBOX_ROOT/other.yml" bm 2>&1)"
RC=$?
assert_ok bash -c '[ "$1" -eq 0 ] && [ -f "$2/compose.yaml" ] && [ -f "$2/compose.monitor.yml" ]' _ "$RC" "$P"

it "[既知の限界] COMPOSE_FILE が設定されていても、COMPOSE_FILE の指すファイルには書かない"
assert_no_file "$SANDBOX_ROOT/other.yml"

# ══════════════════════════════════════════════
suite "settings.json: SessionStart の登録"
# ══════════════════════════════════════════════

SETTINGS="$REPO_ROOT/.claude/settings.json"
CMD_PROJECT='bash $CLAUDE_PROJECT_DIR/.claude/scripts/bootstrap-project.sh --quiet'
CMD_MONITOR='bash $CLAUDE_PROJECT_DIR/.claude/scripts/bootstrap-monitor.sh --quiet'
CMD_EMIT='bash $CLAUDE_PROJECT_DIR/.claude/hooks/monitor-emit.sh'

session_cmds() { jq -r '.hooks.SessionStart[].hooks[].command' "$SETTINGS"; }

it "SessionStart に bootstrap-monitor.sh --quiet が 1 回だけ登録されている"
assert_eq "$(session_cmds | grep -cFx -- "$CMD_MONITOR")" "1"

it "bootstrap-monitor.sh は bootstrap-project.sh の後に登録されている"
pi="$(session_cmds | grep -nFx -- "$CMD_PROJECT" | head -1 | cut -d: -f1)"
mi="$(session_cmds | grep -nFx -- "$CMD_MONITOR" | head -1 | cut -d: -f1)"
if [ -n "$pi" ] && [ -n "$mi" ] && [ "$mi" -gt "$pi" ]; then pass; else fail "project=${pi:-なし} monitor=${mi:-なし}"; fi

it "既存の SessionStart フック（bootstrap-project・monitor-emit）が不変で、順序も保たれている"
assert_eq "$(session_cmds | grep -vFx -- "$CMD_MONITOR" | tr '\n' '|')" "${CMD_PROJECT}|${CMD_EMIT}|"

it "bootstrap-monitor の登録は command 型で、他の SessionStart エントリと同じ形（hooks 配列 1 要素）"
assert_eq "$(jq -c '[.hooks.SessionStart[] | select(.hooks[0].command == "'"$CMD_MONITOR"'")] | map(.hooks | map(.type))' "$SETTINGS")" '[["command"]]'

it "settings.json が妥当な JSON"
assert_ok jq -e . "$SETTINGS"

it "bootstrap-project.sh は変更されていない（HEAD との差分 0）"
assert_ok git -C "$REPO_ROOT" diff --quiet HEAD -- .claude/scripts/bootstrap-project.sh

it "bootstrap-project.sh は main との差分 0（main が無い環境では HEAD で代替）"
if git -C "$REPO_ROOT" rev-parse --verify -q main >/dev/null 2>&1; then
  assert_ok git -C "$REPO_ROOT" diff --quiet main -- .claude/scripts/bootstrap-project.sh
else
  assert_ok git -C "$REPO_ROOT" diff --quiet HEAD -- .claude/scripts/bootstrap-project.sh
fi

# ══════════════════════════════════════════════
suite "docker compose config: 生成物が導入先で実際に動く"
# ══════════════════════════════════════════════

it "docker と docker compose（v2）が使える"
GATE_MSG="$(compose_gate 2>&1)"
GATE_RC=$?
if [ "$GATE_RC" -eq 0 ]; then pass; else fail "$GATE_MSG"; fi

if [ "$GATE_RC" -ne 0 ]; then
  report
  exit 1
fi

ctx_of() { # <dir> — compose.yaml を読んだ monitor の build context（実体パス）
  local c
  c="$(cd "$1" && docker compose config --format json 2>/dev/null | jq -r '.services.monitor.build.context // empty')" || return 1
  [ -n "$c" ] || return 1
  ( cd "$c" 2>/dev/null && pwd -P )
}

fresh
runbm
want="$(cd "$P/.claude/monitor" && pwd -P)"

it "生成した compose.yaml で docker compose config が成功する"
assert_ok bash -c 'cd "$1" && docker compose config >/dev/null' _ "$P"

it "build context が ./.claude/monitor の実体パスを指す"
assert_eq "$(ctx_of "$P")" "$want"

it "-f と --project-directory を明示しても build context が同じ実体を指す"
c2="$(cd "$P" && docker compose -f compose.yaml --project-directory . config --format json 2>/dev/null | jq -r '.services.monitor.build.context // empty')"
assert_eq "$(cd "$c2" 2>/dev/null && pwd -P)" "$want"

it "専用ネットワーク monitor-net が有効なまま include される"
assert_eq "$(cd "$P" && docker compose config --format json 2>/dev/null | jq -r '.services.monitor.networks | keys | join(",")')" "monitor-net"

raw_ctx() { (cd "$1" && docker compose config --format json 2>/dev/null | jq -r '.services.monitor.build.context // empty'); }

it "[自己診断] 原本を直接 include して project_directory を省くと build context が壊れる（#20 の実測。検査が判別力を持つ）"
fresh
printf 'include:\n  - path: .claude/monitor/compose.monitor.yml\n' > "$P/compose.yaml"
case "$(raw_ctx "$P")" in
  */.claude/monitor/.claude/monitor) pass ;;
  *) fail "壊れた形が壊れた context にならない: $(raw_ctx "$P")" ;;
esac

it "[自己診断] 同じ形でも project_directory: . を付けると build context が実体を指す"
printf 'include:\n  - path: .claude/monitor/compose.monitor.yml\n    project_directory: .\n' > "$P/compose.yaml"
assert_eq "$(cd "$(raw_ctx "$P")" 2>/dev/null && pwd -P)" "$(cd "$P/.claude/monitor" && pwd -P)"

report
