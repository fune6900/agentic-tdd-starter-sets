#!/bin/bash
# PreToolUse: 危険なコマンド実行前の警告表示
# exit 2 = ブロック（stderrがClaudeに表示される）
# exit 0 = 続行
#
# ── 設計 ──────────────────────────────────────────────────────────
#
# 以前はコマンド文字列**全体**を grep していたため、ヒアドキュメントやクォートに
# 危険コマンド名を書くだけでブロックされた。ドキュメント・テストコード・
# このフック自身の検知パターンの説明を書くことすらできなかった（Issue #9）。
#
# かといって「クォートされていれば安全」ではない。`psql -c "DROP TABLE x"` は
# シェルは実行しないが**データベースが実行する**。危険の主体はシェルとは限らない。
#
# そこでパターンを2種類に分け、それぞれ別の本文を走査する。
#
#   [shell] シェルが実行して初めて危険なもの（rm / git / chmod / mkfs / dd / fork bomb）
#           → 実行されえない部分を取り除いた本文を走査する
#             ・終端したヒアドキュメントの本文（ただし中身を実行しない消費側に限る）
#             ・シングルクォート文字列（展開が起きない）
#             ・$ とバッククォートを含まないダブルクォート文字列（展開の余地が無い）
#
#   [args]  引数として渡され、**別のプログラムが**実行するもの（SQL）
#           → クォートは取り除かない。代わりに、その別プログラムが
#             コマンドに登場するときだけ検査する
#
# **検知パターンは1つも減らしていない。** 取り除く対象を「シェルが実行しえない」
# ものに限り、かつ他プログラムが実行する経路は別枠で見ることで、緩めても穴を作らない。
#
# ── 既知の限界 ───────────────────────────────────────────────────
#
# ・`python3 - <<PY ... PY` のように**本文を実行する消費側**のヒアドキュメントは
#   本文も走査する。python の文字列リテラルに危険コマンド名を書くとブロックされる。
#   その場合はファイル経由で渡すか、編集ツールを使うこと
# ・SQL は既知のクライアント名（下記 DB_CLIENTS）が登場する場合にのみ検査する

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# ---------- ヒアドキュメント本文の除去 ----------
#
# 終端していない本文は**必ず残す**（捨てた部分を隠し場所にさせない）。
# 終端している本文は、渡される先（消費側）によって扱いを変える。
#
#   inert  … cat / tee / 単なるリダイレクト。本文は実行されない → 常に落とす
#   shell  … sh / bash / zsh / dash / ssh。本文はシェルとして実行される → 常に残す
#   other  … python / node / psql など。本文は別言語として実行される
#            → シェル系パターンの走査からは外す（`print("rm -rf x")` は
#              シェルコマンドではない）。引数系（SQL）の走査には残す
#
# 第1引数 shell: inert と other の本文を落とす
# 第1引数 args : inert の本文だけを落とす
strip_heredocs() {
  local mode="${1:-shell}"
  local line delim strip_tabs buf cmp found kind
  delim=""
  strip_tabs=0
  buf=""

  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$delim" ]; then
      cmp="$line"
      if [ "$strip_tabs" -eq 1 ]; then
        cmp="${cmp#"${cmp%%[![:space:]]*}"}"
      fi
      if [ "$cmp" = "$delim" ]; then
        delim=""
        buf=""
      else
        buf="$buf$line
"
      fi
      continue
    fi

    # 開始行そのものは走査対象に残す（そこに書かれたコマンドは実行される）
    printf '%s\n' "$line"

    case "$line" in
      *'<<'*)
        # 消費側を分類する。判定できないものは other（安全側）に寄せる
        # inert は「消費側が stdin を不透明なデータとしてしか扱わない」もの。
        # git commit -F - / gh ... --body-file - の本文は文章であってコードではない。
        case "$line" in
          *sh\ *|*sh$|*bash*|*zsh*|*dash*|*ssh*)          kind="shell" ;;
          *cat*|*tee*|*git\ commit*|*git\ tag*|*gh\ *)    kind="inert" ;;
          *)                                              kind="other" ;;
        esac

        # shell 消費側の本文は、どちらのモードでも残す
        if [ "$kind" != "shell" ] && { [ "$mode" = "shell" ] || [ "$kind" = "inert" ]; }; then
          found=$(printf '%s' "$line" \
            | sed -n "s/.*<<-\{0,1\}[[:space:]]*[\"']\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)[\"']\{0,1\}.*/\1/p")
          if [ -n "$found" ]; then
            delim="$found"
            case "$line" in
              *'<<-'*) strip_tabs=1 ;;
              *)       strip_tabs=0 ;;
            esac
          fi
        fi
        ;;
    esac
  done

  # 終端しなかった本文は捨てずに走査へ回す
  if [ -n "$buf" ]; then
    printf '%s' "$buf"
  fi
}

# ---------- 展開されないクォート文字列の除去 ----------
#
# シングルクォートは無条件。ダブルクォートは $ もバッククォートも含まない場合に限る
# （含むならコマンド置換・変数展開が起きうるので残す）。
strip_literals() {
  awk '
    { s = s $0 "\n" }
    END {
      n = length(s); i = 1; out = ""
      while (i <= n) {
        c = substr(s, i, 1)

        # バックスラッシュエスケープは次の1文字ごとそのまま通す
        if (c == "\\") {
          out = out c; i++
          if (i <= n) { out = out substr(s, i, 1); i++ }
          continue
        }

        # シングルクォート: 展開が起きないのでシェルは中身を実行しえない
        if (c == "\047") {
          j = index(substr(s, i + 1), "\047")
          if (j == 0) { out = out substr(s, i); break }   # 閉じていない → 残す
          out = out " "
          i = i + j + 1
          continue
        }

        # ダブルクォート: 展開の余地が無いときだけ落とす
        if (c == "\"") {
          k = i + 1; body = ""; closed = 0
          while (k <= n) {
            d = substr(s, k, 1)
            if (d == "\\") {
              body = body d; k++
              if (k <= n) { body = body substr(s, k, 1); k++ }
              continue
            }
            if (d == "\"") { closed = 1; break }
            body = body d; k++
          }
          if (closed == 0) { out = out substr(s, i); break }   # 閉じていない → 残す
          if (index(body, "$") == 0 && index(body, "`") == 0) {
            out = out " "
          } else {
            out = out "\"" body "\""
          }
          i = k + 1
          continue
        }

        out = out c; i++
      }
      printf "%s", out
    }
  '
}

# SQL の検査に使う本文。inert 消費側のヒアドキュメントだけを外し、クォートは残す
SCANNED_ARGS=$(printf '%s' "$COMMAND" | strip_heredocs args)
# シェル実行系の検査に使う本文。other 消費側の本文も外し、展開されないクォートも外す
SCANNED_SHELL=$(printf '%s' "$COMMAND" | strip_heredocs shell | strip_literals)

# ---------- シェルが実行して初めて危険なもの ----------
SHELL_PATTERNS=(
  "rm -rf"
  "rm -fr"
  "rm -Rf"
  "rm -fR"
  "rm -r /"
  "git push --force"
  "git push -f"
  "git reset --hard"
  "git clean -fd"
  "chmod -R 777"
  "> /dev/sda"
  "mkfs"
  "dd if="
  ":(){ :|:& };:"
)

# ---------- 別のプログラムが実行するもの ----------
# そのプログラムが登場する場合にのみ検査する。
# `echo 'DROP TABLE は禁止' > note.md` を止める必要は無い。
DB_CLIENTS="psql mysql mysqldump mariadb sqlite3 mongo mongosh cockroach duckdb clickhouse-client"
ARG_PATTERNS=(
  "DROP TABLE"
  "DROP DATABASE"
  "TRUNCATE"
)

block() { # <パターン>
  echo "⚠ 危険なコマンドを検知しました: $COMMAND" >&2
  echo "パターン: $1" >&2
  echo "このコマンドはブロックされました。メイド長の判断により実行を拒否します。" >&2
  exit 2
}

for pattern in "${SHELL_PATTERNS[@]}"; do
  if printf '%s' "$SCANNED_SHELL" | grep -Fqi -- "$pattern"; then
    block "$pattern"
  fi
done

for client in $DB_CLIENTS; do
  if printf '%s' "$SCANNED_ARGS" | grep -Fq -- "$client"; then
    for pattern in "${ARG_PATTERNS[@]}"; do
      if printf '%s' "$SCANNED_ARGS" | grep -Fqi -- "$pattern"; then
        block "$pattern"
      fi
    done
    break
  fi
done

exit 0
