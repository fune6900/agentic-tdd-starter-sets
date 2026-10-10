#!/usr/bin/env bash
# 導入先プロジェクトに、監視サーバ用の compose を生成する
#
# SessionStart フックから自動で呼ばれる。導入先で `docker compose up` した時に
# 監視コンテナが一緒に立つ状態を、既存ファイルを壊さずに作る。
#   - compose.monitor.yml … 原本 .claude/monitor/compose.monitor.yml のバイト複製（有れば触らない）。
#                           原本の読み取りと生成先への書き込みは perl の中で fd を 1 回だけ開いて行う（名前で開き直さない）
#   - compose.yaml        … compose の候補ファイルが1つも無い時だけ、include だけのものを作る
#   - 候補が有る時       … 何も書き換えず、include の追記方法を案内する
#
# 原則:
#   1. 既存ファイルを絶対に上書きしない。直下にも祖先にも触れない
#   2. リンク（ダングリング含む）は書かない。リンク先に作らせない
#   3. 生成条件は「直下に package.json」または「直下に compose 候補」だけ。満たさなければ何もしない
#      （祖先の候補だけでは生成しない。テンプレート自身では何も出ない）。
#      祖先の候補は、条件を満たした場合に compose.yaml を作らない抑止にだけ使う
#   4. 冪等。出力は固定文字列のみ（stdout はセッションのコンテキストに入る。外部由来の値を載せない）
#
# 出典（いずれも 2026-10-10 取得。推測で列挙しない）:
#   - 探索するファイル名 8 つ: compose-go cli/options.go の DefaultFileNames / DefaultOverrideFileNames
#     https://github.com/compose-spec/compose-go/blob/main/cli/options.go
#   - 作業ディレクトリと全ての親ディレクトリを探索する:
#     https://docs.docker.com/compose/how-tos/multiple-compose-files/merge/
#     （祖先に候補が有る所で直下に compose.yaml を作ると、読まれるファイルが変わってしまう）
#   - include は Compose v2.20.0 から:
#     https://github.com/docker/compose/releases/tag/v2.20.0
#
# 使い方:
#   bootstrap-monitor.sh            生成して結果を表示する
#   bootstrap-monitor.sh --quiet    何もしなかった場合は黙る（フックからの既定）
#   bootstrap-monitor.sh --dry-run  生成せず、生成する内容を表示する
#
# 環境変数:
#   LOOP_BOOTSTRAP=0   ブートストラップを完全に無効化する

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${CODEX_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
case "$PROJECT_DIR" in
  /*) ;;
  *) PROJECT_DIR="$(pwd)/$PROJECT_DIR" ;;
esac

CAND_NAMES="compose.yaml compose.yml docker-compose.yml docker-compose.yaml compose.override.yml compose.override.yaml docker-compose.override.yml docker-compose.override.yaml"

MONITOR_YML="$PROJECT_DIR/compose.monitor.yml"
COMPOSE_YAML="$PROJECT_DIR/compose.yaml"
ORIG="$PROJECT_DIR/.claude/monitor/compose.monitor.yml"

QUIET=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --quiet)   QUIET=1 ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "ERROR: 未知の引数。" >&2; exit 1 ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || echo "$@"; }
note() { echo "$@"; }   # 生成したとき・警告は quiet でも必ず知らせる

# 存在する（リンクはダングリングでも存在とみなす）
exists() { [ -e "$1" ] || [ -L "$1" ]; }

# 原本の読み取りと生成先への書き込みは perl の中だけで行う。
#   - 名前で開くのは sysopen の 1 回だけ。判定は開いた fd 上（FIFO・デバイス・ディレクトリは読まない）
#   - 読み取りは O_NOFOLLOW|O_NONBLOCK|O_NOCTTY。上限 65536 バイト、sysread は上限 + 1 バイトまで
#   - 書き込みは O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK。既存・リンク・FIFO は書かない
#   - パスは環境変数で渡す（argv に載せない）。結果は固定の理由文字列 1 行（外部由来の値を載せない）
#   - BM_MODE: copy=原本を読んで BM_DST に作る / read=原本を読んで内容を返す / write=BM_CONTENT を BM_DST に作る
# PERL_IO は .claude/hooks/monitor-emit.sh の PERL_READ と同じ方式。片方を直したらもう片方も直す。3 本目が出たら共通化する。
MAX_BYTES=65536
PERL_IO='
my $ok = eval { require Fcntl; Fcntl::O_NOFOLLOW(); Fcntl::O_NONBLOCK(); Fcntl::O_NOCTTY(); 1 };
$| = 1;
sub fin { print $_[0], "\n"; exit 0 }
fin("read_failed") unless $ok;
my ($mode, $src, $dst, $max) = ($ENV{BM_MODE}, $ENV{BM_SRC}, $ENV{BM_DST}, $ENV{BM_MAX});
fin("read_failed") unless defined $mode && defined $max && $max =~ /^[0-9]+$/;
my $buf = "";
if ($mode eq "copy" || $mode eq "read") {
  fin("read_failed") unless defined $src && length $src;
  my $fh;
  unless (sysopen($fh, $src, Fcntl::O_RDONLY() | Fcntl::O_NONBLOCK() | Fcntl::O_NOFOLLOW() | Fcntl::O_NOCTTY())) {
    fin($!{ELOOP} ? "symlink" : "read_failed");
  }
  binmode($fh);
  my @st = stat($fh);
  fin("read_failed") unless @st;
  fin("not_regular_file") unless -f $fh;
  fin("too_large") if $st[7] > $max;
  my $n = 0;
  while ($n <= $max) {
    my $r = sysread($fh, $buf, $max + 1 - $n, $n);
    fin("read_failed") unless defined $r;
    last if $r == 0;
    $n += $r;
  }
  fin("too_large") if $n > $max;
  fin("read_failed") if $n == 0;
} elsif ($mode eq "write") {
  $buf = defined $ENV{BM_CONTENT} ? $ENV{BM_CONTENT} : "";
} else {
  fin("read_failed");
}
if ($mode eq "read") {
  binmode(STDOUT);
  print "ok\n", $buf;
  exit 0;
}
fin("write_failed") unless defined $dst && length $dst;
my $out;
unless (sysopen($out, $dst, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL() | Fcntl::O_NOFOLLOW() | Fcntl::O_NONBLOCK() | Fcntl::O_NOCTTY(), 0644)) {
  fin("write_failed");
}
binmode($out);
my ($len, $off) = (length $buf, 0);
while ($off < $len) {
  my $w = syswrite($out, $buf, $len - $off, $off);
  fin("write_failed") unless defined $w;
  $off += $w;
}
close($out) or fin("write_failed");
fin("ok");
'

# perl を起動して結果全体を PERL_RESULT に入れる（末尾の改行を保つため番兵を付けて外す）。
# perl が無い・失敗した場合は空になる。設定・探索パスは外部の環境変数で変えさせない
run_perl() { # <mode> <src> <dst> <content>
  PERL_RESULT="$(BM_MODE="$1" BM_SRC="$2" BM_DST="$3" BM_CONTENT="$4" BM_MAX="$MAX_BYTES" \
    env -u PERL5LIB -u PERL5OPT -u PERLLIB -u PERL5DB -u PERL_UNICODE -u PERLIO \
    perl -e "$PERL_IO" 2>/dev/null </dev/null; printf x)"
  PERL_RESULT="${PERL_RESULT%x}"
  PERL_STATUS="${PERL_RESULT%%$'\n'*}"
}

# 原本の読み取り失敗を固定文言にする
warn_read() {
  case "$PERL_STATUS" in
    symlink)          note "WARN: 原本 .claude/monitor/compose.monitor.yml がシンボリックリンクだ。compose.monitor.yml は生成しない。" ;;
    not_regular_file) note "WARN: 原本 .claude/monitor/compose.monitor.yml が通常ファイルではない。compose.monitor.yml は生成しない。" ;;
    too_large)        note "WARN: 原本 .claude/monitor/compose.monitor.yml が上限（64KB）を超えている。compose.monitor.yml は生成しない。" ;;
    *)                note "WARN: 原本 .claude/monitor/compose.monitor.yml を読めない（perl が使えない場合を含む）。compose.monitor.yml は生成しない。" ;;
  esac
}

COMPOSE_YAML_CONTENT="# 監視サーバ（.claude/monitor）を一緒に起動する。
# .claude/scripts/bootstrap-monitor.sh が生成した。以後は手で管理してよい。
include:
  - path: compose.monitor.yml
    project_directory: .
"

GUIDE_TEXT="compose ファイルが既にあるので compose.yaml は作らない。監視も一緒に起動するには、
既存の compose ファイルに次の include を追記してください（Compose v2.20.0 以降）。
  include:
    - path: compose.monitor.yml
      project_directory: .
compose.monitor.yml はネットワーク monitor-net とボリューム monitor-data を定義する。既存の定義と名前が衝突しないか確認すること。"

# ---------- 早期離脱 ----------

if [ "${LOOP_BOOTSTRAP:-1}" = "0" ]; then
  say "ブートストラップは LOOP_BOOTSTRAP=0 で無効化されている。"
  exit 0
fi

# ---------- 候補の探索（直下と全ての祖先） ----------

DIRECT_CAND=0
ANCESTOR_CAND=0
d="$PROJECT_DIR"
while :; do
  prefix="${d%/}"
  for n in $CAND_NAMES; do
    if exists "$prefix/$n"; then
      if [ "$d" = "$PROJECT_DIR" ]; then DIRECT_CAND=1; else ANCESTOR_CAND=1; fi
    fi
  done
  [ "$d" = "/" ] && break
  next="${d%/*}"
  [ -n "$next" ] || next="/"
  [ "$next" = "$d" ] && break
  d="$next"
done

HAS_CAND=0
if [ "$DIRECT_CAND" -eq 1 ] || [ "$ANCESTOR_CAND" -eq 1 ]; then HAS_CAND=1; fi

# ---------- 生成条件 ----------

# 判定は「直下の package.json」か「直下の候補」だけ。祖先の候補は条件に数えない
# （モノレポの親や $HOME の compose だけで、無関係なディレクトリに書き込まないため）。
# 祖先の候補（HAS_CAND に合算）は、条件を満たした後の compose.yaml 抑止にだけ使う
if [ ! -f "$PROJECT_DIR/package.json" ] && [ "$DIRECT_CAND" -eq 0 ]; then
  say "直下に package.json も compose ファイルも無い（祖先の compose だけでは生成しない）。監視用 compose は生成しない。"
  say "（このテンプレート自身のリポジトリでは、これが正しい挙動）"
  exit 0
fi

# ---------- シンボリックリンク（直下の生成先・原本・候補） ----------
# [ -f ] や [ -e ] はリンクを追う。ダングリングリンクは「存在しない」と判定され、
# リダイレクトがリンク先にファイルを作ってしまう。1つでもリンクなら何も書かない

has_link() {
  local n
  for n in $CAND_NAMES compose.monitor.yml; do
    [ -L "$PROJECT_DIR/$n" ] && return 0
  done
  [ -L "$ORIG" ]
}

if has_link; then
  note "WARN: compose.monitor.yml・compose の候補・原本のいずれかがシンボリックリンクだ。"
  note "WARN: リンク先に書くと封じ込めが成立しないため、何も生成しない。"
  exit 0
fi

# ---------- 何を作るか ----------

NEED_MONITOR=0
exists "$MONITOR_YML" || NEED_MONITOR=1
MONITOR_PRESENT=$((1 - NEED_MONITOR))

NEED_YAML=0
[ "$HAS_CAND" -eq 0 ] && NEED_YAML=1
YAML_PRESENT=0

if [ "$NEED_MONITOR" -eq 1 ] && ! exists "$ORIG"; then
  note "WARN: 原本 .claude/monitor/compose.monitor.yml が無い。compose.monitor.yml は生成しない。"
  exit 0
fi

# ---------- 出力 ----------

if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$NEED_MONITOR" -eq 1 ]; then
    run_perl read "$ORIG" "" ""
    if [ "$PERL_STATUS" != "ok" ]; then
      warn_read
      exit 0
    fi
    echo "--- 生成される compose.monitor.yml ---"
    printf '%s' "${PERL_RESULT#*$'\n'}"
  fi
  if [ "$NEED_YAML" -eq 1 ]; then
    echo "--- 生成される compose.yaml ---"
    printf '%s' "$COMPOSE_YAML_CONTENT"
  elif [ "$HAS_CAND" -eq 1 ]; then
    echo "$GUIDE_TEXT"
  fi
  exit 0
fi

CREATED=0

if [ "$NEED_MONITOR" -eq 1 ]; then
  # 書く直前に、リンク性と存在をもう一度確認する
  if [ -L "$MONITOR_YML" ]; then
    note "WARN: 生成直前にシンボリックリンクを検出した。何も生成しない。"
    exit 0
  fi
  if exists "$MONITOR_YML"; then
    MONITOR_PRESENT=1
  else
    run_perl copy "$ORIG" "$MONITOR_YML" ""
    case "$PERL_STATUS" in
      ok)
        CREATED=1
        note "監視用 compose を生成した: compose.monitor.yml"
        ;;
      write_failed)
        note "WARN: compose.monitor.yml を書き込めない。compose.yaml は生成しない。"
        exit 0
        ;;
      *)
        warn_read
        exit 0
        ;;
    esac
  fi
fi

if [ "$NEED_YAML" -eq 1 ]; then
  if [ -L "$COMPOSE_YAML" ]; then
    note "WARN: 生成直前にシンボリックリンクを検出した。compose.yaml は生成しない。"
    exit 0
  fi
  if exists "$COMPOSE_YAML"; then
    YAML_PRESENT=1
    say "compose.yaml が既に存在する（上書きしない）。"
  elif run_perl write "" "$COMPOSE_YAML" "$COMPOSE_YAML_CONTENT"; [ "$PERL_STATUS" = "ok" ]; then
    CREATED=1
    note "compose.yaml を生成した（compose.monitor.yml を include するだけ）。内容を確認してからコミットしてください。"
  else
    note "WARN: compose.yaml を書き込めない。"
  fi
elif [ "$HAS_CAND" -eq 1 ]; then
  if [ "$CREATED" -eq 1 ]; then note "$GUIDE_TEXT"; else say "$GUIDE_TEXT"; fi
fi

# 両方とも既にあって何もしなかった時だけ言う（書き込みに失敗した時は WARN 済み）
if [ "$CREATED" -eq 0 ] && [ "$MONITOR_PRESENT" -eq 1 ] && { [ "$NEED_YAML" -eq 0 ] || [ "$YAML_PRESENT" -eq 1 ]; }; then
  say "監視用 compose は既に存在する（上書きしない）。"
fi
exit 0
