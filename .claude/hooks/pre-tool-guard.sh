#!/bin/bash
# PreToolUse: 危険なコマンド実行前の警告表示
# exit 2 = ブロック（stderrがClaudeに表示される）
# exit 0 = 続行
#
# ── 設計 ──────────────────────────────────────────────────────────
#
# 以前はコマンド文字列**全体**を grep していたため、ヒアドキュメントやクォートに
# 危険コマンド名を書くだけでブロックされた（Issue #9）。
#
# かといって「クォートされていれば安全」ではない。危険の主体はシェルとは限らない。
#
#   sh -c "rm -rf /"      … 展開は起きないが**別のシェルが実行する**
#   psql -c "DROP TABLE x" … シェルは実行しないが**データベースが実行する**
#
# そこで「その文字列を**誰が実行するか**」を基準に、取り除いてよい部分を決める。
#
#   [shell] シェルが実行して初めて危険なもの（rm / git / chmod / mkfs / dd / fork bomb）
#   [args]  別のプログラムが実行するもの（SQL）
#
# ── 取り除く条件 ─────────────────────────────────────────────────
#
# クォート文字列:
#   コマンド中に**別のシェルを起動する語**（sh / bash / zsh / dash / ksh / ssh /
#   eval / source / .）が1つでもあれば、クォートは一切取り除かない。
#   その引数は別のシェルがそのまま実行しうるからだ。
#   無ければ、シングルクォートと「$ もバッククォートも含まないダブルクォート」を取り除く。
#   ただし $'...'（ANSI-C クォート）は $ 付きなので残す。
#
# ヒアドキュメント本文（終端しているものだけ。終端しない本文は隠し場所にさせない）:
#   inert … cat / tee / git commit / git tag / gh。stdin を不透明なデータとしか扱わない
#   shell … 上記のシェル起動語。本文がシェルとして実行される → 常に残す
#   other … python / node / psql など。別言語として実行される
#           → shell 系の走査からのみ外す（`print("rm -rf x")` はシェルコマンドではない）
#   args モードでは、行に DB クライアントが登場すれば inert 判定を無効化する
#
# **分類は語として判定する。** 部分文字列で見ると `psql -d catalog` の `cat` に
# 引っかかり、止まるかどうかがデータベース名の綴りで決まる。それは歯止めではない。
#
# ── 既知の限界 ───────────────────────────────────────────────────
#
# ・`cat <<EOF > run.sh` で危険コマンドを書き、次のターンで `bash run.sh` する
#   二段実行は止められない（どちらのターンも単体では危険に見えない）
# ・SQL は既知のクライアント名が登場する場合にのみ検査する
# ・`python3 - <<PY` の本文が os.system 経由でシェルを呼ぶ場合、shell 系の走査から外れる
# ・64KB を超えるコマンドは取り除きを行わず生のまま走査する（誤爆側に倒す）
# ・このガードは**事故を防ぐ速度制限**であり、悪意ある操作に対する境界ではない

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# 語境界つきの判定。前後がコマンド名の一部になりうる文字なら一致させない。
WORD_L='(^|[^A-Za-z0-9_./-])'
WORD_R='([^A-Za-z0-9_-]|$)'

SHELL_INVOKERS='sh|bash|zsh|dash|ksh|ssh|eval|source'
INERT_CONSUMERS='cat|tee'
DB_CLIENTS='psql|mysql|mysqldump|mariadb|sqlite3|mongo|mongosh|cockroach|duckdb|clickhouse-client'

has_shell_invoker() { # <テキスト>
  printf '%s' "$1" | grep -Eq "${WORD_L}(${SHELL_INVOKERS})${WORD_R}" && return 0
  # `. script` 形式の読み込み（コマンド位置のドット）
  printf '%s' "$1" | grep -Eq '(^|[;&|(]|&&|\|\|)[[:space:]]*\.[[:space:]]' && return 0
  return 1
}

has_db_client() { # <テキスト>
  printf '%s' "$1" | grep -Eq "${WORD_L}(${DB_CLIENTS})${WORD_R}"
}

classify_consumer() { # <行> <モード>
  local line="$1" mode="$2"
  if has_shell_invoker "$line"; then
    printf 'shell\n'; return
  fi
  # args モードでは DB クライアントがいる行を inert にしない
  if [ "$mode" = "args" ] && has_db_client "$line"; then
    printf 'other\n'; return
  fi
  if printf '%s' "$line" | grep -Eq "${WORD_L}(${INERT_CONSUMERS})${WORD_R}" \
     || printf '%s' "$line" | grep -Eq "git[[:space:]]+(commit|tag)${WORD_R}" \
     || printf '%s' "$line" | grep -Eq "${WORD_L}gh${WORD_R}"; then
    printf 'inert\n'; return
  fi
  printf 'other\n'
}

# 行内の**最初の** << からヒアドキュメントの区切り文字を取り出す。
# 貪欲マッチだと行内の別の << に乗っ取られ、本来の終端を越えて
# 後続のコマンドまで本文として捨てられる。
extract_heredoc() { # <行> → "<タブ除去フラグ> <区切り文字>"
  printf '%s' "$1" | awk '
    {
      n = length($0)
      for (i = 1; i < n; i++) {
        if (substr($0, i, 2) != "<<") continue
        if (substr($0, i, 3) == "<<<") { i += 2; continue }
        rest = substr($0, i + 2)
        tabs = 0
        if (substr(rest, 1, 1) == "-") { tabs = 1; rest = substr(rest, 2) }
        sub(/^[[:space:]]+/, "", rest)
        sub(/^["\047]/, "", rest)
        if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) {
          printf "%d %s\n", tabs, substr(rest, 1, RLENGTH)
        }
        exit
      }
    }'
}

strip_heredocs() { # <モード: shell|args>
  local mode="${1:-shell}"
  local line delim strip_tabs buf cmp kind spec
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
        kind="$(classify_consumer "$line" "$mode")"
        # shell 消費側の本文はどちらのモードでも残す。
        # other の本文は shell モードでのみ外す（別言語のコードはシェルではない）。
        if [ "$kind" != "shell" ] && { [ "$mode" = "shell" ] || [ "$kind" = "inert" ]; }; then
          spec="$(extract_heredoc "$line")"
          if [ -n "$spec" ]; then
            strip_tabs="${spec%% *}"
            delim="${spec#* }"
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

# 展開されないクォート文字列を取り除く。
strip_literals() {
  awk '
    # **文字列を積まない。** awk の連結は毎回バッファ全体をコピーするので、
    # 1文字ずつ積むと二乗オーダーになる。実行時間が跳ねればフックはタイムアウトで死ぬ＝
    # 素通りする。無害な文字列で埋めるだけで検知を無効化できてしまう。
    # そこで位置だけ持ち回り、確定した区間を substr で一度に書き出す。
    # 連結するのは行をまたぐクォートの繰り越し（qbuf）だけで、これは行数ぶんしか起きない。
    BEGIN { mode = 0; qbuf = ""; qstart = 0; dqx = 0; sqd = 0 }
    {
      line = $0; n = length(line); i = 1; pstart = 1
      if (mode != 0) qstart = 1   # 行をまたいだクォートは行頭から数え直す

      while (i <= n) {
        c = substr(line, i, 1)

        if (mode == 0) {
          # エスケープされた文字はそのまま出力に残るので素の区間に含めてよい
          if (c == "\\") { i += 2; continue }
          if (c == "\047") {
            printf "%s", substr(line, pstart, i - pstart)
            # 直前が $ なら ANSI-C クォート。$ 付きなので残す
            sqd = (i > 1 && substr(line, i - 1, 1) == "$") ? 1 : 0
            mode = 1; qstart = i; qbuf = ""; i++; continue
          }
          if (c == "\"") {
            printf "%s", substr(line, pstart, i - pstart)
            mode = 2; dqx = 0; qstart = i; qbuf = ""; i++; continue
          }
          i++; continue
        }

        if (mode == 1) {
          if (c == "\047") {
            printf "%s", (sqd ? (qbuf substr(line, qstart, i - qstart + 1)) : " ")
            mode = 0; qbuf = ""; pstart = i + 1; i++; continue
          }
          i++; continue
        }

        # mode == 2（ダブルクォート）
        if (c == "\\") { i += 2; continue }
        if (c == "\"") {
          printf "%s", (dqx ? (qbuf substr(line, qstart, i - qstart + 1)) : " ")
          mode = 0; qbuf = ""; pstart = i + 1; i++; continue
        }
        if (c == "$" || c == "`") { dqx = 1 }
        i++; continue
      }

      if (mode == 0) { printf "%s\n", substr(line, pstart) }
      else { qbuf = qbuf substr(line, qstart) "\n" }
    }
    # 閉じないクォートは残す（除去した部分を隠し場所にさせない）
    END { if (mode != 0) { printf "%s", qbuf } }
  '
}

# 前処理（取り除き）を行う上限。超えたら**取り除きを一切せず生のまま**走査する。
# 前処理は入力長に対して厳密には線形でない。巨大な入力を投げれば実行時間が跳ね、
# タイムアウト＝フェイルオープンになる。そこを無害な文字列で埋めるだけの
# 検知無効化に使わせない。上限超過時の挙動は Issue #9 以前と同じ厳しさ＝
# **誤爆は増えるが検知漏れは増えない**側に倒れる。
MAX_PREPROCESS_LEN=65536

if [ "${#COMMAND}" -gt "$MAX_PREPROCESS_LEN" ]; then
  SCANNED_ARGS="$COMMAND"
  SCANNED_SHELL="$COMMAND"
else
  # SQL の検査に使う本文。inert 消費側のヒアドキュメントだけを外し、クォートは残す
  SCANNED_ARGS=$(printf '%s' "$COMMAND" | strip_heredocs args)

  # シェル実行系の検査に使う本文。
  # **別のシェルを起動する語があれば、クォートは一切取り除かない。**
  # その引数は展開が起きなくても別のシェルがそのまま実行しうる。
  if has_shell_invoker "$COMMAND"; then
    SCANNED_SHELL=$(printf '%s' "$COMMAND" | strip_heredocs shell)
  else
    SCANNED_SHELL=$(printf '%s' "$COMMAND" | strip_heredocs shell | strip_literals)
  fi
fi

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

if has_db_client "$SCANNED_ARGS"; then
  for pattern in "${ARG_PATTERNS[@]}"; do
    if printf '%s' "$SCANNED_ARGS" | grep -Fqi -- "$pattern"; then
      block "$pattern"
    fi
  done
fi

exit 0
