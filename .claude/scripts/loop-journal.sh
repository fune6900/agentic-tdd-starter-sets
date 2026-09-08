#!/usr/bin/env bash
# 2層外部記憶 — インナーループの記録をプロジェクト内に貯め、アウターループ完了時に Obsidian Vault へ書き写す
#
# 内部（Git 管理）  .claude/memory/journal/<epic-slug>.md
#     インナーループの節目（着手・実装完了・ゲート一巡・完了/停止）を逐次追記する。
#     別端末・別作業者から続きを引き継げるようコミットする。フラッシュ後に削除される。
#
# 外部（Obsidian Vault）  <VAULT>/projects/<project>.md
#     アウターループの節目と、完了したエピックの全記録。追記専用の永続ログ。
#
# 使い方:
#   loop-journal.sh init [vault-path]        Vault を接続する（未指定なら自動検出）
#   loop-journal.sh context [epic-slug]      ★新規タスクの最初の行動。読むべき記録を出力する
#   loop-journal.sh start <epic-slug> [題名] エピック開始。内部ジャーナルを作る
#   loop-journal.sh inner <issue> <phase> [題名]   インナー節目を内部ジャーナルへ追記（本文は stdin）
#                                            phase: start | impl | gates | done | halt
#   loop-journal.sh outer <phase> [題名]     アウター節目を Vault へ直接追記（本文は stdin）
#                                            phase: plan | approve | integrate | note
#   loop-journal.sh flush [epic-slug]        内部ジャーナルを Vault へ書き写して削除（本文は stdin）
#   loop-journal.sh status                   接続状態・進行中エピック・記録量を表示
#   loop-journal.sh where                    解決した各パスを表示
#
# 環境変数:
#   LOOP_VAULT_DIR       Vault のルート（.vault ポインタより優先）
#   LOOP_PROJECT_NAME    Vault 側のファイル名（既定: リポジトリ名）
#   LOOP_EPIC            エピック slug の明示指定
#   LOOP_CONTEXT_EPICS   context で遡る Vault のエピック数（既定 2）

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
JOURNAL_DIR="$PROJECT_DIR/.claude/memory/journal"
VAULT_PTR="$JOURNAL_DIR/.vault"
ACTIVE_PTR="$JOURNAL_DIR/.active"
PROJECT_PTR="$JOURNAL_DIR/.project"
STATE_FILE="$PROJECT_DIR/.claude/memory/loop-state.json"
ENTRY_MARKER="<!-- LOOP-JOURNAL:ENTRIES -->"

now_iso() { date -u +%Y-%m-%dT%H:%MZ; }
today() { date +%Y-%m-%d; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- 解決 ----------

project_name() {
  if [ -n "${LOOP_PROJECT_NAME:-}" ]; then echo "$LOOP_PROJECT_NAME"; return 0; fi
  if [ -s "$PROJECT_PTR" ]; then head -1 "$PROJECT_PTR"; return 0; fi
  basename "$PROJECT_DIR"
}

vault_dir() {
  local v="${LOOP_VAULT_DIR:-}"
  if [ -z "$v" ] && [ -s "$VAULT_PTR" ]; then v="$(head -1 "$VAULT_PTR")"; fi
  [ -n "$v" ] || return 1
  echo "$v"
}

vault_file() {
  local v
  v="$(vault_dir)" || return 1
  echo "$v/projects/$(project_name).md"
}

journal_file() { echo "$JOURNAL_DIR/$1.md"; }

# エピック slug の解決順: 引数 → $LOOP_EPIC → loop-state.json → .active → ブランチ epic/<slug> → 唯一のジャーナル
resolve_epic() {
  local given="${1:-}"
  [ -n "$given" ] && { echo "$given"; return 0; }
  [ -n "${LOOP_EPIC:-}" ] && { echo "$LOOP_EPIC"; return 0; }

  if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
    local e
    e="$(jq -r '.epic // empty' "$STATE_FILE" 2>/dev/null)"
    [ -n "$e" ] && { echo "$e"; return 0; }
  fi

  [ -s "$ACTIVE_PTR" ] && { head -1 "$ACTIVE_PTR"; return 0; }

  local branch
  branch="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)"
  case "$branch" in
    epic/*) echo "${branch#epic/}"; return 0 ;;
  esac

  local files count
  files="$(find "$JOURNAL_DIR" -maxdepth 1 -name '*.md' ! -name 'README.md' 2>/dev/null)"
  count="$(printf '%s\n' "$files" | grep -c . )"
  if [ "$count" -eq 1 ]; then
    basename "$(printf '%s\n' "$files")" .md
    return 0
  fi

  return 1
}

# ---------- init ----------

detect_vault() {
  find "$HOME" -maxdepth 5 -type d -name ".obsidian" 2>/dev/null | sed 's#/\.obsidian$##'
}

cmd_init() {
  local vault="${1:-${LOOP_VAULT_DIR:-}}"

  if [ -z "$vault" ]; then
    local found count
    found="$(detect_vault)"
    count="$(printf '%s\n' "$found" | grep -c . )"
    if [ "$count" -eq 1 ]; then
      vault="$found"
      echo "Vault を自動検出した: $vault"
    elif [ "$count" -eq 0 ]; then
      die "Vault が見つからない。パスを明示しろ: loop-journal.sh init <vault-path>"
    else
      echo "Vault の候補が複数ある。どれか1つを引数で指定しろ:" >&2
      printf '%s\n' "$found" >&2
      exit 1
    fi
  fi

  [ -d "$vault" ] || die "Vault のディレクトリが存在しない: $vault"

  mkdir -p "$vault/projects" "$JOURNAL_DIR"
  local name file
  name="$(project_name)"
  file="$vault/projects/$name.md"

  if [ ! -f "$file" ]; then
    local remote
    remote="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || echo '')"
    cat > "$file" <<EOF
---
type: project-log
title: "$name"
project: $name
repo: "$remote"
tags: [project-log, loop-engineering]
created: $(today)
updated: $(today)
---

# $name — 開発記録

> ループエンジニアリングの外部記憶。\`.claude/scripts/loop-journal.sh\` が**追記のみ**行う。
> インナーループの記録はプロジェクト内 \`.claude/memory/journal/\` に貯まり、
> アウターループ完了時にここへ丸ごと書き写される。
>
> 手編集してよいが、\`## <日付> / epic: <slug>\` の見出し階層は壊さないこと。
> 恒久的な教訓はリポジトリ側の \`.claude/memory/lessons.md\` が正典。ここは経緯の記録。

$ENTRY_MARKER
EOF
    echo "Vault にプロジェクトファイルを作成した: $file"
  else
    echo "既存のプロジェクトファイルを再利用する: $file"
  fi

  printf '%s\n' "$vault" > "$VAULT_PTR"
  echo "Vault を接続した: $vault"
  echo "（接続情報は $VAULT_PTR に保存した。端末ごとの設定なので Git には乗せない）"
}

# ---------- context（新規タスクの最初の行動） ----------

cmd_context() {
  local epic jf vf
  epic="$(resolve_epic "${1:-}")" || epic=""

  if [ -n "$epic" ]; then
    jf="$(journal_file "$epic")"
    if [ -f "$jf" ]; then
      cat <<EOF
════════════════════════════════════════════════
 読み取り元: プロジェクト内部ジャーナル（進行中のエピック）
 エピック: $epic
 ファイル: $jf
════════════════════════════════════════════════
EOF
      cat "$jf"
      echo
      echo "──── ここまでが前回までの経緯。続きから始めろ。 ────"
      return 0
    fi
  fi

  if vf="$(vault_file)" && [ -f "$vf" ]; then
    local n="${LOOP_CONTEXT_EPICS:-2}"
    cat <<EOF
════════════════════════════════════════════════
 読み取り元: 外部 Obsidian Vault（新規エピックの開始）
 ファイル: $vf
 表示: 直近 $n エピック分
════════════════════════════════════════════════
EOF
    awk -v n="$n" '
      { line[NR] = $0 }
      /^## / { c++; idx[c] = NR }
      END {
        start = (c > n) ? idx[c - n + 1] : 1
        for (i = start; i <= NR; i++) print line[i]
      }
    ' "$vf"
    echo
    echo "──── ここまでが過去エピックの記録。新しいエピックを始めろ。 ────"
    return 0
  fi

  echo "記録なし。Vault 未接続、または内部ジャーナルが空だ。"
  echo "Vault を繋ぐ: bash .claude/scripts/loop-journal.sh init <vault-path>"
  return 0
}

# ---------- start ----------

cmd_start() {
  local epic="${1:-}" title="${2:-}"
  [ -n "$epic" ] || die "エピック slug を指定しろ。"
  mkdir -p "$JOURNAL_DIR"
  local jf
  jf="$(journal_file "$epic")"

  if [ ! -f "$jf" ]; then
    cat > "$jf" <<EOF
---
epic: $epic
title: "${title:-$epic}"
started: $(today)
status: active
---

# インナーループ記録: $epic

> **このファイルはアウターループ完了時に Vault へ書き写され、削除される。**
> 恒久的な教訓は \`.claude/memory/lessons.md\` に書け。ここは「何をやって、なぜそうしたか」の経緯。
> 別端末・別作業者が続きを引き継ぐための記録なので、必ずコミットする。

$ENTRY_MARKER
EOF
    echo "内部ジャーナルを作成した: $jf"
  else
    echo "既存の内部ジャーナルを再利用する: $jf"
  fi

  printf '%s\n' "$epic" > "$ACTIVE_PTR"
  echo "進行中エピック: $epic"
}

# ---------- 追記 ----------

read_body() {
  local body
  body="$(cat)"
  [ -n "$body" ] || die "本文が空だ。標準入力で「やったこと」と「なぜ」を渡せ。"
  printf '%s\n' "$body"
}

cmd_inner() {
  local issue="${1:-}" phase="${2:-}" title="${3:-}"
  [ -n "$issue" ] || die "Issue 番号を指定しろ。"
  case "$phase" in
    start|impl|gates|done|halt) ;;
    *) die "phase は start / impl / gates / done / halt のいずれか。指定値: '${phase:-空}'" ;;
  esac

  local epic jf body
  epic="$(resolve_epic)" || die "エピックが特定できない。'loop-journal.sh start <epic-slug>' を先に実行しろ。"
  jf="$(journal_file "$epic")"
  [ -f "$jf" ] || die "内部ジャーナルが無い: ${jf}（'loop-journal.sh start $epic' を実行しろ）"

  body="$(read_body)" || exit 1
  {
    echo
    echo "## $(now_iso) / #${issue#\#} / $phase${title:+ — $title}"
    echo
    printf '%s\n' "$body"
  } >> "$jf"

  echo "内部ジャーナルに追記した: $epic / #${issue#\#} / $phase"
}

cmd_outer() {
  local phase="${1:-}" title="${2:-}"
  case "$phase" in
    plan|approve|integrate|note) ;;
    *) die "phase は plan / approve / integrate / note のいずれか。指定値: '${phase:-空}'" ;;
  esac

  local epic body vf
  epic="$(resolve_epic)" || epic="unknown"
  body="$(read_body)" || exit 1

  if ! vf="$(vault_file)" || [ ! -f "$vf" ]; then
    # Vault に届かない端末では内部ジャーナルへ退避する。記録を落とさない。
    local jf
    jf="$(journal_file "$epic")"
    if [ -f "$jf" ]; then
      {
        echo
        echo "## $(now_iso) / epic: $epic / outer:$phase${title:+ — $title}"
        echo
        echo "> ⚠ Vault 未接続のため内部ジャーナルへ退避。flush 時に Vault へ書き写される。"
        echo
        printf '%s\n' "$body"
      } >> "$jf"
      echo "⚠ Vault 未接続。内部ジャーナルへ退避した: $jf" >&2
      return 0
    fi
    die "Vault も内部ジャーナルも無い。記録先が存在しない。"
  fi

  {
    echo
    echo "## $(today) / epic: $epic / $phase${title:+ — $title}"
    echo
    printf '%s\n' "$body"
  } >> "$vf"
  touch_updated "$vf"

  echo "Vault に追記した: $(basename "$vf") / epic: $epic / $phase"
}

touch_updated() {
  local f="${1:-}" tmp
  # 空パスで呼ばれるとカレントディレクトリにゴミを撒く。呼び出し側のバグを黙って通さない。
  [ -n "$f" ] && [ -f "$f" ] || { echo "WARN: touch_updated: 対象ファイルが無い: '${f}'" >&2; return 1; }
  tmp="$f.tmp.$$"
  awk -v d="$(today)" '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm == 1 && /^updated:/ { print "updated: " d; next }
    fm == 1 && $0 == "---" { fm = 2; print; next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# ---------- flush ----------

cmd_flush() {
  local epic jf vf body tmp header
  epic="$(resolve_epic "${1:-}")" || die "エピックが特定できない。slug を引数で指定しろ。"
  jf="$(journal_file "$epic")"
  [ -f "$jf" ] || die "内部ジャーナルが無い: $jf"
  # die はサブシェル内では親を殺せない。判定は必ず親側で行う。
  vf="$(vault_file)" || die "Vault が未接続だ。'loop-journal.sh init <vault-path>' を先に実行しろ。ジャーナルは残した: $jf"
  [ -f "$vf" ] || die "Vault のプロジェクトファイルが無い: ${vf}（'loop-journal.sh init' で作れ）。ジャーナルは残した: $jf"

  # 完了サマリは任意。tty からの実行で空でも通す。
  if [ -t 0 ]; then body=""; else body="$(cat)"; fi

  header="## $(today) / epic: $epic / complete"
  tmp="$(mktemp)" || die "一時ファイルを作れない。ジャーナルは残した: $jf"

  {
    echo
    echo "$header"
    echo
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
      echo
    fi
    echo "### インナーループの経緯"
    echo
    # 内部ジャーナルのエントリ部分のみを、見出しを1段下げて書き写す
    awk -v marker="$ENTRY_MARKER" '
      found { print; next }
      index($0, marker) { found = 1 }
    ' "$jf" | sed 's/^## /#### /' | sed '/./,$!d'
  } > "$tmp"

  # Vault に着地したことを確認してからでなければ、内部ジャーナルは絶対に消さない。
  if ! cat "$tmp" >> "$vf"; then
    rm -f "$tmp"
    die "Vault への追記に失敗した。ジャーナルは残した: $jf"
  fi
  rm -f "$tmp"
  touch_updated "$vf"

  if ! grep -qF "$header" "$vf"; then
    die "Vault への書き込みが確認できない。ジャーナルは残した: $jf"
  fi

  rm -f "$jf"
  if [ -s "$ACTIVE_PTR" ] && [ "$(head -1 "$ACTIVE_PTR")" = "$epic" ]; then
    rm -f "$ACTIVE_PTR"
  fi

  cat <<EOF
Vault へ書き写した: ${vf}（epic: ${epic}）
内部ジャーナルを削除した: $jf

削除をコミットしろ:
  git add -A .claude/memory/journal && git commit -m "chore: flush inner-loop journal for epic $epic"
EOF
}

# ---------- 点検 ----------

cmd_where() {
  local v vf epic
  v="$(vault_dir)" || v="(未接続)"
  vf="$(vault_file)" || vf="(未接続)"
  epic="$(resolve_epic)" || epic="(未特定)"
  cat <<EOF
プロジェクト名 : $(project_name)
Vault ルート   : $v
Vault ファイル : $vf
内部ジャーナル : $JOURNAL_DIR
進行中エピック : $epic
EOF
}

cmd_status() {
  cmd_where
  echo
  local vf
  if vf="$(vault_file)" && [ -f "$vf" ]; then
    echo "Vault に記録済みのエピック:"
    grep -n '^## ' "$vf" | tail -5 | sed 's/^/  /' || echo "  （まだ無し）"
  else
    echo "Vault: 未接続、またはプロジェクトファイル未作成"
    echo "  接続: bash .claude/scripts/loop-journal.sh init <vault-path>"
  fi
  echo
  echo "未フラッシュの内部ジャーナル:"
  local found=0 f n
  for f in "$JOURNAL_DIR"/*.md; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in README.md) continue ;; esac
    found=1
    n="$(grep -c '^## ' "$f" 2>/dev/null || echo 0)"
    echo "  $(basename "$f" .md) — ${n} エントリ"
  done
  [ "$found" -eq 1 ] || echo "  （なし）"
}

case "${1:-}" in
  init)    shift; cmd_init "$@" ;;
  context) shift; cmd_context "$@" ;;
  start)   shift; cmd_start "$@" ;;
  inner)   shift; cmd_inner "$@" ;;
  outer)   shift; cmd_outer "$@" ;;
  flush)   shift; cmd_flush "$@" ;;
  status)  cmd_status ;;
  where)   cmd_where ;;
  *)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
