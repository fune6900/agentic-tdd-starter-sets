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
LEAK_PATTERNS=("$HOME" "$(whoami)" "/Users/" "/home/")

match_leak_patterns() { # <text>
  local text="$1" pat leaked=""
  for pat in "${LEAK_PATTERNS[@]}"; do
    [ -n "$pat" ] || continue
    case "$text" in
      *"$pat"*) leaked="$leaked $pat" ;;
    esac
  done
  printf '%s' "$leaked"
}

# 全文字列値とオブジェクトのキー名（ともにネスト含む）から禁止パターンを検出する。見つかった分だけ
# スペース区切りで標準出力へ返す（空文字列なら安全）。
check_no_leak() { # <json path>
  local f="$1" value leaked=""
  while IFS= read -r -d '' value; do
    leaked="$leaked$(match_leak_patterns "$value")"
  done < <(jq -j '([.. | strings] + [.. | objects | keys[]])[] + "\u0000"' "$f" 2>/dev/null)
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

# stdin の Bash コマンド（tool_name が Bash の時の tool_input.command）を返す。無ければ空。
stdin_bash_command() { # <hook-stdin json path>
  jq -r 'select(.tool_name == "Bash") | .tool_input.command // empty' "$1" 2>/dev/null
}

# コマンドの先頭トークン以外の語（秘密値になりうるもの）を1行1語で返す。
command_rest_words() { # <command string>
  local -a words
  read -r -a words <<< "$1"
  local i
  for ((i = 1; i < ${#words[@]}; i++)); do
    printf '%s\n' "${words[$i]}"
  done
}

# 先頭トークンのベース名を返す（emitted.bash_command の期待値）。
command_first_basename() { # <command string>
  local -a words
  read -r -a words <<< "$1"
  [ "${#words[@]}" -ge 1 ] || return 0
  basename "${words[0]}"
}

# emitted の全文字列値（ネスト含む）のどれかに、stdin コマンドの先頭以外の語が現れれば
# その語をスペース区切りで返す（空文字列なら安全）。値は NUL 区切りで丸ごと判定する。
secret_words_in_emitted() { # <hook-stdin json path> <emitted json path>
  local stdin_f="$1" emitted_f="$2" cmd word value found=""
  cmd="$(stdin_bash_command "$stdin_f")"
  while IFS= read -r word; do
    [ -n "$word" ] || continue
    while IFS= read -r -d '' value; do
      case "$value" in
        *"$word"*) found="${found} ${word}"; break ;;
      esac
    done < <(jq -j '(.. | strings) + "\u0000"' "$emitted_f" 2>/dev/null)
  done < <(command_rest_words "$cmd")
  printf '%s' "$found"
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

# ══════════════════════════════════════════════
suite "monitor-fixtures: .claude/memory 配下の追跡 Markdown の個人情報検査"
# ══════════════════════════════════════════════
# 漏洩の行き先は monitor 配下だけではない（epics / journal / lessons にも実パスは書ける）。
# git ls-files で追跡対象を拾い、ファイル全文を判定する。失敗時は行番号のみ報告する
# （値は報告に載せない）。

while IFS= read -r f; do
  case "$f" in *.md) ;; *) continue ;; esac
  it "${f} に個人情報が残っていない（ファイル全文判定）"
  hit="$(check_no_leak_text "$REPO_ROOT/$f")"
  if [ -z "$(echo "$hit" | tr -s ' ')" ]; then
    pass
  else
    lines=""
    for pat in "${LEAK_PATTERNS[@]}"; do
      [ -n "$pat" ] || continue
      lines="${lines} $(grep -n -F -- "$pat" "$REPO_ROOT/$f" | cut -d: -f1 | tr '\n' ',')"
    done
    fail "${f} の行:${lines}"
  fi
done < <(git ls-files .claude/memory)

# ══════════════════════════════════════════════
suite "monitor-fixtures: 秘密値が emitted に出ない（stdin/emitted のペア）"
# ══════════════════════════════════════════════

for stdin_f in "$HOOK_STDIN_DIR"/*.json; do
  [ -e "$stdin_f" ] || continue
  name="$(basename "$stdin_f")"
  emitted_f="$EMITTED_DIR/$name"
  [ -e "$emitted_f" ] || continue
  cmd="$(stdin_bash_command "$stdin_f")"
  [ -n "$cmd" ] || continue

  it "emitted/${name} に stdin コマンドの先頭以外の語が現れない"
  assert_eq "$(secret_words_in_emitted "$stdin_f" "$emitted_f" | tr -s ' ')" ""

  it "emitted/${name} の bash_command が stdin コマンドの先頭トークンのベース名と一致する"
  assert_eq "$(jq -r '.bash_command // empty' "$emitted_f" 2>/dev/null)" "$(command_first_basename "$cmd")"
done

# ══════════════════════════════════════════════
suite "monitor-fixtures: 自己診断 — キー名の漏洩と秘密値の混入"
# ══════════════════════════════════════════════

new_tmp_dir KEY_DIR
printf '%s' '{"schema_version":1,"usage":{"safe_key":1}}' > "$KEY_DIR/clean-key.json"
printf '{"schema_version":1,"usage":{"%s/x":1}}' "$HOME" > "$KEY_DIR/leak-key.json"

it "自己診断: 安全なキー名のみの fixture は check_no_leak が何も検出しない"
assert_eq "$(check_no_leak "$KEY_DIR/clean-key.json" | tr -s ' ')" ""

it "自己診断: ネストしたキー名に \$HOME を注入した fixture は check_no_leak が FAIL する"
hit="$(check_no_leak "$KEY_DIR/leak-key.json")"
if [ -n "$(echo "$hit" | tr -s ' ')" ]; then pass; else fail "キー名の \$HOME 混入を検出できなかった"; fi

SECRET_STDIN="$HOOK_STDIN_DIR/PreToolUse.bash-envexport.json"
SECRET_EMITTED="$EMITTED_DIR/PreToolUse.bash-envexport.json"
new_tmp_dir SECRET_DIR

it "自己診断: 正しい emitted では秘密値検査が何も検出しない"
assert_eq "$(secret_words_in_emitted "$SECRET_STDIN" "$SECRET_EMITTED" | tr -s ' ')" ""

it "自己診断: stdin の秘密値を emitted に注入すると秘密値検査が FAIL する"
secret_word="$(command_rest_words "$(stdin_bash_command "$SECRET_STDIN")" | head -n 1)"
jq --arg s "$secret_word" '.bash_command = $s' "$SECRET_EMITTED" > "$SECRET_DIR/mutated.json"
hit="$(secret_words_in_emitted "$SECRET_STDIN" "$SECRET_DIR/mutated.json")"
if [ -n "$(echo "$hit" | tr -s ' ')" ]; then pass; else fail "秘密値の混入を検出できなかった"; fi

it "自己診断: 秘密値を埋め込んだ値（他の文字列に部分一致）でも検出する"
jq --arg s "prefix-${secret_word}-suffix" '.file_path = $s' "$SECRET_EMITTED" > "$SECRET_DIR/mutated2.json"
hit="$(secret_words_in_emitted "$SECRET_STDIN" "$SECRET_DIR/mutated2.json")"
if [ -n "$(echo "$hit" | tr -s ' ')" ]; then pass; else fail "部分一致の秘密値を検出できなかった"; fi

# ══════════════════════════════════════════════
suite "monitor-fixtures: UsageSnapshot の emitted と transcript fixture（Issue #23）"
# ══════════════════════════════════════════════
# 仕様の正: event-schema.md「UsageSnapshot」。emitted の期待値は transcript から
# 独立の jq（参照実装）で再計算して突き合わせる。手書きの期待値だけに頼ると、
# fixture と仕様がずれても気付けない。

TRANSCRIPT_DIR="$MONITOR_DIR/test/fixtures/transcript"
SNAP_MAIN="$EMITTED_DIR/UsageSnapshot.main-ok.json"
SNAP_SUB="$EMITTED_DIR/UsageSnapshot.sub-ok.json"
SNAP_UNK="$EMITTED_DIR/UsageSnapshot.unknown.json"

# 仕様の集計規則 1〜9 を素直に書いた参照実装（transcript の jsonl を stdin から読む）
ref_aggregate() {
  jq -R -s -c '
    def isint: type == "number" and . == floor and . >= 0;
    def n(k): (.[k] // 0);
    [ split("\n")[] | select(test("^\\s*$") | not) | fromjson
      | select(.type == "assistant")
      | select((.message | type) == "object" and (.message.usage | type) == "object")
      | select((.message.id | type) == "string" and .message.id != "") ]
    | group_by(.message.id) | map(.[-1].message)
    | map(select((.usage | n("input_tokens")) + (.usage | n("output_tokens"))
                 + (.usage | n("cache_creation_input_tokens")) + (.usage | n("cache_read_input_tokens")) > 0))
    | group_by(.model) | map(
        . as $ms
        | { model: $ms[0].model, message_count: ($ms | length),
            input_tokens: ([$ms[].usage | n("input_tokens")] | add),
            output_tokens: ([$ms[].usage | n("output_tokens")] | add),
            cache_creation_5m_input_tokens: ([$ms[].usage | (.cache_creation.ephemeral_5m_input_tokens // n("cache_creation_input_tokens"))] | add),
            cache_creation_1h_input_tokens: ([$ms[].usage | (.cache_creation.ephemeral_1h_input_tokens // 0)] | add),
            cache_read_input_tokens: ([$ms[].usage | n("cache_read_input_tokens")] | add),
            fast_mode: ([$ms[].usage.speed == "fast"] | any),
            us_inference: ([$ms[].usage.inference_geo == "us"] | any),
            variant_unknown: false,
            cache_split_unknown: false })
    | sort_by(.model)'
}

it "transcript/main.jsonl と sub.jsonl が存在する"
if [ -f "$TRANSCRIPT_DIR/main.jsonl" ] && [ -f "$TRANSCRIPT_DIR/sub.jsonl" ]; then pass; else fail "無い: $TRANSCRIPT_DIR"; fi

for t in main sub; do
  tf="$TRANSCRIPT_DIR/${t}.jsonl"
  it "transcript/${t}.jsonl に個人情報が残っていない（ファイル全文判定）"
  assert_eq "$(check_no_leak_text "$tf" | tr -s ' ')" ""

  it "transcript/${t}.jsonl は空行以外の全行が JSON として読める"
  bad=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *[![:space:]]*) printf '%s' "$line" | jq -e . >/dev/null 2>&1 || bad=$((bad + 1)) ;;
    esac
  done <"$tf"
  assert_eq "$bad" "0"

  it "transcript/${t}.jsonl は番兵（SNT）を含む（漏洩検査が空振りしないための前提）"
  assert_file_contains "$tf" "SNT"
done

it "transcript/main.jsonl は重複 id・全 0 の行・usage 無し・空白のみの行・assistant 以外の行を含む（集計規則の網羅）"
mt="$TRANSCRIPT_DIR/main.jsonl"
dup="$(jq -R -s -r '[split("\n")[] | select(test("^\\s*$")|not) | fromjson | select(.type=="assistant") | .message.id] | group_by(.) | map(select(length>1)) | length' "$mt")"
blank="$(grep -c '^[[:space:]]\+$' "$mt")"
zero="$(grep -c '"<synthetic>"' "$mt")"
other="$(grep -c '"type":"cost-state"' "$mt")"
nousage="$(grep -c 'SNTNOUSAGE' "$mt")"
if [ -n "$dup" ] && [ "$dup" -ge 1 ] && [ "$blank" -ge 1 ] && [ "$zero" -ge 1 ] && [ "$other" -ge 1 ] && [ "$nousage" -ge 1 ]; then pass
else fail "dup=${dup} blank=${blank} synthetic=${zero} cost-state=${other} nousage=${nousage}"; fi

it "transcript/main.jsonl は同じ id で usage が違う行（最後を採る規則）を含む"
diffid="$(jq -R -s -r '[split("\n")[] | select(test("^\\s*$")|not) | fromjson | select(.type=="assistant" and .message.usage != null) | {id:.message.id, u:.message.usage}] | group_by(.id) | map(select((map(.u)|unique|length)>1)) | length' "$mt")"
if [ -n "$diffid" ] && [ "$diffid" -ge 1 ]; then pass; else fail "usage が食い違う同一 id が無い"; fi

for pair in "main:$SNAP_MAIN" "sub:$SNAP_SUB"; do
  t="${pair%%:*}"; sf="${pair#*:}"
  it "emitted/$(basename "$sf") は transcript/${t}.jsonl を参照実装で集計した結果と一致する"
  assert_eq "$(jq -S -c '.models' "$sf" 2>/dev/null)" "$(ref_aggregate <"$TRANSCRIPT_DIR/${t}.jsonl" | jq -S -c .)"
done

it "自己診断: models の数値を 1 変えた emitted は参照実装との突き合わせで FAIL する"
new_tmp_dir SNAP_SELF
jq '.models[0].output_tokens += 1' "$SNAP_MAIN" >"$SNAP_SELF/m.json"
if [ "$(jq -S -c '.models' "$SNAP_SELF/m.json")" = "$(ref_aggregate <"$TRANSCRIPT_DIR/main.jsonl" | jq -S -c .)" ]; then
  fail "変異を検出できなかった"
else pass; fi

# 形の検査（受信側の検証と同じ規則を別実装で）
snap_shape_problems() { # <path> → 問題の説明（空なら適合）
  jq -r '
    def isint: type == "number" and . == floor and . >= 0;
    def mkeys: ["model","message_count","input_tokens","output_tokens","cache_creation_5m_input_tokens","cache_creation_1h_input_tokens","cache_read_input_tokens","fast_mode","us_inference","variant_unknown","cache_split_unknown"];
    def reasons: ["no_path","symlink","not_regular_file","too_large","read_failed","parse_failed","invalid_usage","too_many_models","out_of_range"];
    [
      (if .schema_version != 2 then "schema_version" else empty end),
      (if .event != "UsageSnapshot" then "event" else empty end),
      (if (.session_id | type) != "string" then "session_id" else empty end),
      (if (.usage_status | IN("ok","unknown") | not) then "usage_status" else empty end),
      (if .usage_status == "ok" then
         ( (if has("unknown_reason") then "ok_with_reason" else empty end),
           (if (.models | type) != "array" then "models_missing"
            else
              ( (if (.models | length) > 8 then "too_many" else empty end),
                (if ([.models[].model] | . != (sort | unique)) then "models_not_sorted_unique" else empty end),
                (.models[] | (if (keys | sort) != (mkeys | sort) then "element_keys" else empty end),
                             (if (.model | type) != "string" or (.model | test("^[A-Za-z0-9._-]{1,64}$") | not) then "model_id" else empty end),
                             (if ([.message_count, .input_tokens, .output_tokens, .cache_creation_5m_input_tokens, .cache_creation_1h_input_tokens, .cache_read_input_tokens] | all(isint) | not) then "int" else empty end),
                             (if ([.fast_mode, .us_inference, .variant_unknown, .cache_split_unknown] | all(type == "boolean") | not) then "bool" else empty end)) )
            end) )
       else
         ( (if has("models") then "unknown_with_models" else empty end),
           (if (.unknown_reason | IN(reasons[]) | not) then "unknown_reason" else empty end) )
       end)
    ] | join(",")' "$1" 2>/dev/null
}

for sf in "$SNAP_MAIN" "$SNAP_SUB" "$SNAP_UNK"; do
  it "emitted/$(basename "$sf") は仕様どおりの形（schema_version 2・ok/unknown の排他・models の要素）"
  assert_eq "$(snap_shape_problems "$sf")" ""

  it "emitted/$(basename "$sf") に番兵（SNT）が現れない"
  assert_file_not_contains "$sf" "SNT"

  it "emitted/$(basename "$sf") に '/' が現れない（パス混入なし）"
  case "$(cat "$sf")" in */*) fail "'/' がある" ;; *) pass ;; esac
done

it "自己診断: ok なのに unknown_reason を持つ emitted は形の検査で FAIL する"
jq '.unknown_reason = "too_large"' "$SNAP_MAIN" >"$SNAP_SELF/bad1.json"
if [ -n "$(snap_shape_problems "$SNAP_SELF/bad1.json")" ]; then pass; else fail "検出できなかった"; fi

it "自己診断: unknown なのに models を持つ emitted は形の検査で FAIL する"
jq '.models = []' "$SNAP_UNK" >"$SNAP_SELF/bad2.json"
if [ -n "$(snap_shape_problems "$SNAP_SELF/bad2.json")" ]; then pass; else fail "検出できなかった"; fi

it "UsageSnapshot.main-ok は agent_id を持たず、sub-ok は agent_id を持つ（帰属）"
assert_eq "$(jq -r 'has("agent_id")' "$SNAP_MAIN"),$(jq -r '.agent_id // ""' "$SNAP_SUB")" "false,aaaaaaaaaaaaaaaaa"

it "UsageSnapshot の session_id は hook-stdin/Stop.json と一致する（フックが stdin の値を使う前提）"
assert_eq "$(jq -r '.session_id' "$SNAP_MAIN")" "$(jq -r '.session_id' "$HOOK_STDIN_DIR/Stop.json")"

it "旧形式の emitted/Stop.with-usage.json と SubagentStop.with-usage.json が残っていない（UsageSnapshot に置換済み）"
if [ -e "$EMITTED_DIR/Stop.with-usage.json" ] || [ -e "$EMITTED_DIR/SubagentStop.with-usage.json" ]; then fail "旧 fixture が残っている"; else pass; fi

report
