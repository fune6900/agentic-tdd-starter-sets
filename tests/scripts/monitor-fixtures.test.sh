#!/usr/bin/env bash
# .claude/monitor 配下の実測ドキュメントと fixtures の検査（Issue #17 / Red）
#
# Architect / Coder との契約（このテストが前提にする機械可読フォーマット）:
#
#   1. `.claude/monitor/docs/hook-events.md`
#      - 次の10イベント名を本文中に含む:
#        SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse
#        SubagentStart SubagentStop Stop Notification PreCompact
#      - 見出しまたは記載として「Claude Code のバージョン」「測定日」「測定手順」を含む
#      - 実測結果として agent_id / agent_type / agent_transcript_path / async /
#        message.id の各語を本文中に含む（「来た」「来なかった」等の結果つきで書く）
#
#   2. `.claude/monitor/docs/event-schema.md`
#      - `<!-- SCHEMA:KEYS -->` と `<!-- /SCHEMA:KEYS -->` の間に、許可するトップ
#        レベルキーを1行1個 `- \`key\`` 形式で列挙する（この区画だけを機械的に読む）
#
#   3. `.claude/monitor/test/fixtures/hook-stdin/<Event>.json` と
#      `.claude/monitor/test/fixtures/emitted/<Event>.json`（`<Event>.<variant>.json` も可）
#      - 全て `jq -e .` で妥当な JSON であること
#      - hook-stdin 側は `.hook_event_name` がファイル名の先頭要素（拡張子を除き
#        最初の `.` までの部分）と一致すること
#      - emitted 側はトップレベルキー集合が event-schema.md の SCHEMA:KEYS の部分集合であること
#      - 全文字列値（ネスト含む）に実行時の ${HOME}・whoami・/Users/・/home/ を含まないこと
#
#   4. `.claude/monitor/docs/*.md`（hook-events.md・event-schema.md を含む全 Markdown）
#      - ファイル全文に実行時の ${HOME}・whoami・/Users/・/home/ を含まないこと
#        （記録の行き先は fixtures だけではない。実測手順のコマンド例に実ユーザー名
#        入りの絶対パスを書き残すのも漏洩。lessons #11「入力の行き先を全数列挙」）
#
#   5. 採取用のダンプフック（ファイル名に dump を含む .sh）はコミットしない
#
# 個人情報漏洩の判定は grep ではなく case で行う（lessons #10: grep は行単位の判定なので、
# `^...$` のようなつもりの検証が複数行入力の1行目だけを見てすり抜ける）。
# fixtures（JSON）は `jq -j '(.. | strings) + "\u0000"'` で全文字列値を NUL 区切りに変換して
# 読むことで、値の中に改行が埋め込まれていても1つの値として丸ごと判定できるようにしている。
# docs（Markdown）は JSON ではないので、ファイル全文を1つの文字列として読み、同じ禁止
# パターン判定（match_leak_patterns）に通す。判定ロジックは1箇所（match_leak_patterns）
# に集約し、対象が増えても複製しない。
#
# MONITOR_DIR で検査対象ルートを差し替えられる（既定: $REPO_ROOT/.claude/monitor）。
# 例: MONITOR_DIR=/path/to/scratch bash tests/scripts/monitor-fixtures.test.sh

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

cd "$REPO_ROOT" || exit 1

trap cleanup_sandboxes EXIT

MONITOR_DIR="${MONITOR_DIR:-$REPO_ROOT/.claude/monitor}"
HOOK_EVENTS_DOC="$MONITOR_DIR/docs/hook-events.md"
SCHEMA_DOC="$MONITOR_DIR/docs/event-schema.md"
HOOK_STDIN_DIR="$MONITOR_DIR/test/fixtures/hook-stdin"
EMITTED_DIR="$MONITOR_DIR/test/fixtures/emitted"

HOOK_EVENT_NAMES="SessionStart SessionEnd UserPromptSubmit PreToolUse PostToolUse SubagentStart SubagentStop Stop Notification PreCompact"

# ---------- 共有ヘルパー ----------

# 禁止パターン（実行時の ${HOME}・whoami・/Users/・/home/）に1つでも一致すれば、
# 一致したパターンをスペース区切りで返す（空文字列なら安全）。
# check_no_leak（JSON 用）と check_no_leak_text（Markdown 等プレーンテキスト用）が
# この判定ロジックを共有する。対象フォーマットが増えてもここ1箇所を直せばよい。
match_leak_patterns() { # <text>
  local text="$1" pat leaked=""
  for pat in "$HOME" "$(whoami)" "/Users/" "/home/"; do
    [ -n "$pat" ] || continue
    case "$text" in
      *"$pat"*) leaked="$leaked $pat" ;;
    esac
  done
  printf '%s' "$leaked"
}

# 全文字列値（ネスト含む）から禁止パターンを検出する。見つかった分だけ
# スペース区切りで標準出力へ返す（空文字列なら安全）。
check_no_leak() { # <json path>
  local f="$1" value leaked=""
  while IFS= read -r -d '' value; do
    leaked="$leaked$(match_leak_patterns "$value")"
  done < <(jq -j '(.. | strings) + "\u0000"' "$f" 2>/dev/null)
  printf '%s' "$leaked"
}

# ファイル全文を1つの文字列として禁止パターンを検出する（Markdown 等の非 JSON 用）。
# jq で取り出す構造化された値が無いテキストファイルはこちらを使う。
check_no_leak_text() { # <text file path>
  local f="$1" content
  content="$(cat "$f" 2>/dev/null)"
  match_leak_patterns "$content"
}

# event-schema.md の <!-- SCHEMA:KEYS --> 区画から `- \`key\`` 形式のキー名を取り出す。
schema_keys() { # <schema doc path>
  sed -n '/<!-- SCHEMA:KEYS -->/,/<!-- \/SCHEMA:KEYS -->/p' "$1" 2>/dev/null \
    | sed -n 's/^- `\([A-Za-z0-9_.-]*\)`.*/\1/p'
}

key_allowed() { # <key> <改行区切りの許可リスト>
  local k="$1" list="$2" line
  while IFS= read -r line; do
    [ "$line" = "$k" ] && return 0
  done <<< "$list"
  return 1
}

count_json() { # <dir> -> 直下の *.json 件数
  find "$1" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '
}

# 一時ディレクトリを1つ作り SANDBOXES に登録して掃除対象にする（呼び出し側は
# 変数名を渡す。`$(new_tmp_dir)` のようにコマンド置換で呼ぶと、mktemp 失敗時の
# exit がサブシェルだけを終了させて親スクリプトを止め損ね、かつ SANDBOXES への
# 登録もサブシェル内で消えて掃除されない。だから printf -v で直接代入する）。
new_tmp_dir() { # <代入先の変数名>
  local __dest="$1" dir
  dir="$(mktemp -d)" || { echo "mktemp に失敗した" >&2; exit 1; }
  SANDBOXES+=("$dir")
  printf -v "$__dest" '%s' "$dir"
}

# JSON のトップレベルキーのうち許可リストに無いものをスペース区切りで返す
# （空文字列なら全て許可済み）。check_emitted_fixture 本体と自己診断の両方が
# ここを通ることで、自己診断が本体と同じ判定ロジックを検査する。
extra_keys() { # <json path> <改行区切りの許可リスト>
  local f="$1" keys="$2" k extra=""
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    key_allowed "$k" "$keys" || extra="$extra $k"
  done < <(jq -r 'keys[]' "$f" 2>/dev/null)
  printf '%s' "$extra"
}

check_hook_stdin_fixture() { # <path>
  local f="$1" name base prefix actual hit
  name="$(basename "$f")"

  it "hook-stdin/${name} が妥当な JSON"
  assert_ok jq -e . "$f"

  it "hook-stdin/${name} に個人情報が残っていない"
  hit="$(check_no_leak "$f")"
  assert_eq "$(echo "$hit" | tr -s ' ')" ""

  base="${name%.json}"
  prefix="${base%%.*}"
  actual="$(jq -r '.hook_event_name // empty' "$f" 2>/dev/null)"
  it "hook-stdin/${name} の hook_event_name がファイル名（${prefix}）と一致する"
  assert_eq "$actual" "$prefix"
}

check_emitted_fixture() { # <path> <schema keys list（改行区切り）>
  local f="$1" keys="$2" name hit extra
  name="$(basename "$f")"

  it "emitted/${name} が妥当な JSON"
  assert_ok jq -e . "$f"

  it "emitted/${name} に個人情報が残っていない"
  hit="$(check_no_leak "$f")"
  assert_eq "$(echo "$hit" | tr -s ' ')" ""

  it "emitted/${name} のトップレベルキーがスキーマの部分集合"
  extra="$(extra_keys "$f" "$keys")"
  assert_eq "$(echo "$extra" | tr -s ' ')" ""
}

check_doc_no_leak() { # <markdown path>
  local f="$1" name hit
  name="$(basename "$f")"

  it "docs/${name} に個人情報が残っていない（ファイル全文判定）"
  hit="$(check_no_leak_text "$f")"
  assert_eq "$(echo "$hit" | tr -s ' ')" ""
}

run_dir_checks() { # <monitor_dir>
  local dir="$1" f keys
  keys="$(schema_keys "$dir/docs/event-schema.md")"
  for f in "$dir/docs"/*.md; do
    [ -e "$f" ] || continue
    check_doc_no_leak "$f"
  done
  for f in "$dir/test/fixtures/hook-stdin"/*.json; do
    [ -e "$f" ] || continue
    check_hook_stdin_fixture "$f"
  done
  for f in "$dir/test/fixtures/emitted"/*.json; do
    [ -e "$f" ] || continue
    check_emitted_fixture "$f" "$keys"
  done
}

# ══════════════════════════════════════════════
suite "monitor-fixtures: hook-events.md の実測記録"
# ══════════════════════════════════════════════

it "hook-events.md が存在する"
assert_file "$HOOK_EVENTS_DOC"

for ev in $HOOK_EVENT_NAMES; do
  it "hook-events.md に ${ev} の実測が記録されている"
  assert_file_contains "$HOOK_EVENTS_DOC" "$ev"
done

for heading in "Claude Code のバージョン" "測定日" "測定手順"; do
  it "hook-events.md に「${heading}」の記載がある"
  assert_file_contains "$HOOK_EVENTS_DOC" "$heading"
done

for term in agent_id agent_type agent_transcript_path async "message.id"; do
  it "hook-events.md に ${term} の実測結果が記録されている"
  assert_file_contains "$HOOK_EVENTS_DOC" "$term"
done

# ══════════════════════════════════════════════
suite "monitor-fixtures: event-schema.md の存在"
# ══════════════════════════════════════════════

it "event-schema.md が存在する"
assert_file "$SCHEMA_DOC"

# ══════════════════════════════════════════════
suite "monitor-fixtures: fixtures ディレクトリの実在"
# ══════════════════════════════════════════════

it "hook-stdin fixtures が1件以上ある"
n="$(count_json "$HOOK_STDIN_DIR")"
if [ "${n:-0}" -ge 1 ] 2>/dev/null; then pass; else fail "0件だった: ${HOOK_STDIN_DIR}"; fi

it "emitted fixtures が1件以上ある"
n="$(count_json "$EMITTED_DIR")"
if [ "${n:-0}" -ge 1 ] 2>/dev/null; then pass; else fail "0件だった: ${EMITTED_DIR}"; fi

# ══════════════════════════════════════════════
suite "monitor-fixtures: docs・fixtures の妥当性・個人情報・スキーマ整合"
# ══════════════════════════════════════════════
# 対象は ${MONITOR_DIR}（既定は実リポジトリ）。ファイルが無ければループは素通りする
# だけなので、実在の検査は上の suite が別途担っている。
# docs/*.md の個人情報検査もここに含む（fixtures だけを見て docs を見落とすと、
# 実測手順のコマンド例に残した実ユーザー名入りパスが素通りする）。

run_dir_checks "$MONITOR_DIR"

# ══════════════════════════════════════════════
suite "monitor-fixtures: 採取用ダンプフックの後片付け"
# ══════════════════════════════════════════════

it "git ls-files に dump を名前に含む .sh が無い"
hits=""
while IFS= read -r f; do
  base="$(basename "$f")"
  case "$base" in
    *dump*.sh) hits="$hits $f" ;;
  esac
done < <(git ls-files)
assert_eq "$(echo "$hits" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "monitor-fixtures: 自己診断 — 個人情報検査ロジックの直接検証（JSON）"
# ══════════════════════════════════════════════
# check_no_leak 自体が「検査したつもりで何も検査していない」状態になっていないかを、
# 変異注入で確認する（lessons #5: 全部 PASS はテストが何も検査していなくても起きる）。

new_tmp_dir SELF_DIR

it "安全な値では個人情報検査が何も検出しない"
printf '%s' '{"cwd":"safe value","note":"no problem here"}' > "$SELF_DIR/clean.json"
hit="$(check_no_leak "$SELF_DIR/clean.json")"
assert_eq "$(echo "$hit" | tr -s ' ')" ""

it "/Users/ を含む値を検出する"
printf '%s' '{"cwd":"/Users/ghost/project"}' > "$SELF_DIR/leak-users.json"
hit="$(check_no_leak "$SELF_DIR/leak-users.json")"
case "$hit" in
  *"/Users/"*) pass ;;
  *) fail "検出されなかった: [${hit}]" ;;
esac

it "/home/ を含む値を検出する"
printf '%s' '{"cwd":"/home/ghost/project"}' > "$SELF_DIR/leak-home-dir.json"
hit="$(check_no_leak "$SELF_DIR/leak-home-dir.json")"
case "$hit" in
  *"/home/"*) pass ;;
  *) fail "検出されなかった: [${hit}]" ;;
esac

it "実行時の \$HOME の値を検出する"
printf '{"cwd":"%s/project"}' "$HOME" > "$SELF_DIR/leak-home.json"
hit="$(check_no_leak "$SELF_DIR/leak-home.json")"
case "$hit" in
  *"$HOME"*) pass ;;
  *) fail "検出されなかった: [${hit}]" ;;
esac

it "whoami の値を検出する"
ME="$(whoami)"
printf '{"user":"login:%s"}' "$ME" > "$SELF_DIR/leak-whoami.json"
hit="$(check_no_leak "$SELF_DIR/leak-whoami.json")"
case "$hit" in
  *"$ME"*) pass ;;
  *) fail "検出されなかった: [${hit}]" ;;
esac

it "値に埋め込まれた改行をまたいでも検出できる（grep の行単位判定が見逃す形）"
printf '%s' '{"note":"line1\n/Users/ghost/secret\nline3"}' > "$SELF_DIR/leak-multiline.json"
hit="$(check_no_leak "$SELF_DIR/leak-multiline.json")"
case "$hit" in
  *"/Users/"*) pass ;;
  *) fail "改行を挟んだ値の検出に失敗した: [${hit}]" ;;
esac

it "ネストした配列・オブジェクトの中の値も検査する"
printf '%s' '{"a":{"b":[{"c":"/Users/ghost/deep"}]}}' > "$SELF_DIR/leak-nested.json"
hit="$(check_no_leak "$SELF_DIR/leak-nested.json")"
case "$hit" in
  *"/Users/"*) pass ;;
  *) fail "ネストした値の検出に失敗した: [${hit}]" ;;
esac

# ══════════════════════════════════════════════
suite "monitor-fixtures: 自己診断 — 個人情報検査ロジックの直接検証（Markdown）"
# ══════════════════════════════════════════════
# check_no_leak_text（docs/*.md 用）が match_leak_patterns を正しく全文に対して
# 呼んでいるかを直接検証する。G4 で指摘された実例（hook-events.md の実測手順に
# 実ユーザー名入りの CLI パスを残した）の再発防止（lessons #11）。

it "安全な Markdown では個人情報検査が何も検出しない"
printf '# doc\n\n安全な文章。手順の説明のみ。\n' > "$SELF_DIR/clean-doc.md"
hit="$(check_no_leak_text "$SELF_DIR/clean-doc.md")"
assert_eq "$(echo "$hit" | tr -s ' ')" ""

it "md に /Users/ を含む行があれば検出される（1行目ではない後続行でも検出）"
printf '# doc\n\n前置きの安全な行。\n\nCLI パス: `/Users/ghost/.local/bin/claude --version` で確認\n' \
  > "$SELF_DIR/leak-doc.md"
hit="$(check_no_leak_text "$SELF_DIR/leak-doc.md")"
case "$hit" in
  *"/Users/"*) pass ;;
  *) fail "Markdown 内の /Users/ を検出できなかった: [${hit}]" ;;
esac

it "md に実行時の \$HOME を含む行があれば検出される"
printf '# doc\n\n測定コマンド: %s/.local/bin/claude --version\n' "$HOME" \
  > "$SELF_DIR/leak-doc-home.md"
hit="$(check_no_leak_text "$SELF_DIR/leak-doc-home.md")"
case "$hit" in
  *"$HOME"*) pass ;;
  *) fail "Markdown 内の \$HOME を検出できなかった: [${hit}]" ;;
esac

# ══════════════════════════════════════════════
suite "monitor-fixtures: 自己診断 — スキーマ部分集合チェックの直接検証"
# ══════════════════════════════════════════════

SCHEMA_SELF="$SELF_DIR/schema.md"
cat > "$SCHEMA_SELF" <<'DOC'
# ダミースキーマ（自己診断用）

前置きの文章。ここは読まれない。

<!-- SCHEMA:KEYS -->
- `hook_event_name`
- `session_id`
- `cwd`
<!-- /SCHEMA:KEYS -->

区画の外に書いたキーは読まれない:
- `should_not_be_read`
DOC

it "SCHEMA:KEYS 区画の外のキーは読み込まない"
keys="$(schema_keys "$SCHEMA_SELF")"
case "$keys" in
  *should_not_be_read*) fail "区画外のキーを読み込んでしまった" ;;
  *) pass ;;
esac

it "許可されたキーだけの emitted は部分集合チェックを通る"
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"s1"}' > "$SELF_DIR/emitted-ok.json"
extra="$(extra_keys "$SELF_DIR/emitted-ok.json" "$keys")"
assert_eq "$(echo "$extra" | tr -s ' ')" ""

it "スキーマ外のキーを持つ emitted は部分集合チェックで検出される"
printf '%s' '{"hook_event_name":"PreToolUse","not_in_schema":"x"}' > "$SELF_DIR/emitted-ng.json"
extra="$(extra_keys "$SELF_DIR/emitted-ng.json" "$keys")"
case "$extra" in
  *not_in_schema*) pass ;;
  *) fail "スキーマ外キーを検出できなかった: [${extra}]" ;;
esac

# ══════════════════════════════════════════════
suite "monitor-fixtures: 自己診断 — 正しい fixtures 一式は PASS、\$HOME 注入で FAIL"
# ══════════════════════════════════════════════
# 受け入れ条件の変異テストそのもの。正しい形の隔離コピーを1組作り、
# check_no_leak が「安全なら何も検出しない／$HOME を混ぜたら検出する」ことを固定する。

new_tmp_dir VALID_DIR
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"safe"}' \
  > "$VALID_DIR/valid-emitted.json"

it "自己診断: 正しい fixtures では個人情報検査が何も検出しない（PASS）"
hit="$(check_no_leak "$VALID_DIR/valid-emitted.json")"
assert_eq "$(echo "$hit" | tr -s ' ')" ""

new_tmp_dir MUTATED_DIR
printf '{"hook_event_name":"PreToolUse","session_id":"s1","cwd":"%s/leaked"}' "$HOME" \
  > "$MUTATED_DIR/mutated-emitted.json"

it "自己診断: \$HOME を注入した隔離コピーでは個人情報検査が FAIL する（検出できる）"
hit="$(check_no_leak "$MUTATED_DIR/mutated-emitted.json")"
if [ -n "$(echo "$hit" | tr -s ' ')" ]; then pass; else fail "\$HOME の混入を検出できなかった"; fi

report
