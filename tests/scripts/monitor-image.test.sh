#!/usr/bin/env bash
# 監視イメージ（Dockerfile）と原本 compose の静的検査（Issue #20 / Red）
#
# デーモン不要。docker CLI と compose プラグイン（docker compose config）だけで動く。
# ビルド・起動・ヘルス・実ユーザーは tests/scripts/monitor-image-smoke.test.sh（デーモン必須・重い）が受け持つ。
#
# ── テストを分けた理由 ─────────────────────────────────────────────────────
#   Issue は「docs-consistency で機械判定」と書くが、docs-consistency は docs ジョブ（Docker も Node も無い）で
#   単独実行される作りで、compose の実出力（docker compose config）を要するこの検査は載せられない。
#   Docker がある tests ジョブで bash tests/run.sh が回すこのスイートに置く。
#   docs-consistency には「必須ジョブ検査の更新（4 → 5）と、スモークジョブの中身」だけを置く
#
# ── 前提（lessons #10: 判定不能は合格にしない）────────────────────────────────
#   docker / docker compose が無い、または compose config が失敗する場合は、スキップせず FAIL。
#   YAML は grep で判定しない（行単位で誤爆する）。docker compose config --format json を jq で見る。
#   Dockerfile は継続行・コメントを論理行に直してから命令単位で見る（grep の行単位判定を使わない）。
#
# ── Coder への契約（テストが前提にした名前。変えるなら QA に差し戻せ）────────────
#   .claude/monitor/Dockerfile          ビルドコンテキストは .claude/monitor。FROM は1行のみ
#     FROM node:24-alpine@sha256:<64桁の小文字hex>    ← 直前の連続コメントに取得日（YYYY-MM-DD）
#     USER <root 以外>                  （最後の USER が有効。名前か数値。変数は不可）
#     HEALTHCHECK ... CMD ["node", "-e", "..."]  ← 先頭コマンドが node、/api/state と LOOP_MONITOR_PORT を含む
#                                         （ポートを決め打ちすると LOOP_MONITOR_PORT 変更時に不健康になる）
#     curl / wget を命令（コメント以外）に書かない。ヒアドキュメント（<<）と escape ディレクティブは非対応
#   .claude/monitor/.dockerignore       test / docs / data と env 系（**/ 付きで全階層。否定で戻さない）を除外
#                                       （記述はここで静的に見る。実際の除外は smoke が docker build で確かめる）
#     ENV MONITOR_DB=/data 配下の絶対パス + /data を node に chown（docker run が DB 指定なしでも起動できる）
#     ENV MONITOR_BIND は書かない（イメージ既定は 127.0.0.1 listen のまま。0.0.0.0 は compose 側だけ）
#   .claude/monitor/compose.monitor.yml サービス名は monitor の1つだけ。外部サービスなし
#     networks（G5 retry 2。導入先のアプリと同じ default ネットワークに同居させない）:
#       サービス monitor:  networks: [monitor-net]           ← default を含めない。専用ネットワーク1つだけ
#       トップレベル:      networks: { monitor-net: {} }     ← 名前は monitor-net 固定ではない（default 以外の1つ）
#                          internal: true は付けない（実測: internal だと published ports がホストから届かない。
#                          nettest で同一構成を internal あり/なしで起動し、ホストの curl が 000 / 200 になった）。external も不可
#     複製・include で別サービス（例: app）と同居しても、monitor と app の networks のキー集合は交わらない
#     build.context: ./.claude/monitor   （project directory = プロジェクト直下の前提。--project-directory . で
#                                          原本の置き場所から回しても、直下へ複製しても同じ文字列で同じ場所を指す）
#     ports: 1件。host_ip 127.0.0.1、published == target == ${LOOP_MONITOR_PORT:-4319}（内外同一。#19 の Host 検査がポート込み）
#     environment: LOOP_MONITOR_PORT=${LOOP_MONITOR_PORT:-4319} / MONITOR_BIND=0.0.0.0 / MONITOR_DB=<名前付きボリュームの直下の絶対パス>
#     volumes: 名前付きボリューム1つ（DB の置き場所。リンクを含まない実体パス）と
#              ./.claude/memory のディレクトリ単位 bind（read_only: true）のみ。ほかの bind は不可
#     read_only: true / cap_drop: [ALL] / security_opt に no-new-privileges:true
#     privileged・network_mode: host・pid: host・cap_add は不可。user を書くなら root 以外
#
# ── 変異テスト対応表（隔離コピー: REPO_ROOT=<コピー> bash tests/scripts/monitor-image.test.sh）──────
#   USER 行を消す                  → 「最後の USER が root 以外」
#   digest を外す                  → 「FROM が node:24-alpine@sha256:<64桁hex>」
#   127.0.0.1 を外す               → 「公開は 127.0.0.1 に bind」（原本・複製の全パターン）
#   公開ポートと内側ポートのずれ   → 「target == published」「LOOP_MONITOR_PORT == published」（4555 指定の2パターン）
#   read_only / cap_drop / no-new-privileges を外す → 対応する各1件
#   ファイル単位の bind に変える   → 「memory はディレクトリ単位」
#   build.context を変える         → 「build.context が ./.claude/monitor」（原本・複製・include の全パターン）
#   networks を外す / default を足す → 「default ネットワークに属さず専用ネットワーク1つだけ」（全パターン）
#   専用ネットワークに internal: true → 「internal: true でも external でもない」
#   app を monitor と同じネットワークへ → 「他サービスと共有されない」（直下複製・include の app 同居 各2ポート）
#   ENV MONITOR_DB を /data 外にする・chown を外す → 「ENV MONITOR_DB が /data 配下」
#   ENV MONITOR_BIND を足す        → 「ENV MONITOR_BIND が無い」
#   .dockerignore から env 系を消す・否定で戻す → 「.dockerignore が .env 系を全階層で除外する」
#   検査器そのものの自己診断は「[自己診断]」。判定関数に既知の悪い入力を食わせ、必ず落ちることを固定する

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

cd "$REPO_ROOT" || exit 1

trap cleanup_sandboxes EXIT

MONITOR_DIR=".claude/monitor"
DOCKERFILE="$MONITOR_DIR/Dockerfile"
DOCKERIGNORE="$MONITOR_DIR/.dockerignore"
COMPOSE_SRC="$MONITOR_DIR/compose.monitor.yml"
DEFAULT_PORT="4319"

WORK="$(mktemp -d)" || { echo "mktemp に失敗した" >&2; exit 1; }
SANDBOXES+=("$WORK")
EMPTY_ENV="$WORK/empty.env"
: > "$EMPTY_ENV"
ERR_FILE="$WORK/stderr.txt"

# ══════════════════════════════════════════════
# Dockerfile の検査器（文字列を受けて 0/1 を返す。自己診断で縛る）
# ══════════════════════════════════════════════

# 継続行・コメントを論理行に直す。出力は「C<TAB>コメント行」「B<TAB>空行」「I<TAB>命令（論理1行）」
df_logical() {
  awk '
    { sub(/\r$/, "") }
    !cont && /^[[:space:]]*#/ { print "C\t" $0; next }
    cont && /^[[:space:]]*#/ { next }
    !cont && /^[[:space:]]*$/ { print "B\t"; next }
    cont && /^[[:space:]]*$/ { next }
    {
      line = $0
      if (line ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, "", line); buf = buf line " "; cont = 1; next }
      print "I\t" buf line
      buf = ""; cont = 0
    }
    END { if (cont) print "I\t" buf }
  '
}

# 指定命令（大文字小文字を区別しない）の引数を1命令1行で出す
df_instr() { # <内容> <命令>
  local content="$1" want="$2" tag line kw rest
  while IFS=$'\t' read -r tag line; do
    [ "$tag" = "I" ] || continue
    line="${line#"${line%%[![:space:]]*}"}"
    kw="${line%%[[:space:]]*}"
    rest="${line#"$kw"}"
    rest="${rest#"${rest%%[![:space:]]*}"}"
    rest="${rest%"${rest##*[![:space:]]}"}"
    kw="$(printf '%s' "$kw" | tr 'a-z' 'A-Z')"
    if [ "$kw" = "$want" ]; then printf '%s\n' "$rest"; fi
  done < <(printf '%s\n' "$content" | df_logical)
}

# コメントを除いた全命令（1命令1行）
df_all_instr() { # <内容>
  local tag line
  while IFS=$'\t' read -r tag line; do
    if [ "$tag" = "I" ]; then printf '%s\n' "$line"; fi
  done < <(printf '%s\n' "$1" | df_logical)
}

# この検査器が正しく読めない書き方（ヒアドキュメント・escape ディレクティブ）。読めないものは合格にしない
df_supported() { # <内容>
  local tag line
  while IFS=$'\t' read -r tag line; do
    case "$tag" in
      I) case "$line" in *"<<"*) return 1 ;; esac ;;
      C) case "$line" in *escape=*|*escape\ =*) return 1 ;; esac ;;
    esac
  done < <(printf '%s\n' "$1" | df_logical)
  return 0
}

from_ok() { # <FROM の引数>
  local re='^node:24-alpine@sha256:[0-9a-f]{64}$'
  [[ $1 =~ $re ]]
}

df_from_ok() { # <内容>。FROM はちょうど1行で、from_ok を満たす
  local f
  f="$(df_instr "$1" FROM)"
  [ -n "$f" ] || return 1
  [ "$(printf '%s\n' "$f" | wc -l | tr -d ' ')" = "1" ] || return 1
  from_ok "$f"
}

# FROM の直前に途切れず続くコメントブロックに YYYY-MM-DD がある
df_from_has_date() { # <内容>
  local tag line block="" kw
  local re='[0-9]{4}-[0-9]{2}-[0-9]{2}'
  while IFS=$'\t' read -r tag line; do
    case "$tag" in
      C) block="${block}${line}"$'\n' ;;
      B) block="" ;;
      I)
        line="${line#"${line%%[![:space:]]*}"}"
        kw="$(printf '%s' "${line%%[[:space:]]*}" | tr 'a-z' 'A-Z')"
        if [ "$kw" = "FROM" ]; then
          [[ $block =~ $re ]]
          return $?
        fi
        block=""
        ;;
    esac
  done < <(printf '%s\n' "$1" | df_logical)
  return 1
}

# USER の引数の1要素（ユーザー or グループ）が root でない名前か正の数値
user_part_ok() { # <要素>
  local p="$1" lower
  local re_name='^[A-Za-z_][A-Za-z0-9_.-]*$'
  case "$p" in
    '') return 1 ;;
    *[!0-9]*)
      lower="$(printf '%s' "$p" | tr 'A-Z' 'a-z')"
      [ "$lower" = "root" ] && return 1
      [[ $p =~ $re_name ]]
      ;;
    *)
      [ "${#p}" -le 9 ] || return 1
      [ "$((10#$p))" -gt 0 ]
      ;;
  esac
}

user_ok() { # <USER の引数>
  local v="$1" u g=""
  case "$v" in
    ''|*[[:space:]]*|*'$'*|*'{'*|*'"'*|*"'"*|*'\'*) return 1 ;;
  esac
  u="${v%%:*}"
  case "$v" in *:*) g="${v#*:}" ;; esac
  user_part_ok "$u" || return 1
  case "$v" in *:*) user_part_ok "$g" || return 1 ;; esac
  return 0
}

df_user_ok() { # <内容>。最後の USER が有効で、root でない
  local u
  u="$(df_instr "$1" USER | tail -n 1)"
  [ -n "$u" ] || return 1
  user_ok "$u"
}

# curl / wget を語として含まない（パス・識別子の一部は除く）
no_http_tools() { # <文字列>
  local re='(^|[^A-Za-z0-9_./-])(curl|wget)([^A-Za-z0-9_-]|$)'
  if [[ $1 =~ $re ]]; then return 1; fi
  return 0
}

healthcheck_ok() { # <HEALTHCHECK の引数>
  local r="$1"
  local re_cmd='^CMD[[:space:]]+(\[[[:space:]]*"node"|node([[:space:]]|$))'
  while [[ $r == --* ]]; do
    case "$r" in
      *[[:space:]]*) r="${r#*[[:space:]]}"; r="${r#"${r%%[![:space:]]*}"}" ;;
      *) return 1 ;;
    esac
  done
  [[ $r =~ $re_cmd ]] || return 1
  case "$r" in *"/api/state"*) ;; *) return 1 ;; esac
  case "$r" in *LOOP_MONITOR_PORT*) ;; *) return 1 ;; esac
  no_http_tools "$r"
}

df_healthcheck_ok() { # <内容>。HEALTHCHECK はちょうど1行で healthcheck_ok を満たす
  local h
  h="$(df_instr "$1" HEALTHCHECK)"
  [ -n "$h" ] || return 1
  [ "$(printf '%s\n' "$h" | wc -l | tr -d ' ')" = "1" ] || return 1
  healthcheck_ok "$h"
}

df_no_http_tools() { # <内容>
  no_http_tools "$(df_all_instr "$1")"
}

# ══════════════════════════════════════════════
# compose の検査器（compose config の JSON を受けて 0/1 を返す）
#   引数: <json> <期待ポート> <プロジェクト直下の実ディレクトリ>
# ══════════════════════════════════════════════

jqe() { # <json> <jq の引数...>
  local json="$1"
  shift
  printf '%s' "$json" | jq -e "$@" >/dev/null 2>&1
}

# サービスが無い・壊れた入力では「無い＝許容」の否定系チェックまで通ってしまう。先に存在を要求する
has_svc() { jqe "$1" '.services.monitor | type == "object"'; }

BINDS='[.services.monitor.volumes[]? | select(.type == "bind")]'
VOLS='[.services.monitor.volumes[]? | select(.type == "volume")]'

c_single_service() { jqe "$1" '(.services | keys) == ["monitor"]'; }
c_one_port() { jqe "$1" '(.services.monitor.ports | length) == 1'; }
c_bind_loopback() { jqe "$1" '.services.monitor.ports[0].host_ip == "127.0.0.1"'; }
c_published_port() { jqe "$1" --arg p "$2" '(.services.monitor.ports[0].published | tostring) == $p'; }
c_target_port() { jqe "$1" --arg p "$2" '(.services.monitor.ports[0].target | tostring) == $p'; }
c_tcp_only() { has_svc "$1" && jqe "$1" '(.services.monitor.ports[0].protocol // "tcp") == "tcp"'; }
c_env_port() { jqe "$1" --arg p "$2" '.services.monitor.environment.LOOP_MONITOR_PORT == $p'; }
c_env_bind() { jqe "$1" '.services.monitor.environment.MONITOR_BIND == "0.0.0.0"'; }
c_read_only() { jqe "$1" '.services.monitor.read_only == true'; }
c_cap_drop() { jqe "$1" '.services.monitor.cap_drop == ["ALL"]'; }
c_no_cap_add() { has_svc "$1" && jqe "$1" '((.services.monitor.cap_add // []) | length) == 0'; }
c_no_new_priv() { jqe "$1" '((.services.monitor.security_opt // []) | index("no-new-privileges:true")) != null'; }
c_not_privileged() {
  has_svc "$1" && jqe "$1" '(.services.monitor.privileged // false) == false
    and (.services.monitor.network_mode // "") != "host"
    and (.services.monitor.pid // "") != "host"'
}
c_one_named_volume() {
  jqe "$1" ". as \$r | ${VOLS} as \$v
    | (\$v | length) == 1 and (\$v[0].read_only // false) == false and (\$r.volumes | has(\$v[0].source))"
}
c_db_in_volume() {
  jqe "$1" "${VOLS}[0].target as \$t
    | (.services.monitor.environment.MONITOR_DB // \"\") as \$db
    | \$t != null and (\$db | test(\"^/[^/]+(/[^/]+)*/[^/]+\$\")) and ((\$db | sub(\"/[^/]+\$\"; \"\")) == \$t)"
}
c_memory_bind_ro() { jqe "$1" "${BINDS} | length == 1 and .[0].read_only == true"; }
c_only_memory_bind() { jqe "$1" "${BINDS} as \$b | (\$b | length) == 1 and all(\$b[]; .source | endswith(\"/.claude/memory\"))"; }
c_mount_targets() {
  jqe "$1" "${BINDS}[0].target as \$m | ${VOLS}[0].target as \$t
    | \$m != null and \$t != null and \$m != \$t
    and ((\$m | startswith(\$t + \"/\")) | not) and ((\$t | startswith(\$m + \"/\")) | not)"
}
# memory はディレクトリ単位: bind の source が <直下>/.claude/memory の実ディレクトリそのもの
c_memory_dir() {
  local src real expect
  src="$(printf '%s' "$1" | jq -r "${BINDS}[0].source // empty" 2>/dev/null)"
  [ -n "$src" ] || return 1
  real="$(cd -P "$src" 2>/dev/null && pwd -P)" || return 1
  expect="$(cd -P "$3/.claude/memory" 2>/dev/null && pwd -P)" || return 1
  [ -n "$real" ] && [ "$real" = "$expect" ]
}
c_user_not_root() {
  local u
  has_svc "$1" || return 1
  u="$(printf '%s' "$1" | jq -r '.services.monitor.user // ""' 2>/dev/null)" || return 1
  [ -z "$u" ] && return 0
  user_ok "$u"
}
c_build_context() {
  local ctx real expect
  ctx="$(printf '%s' "$1" | jq -r '.services.monitor.build.context // empty' 2>/dev/null)"
  [ -n "$ctx" ] || return 1
  real="$(cd -P "$ctx" 2>/dev/null && pwd -P)" || return 1
  expect="$(cd -P "$3/.claude/monitor" 2>/dev/null && pwd -P)" || return 1
  [ "$real" = "$expect" ]
}
c_dockerfile() {
  local df
  has_svc "$1" || return 1
  df="$(printf '%s' "$1" | jq -r '.services.monitor.build.dockerfile // "Dockerfile"' 2>/dev/null)"
  case "$df" in ''|/*|*..*) return 1 ;; esac
  [ -f "$3/.claude/monitor/$df" ]
}

# ── ネットワーク（G5 retry 2）。monitor は default に入らず、専用ネットワーク1つだけに属す ──
# networks を書かないサービスは compose が default に入れる（config の出力は {"default": null}）。省略も default 扱いにする
c_dedicated_net() {
  jqe "$1" '(.services.monitor.networks // {"default": null} | keys) as $k
    | ($k | length) == 1 and ($k | index("default") | not) and ((.networks // {}) | has($k[0]))'
}
# internal: true はホストからの published ports を殺す（実測）。external は他プロジェクトと共有しうる
c_net_not_internal() {
  has_svc "$1" && jqe "$1" '(.services.monitor.networks // {} | keys[0]) as $k
    | $k != null and ((.networks[$k].internal // false) == false) and ((.networks[$k].external // false) == false)'
}
# monitor と他の全サービスの networks のキー集合が交わらない（他サービスが無ければ自明に通る。空振りは呼び出し側で防ぐ）
c_net_isolated() {
  has_svc "$1" && jqe "$1" 'def nets: (.networks // {"default": null} | keys);
    (.services.monitor | nets) as $m
    | [.services | to_entries[] | select(.key != "monitor") | .value | nets[]] as $others
    | all($m[]; . as $k | ($others | index($k)) == null)'
}

# .dockerignore が .env 系を除外する。サブディレクトリにも効く形（**/.env* か、**/.env と **/.env.* の両方）を要求する。
# 直下だけの .env* / .env / .env.* は FAIL（Docker はパターンをコンテキスト直下基準で解釈し、server/ 配下には届かない）。
# .env を戻す否定パターンも不可。これは文法の近似で弱い。本体はスモークの「全階層の囮が入らない」実効検査（lessons #9）
di_ignores_env() { # <内容>
  local line plain=1 dot=1 glob=1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in '!'*) case "$line" in *.env*) return 1 ;; esac ;; esac
    case "$line" in
      '**/.env*') glob=0 ;;
      '**/.env') plain=0 ;;
      '**/.env.*') dot=0 ;;
    esac
  done <<< "$1"
  [ "$glob" -eq 0 ] || { [ "$plain" -eq 0 ] && [ "$dot" -eq 0 ]; }
}

# .dockerignore が許可リスト方式: 先頭の有効行が *（全除外）、続いて !server と !public（Issue #21: ビューの静的ファイル。両方必須）で戻し、その後ろに秘密パターンの除外を並べる。
# Docker は最後に一致した行が勝つので、秘密パターンは !server より後ろに置かないと server/ 配下の秘密が戻ってしまう（順序を検査）。
# !server が複数回出たら状態を全てリセットする（秘密パターンの後に !server が戻ると、その秘密が戻るため。最後の !server より後ろだけを数える）。
# 要求する行: **/.env*（または **/.env と **/.env.*）・**/*.pem・**/*.key・**/id_*。!server / !public 以外の否定（!）は許さない。
# 文法の近似で弱い。実効はスモークの囮（env 系・*.pem・*.key・id_*）が本体
di_allowlist_ok() { # <内容>
  local line first=1 seen_back=0 seen_pub=0 after="" ok_first=1 neg_other=0 pem=1 key=1 idr=1
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in ''|'#'*) continue ;; esac
    if [ "$first" -eq 1 ]; then
      first=0
      [ "$line" = "*" ] && ok_first=0
      continue
    fi
    case "$line" in
      '!server'|'!server/'|'!server/**') seen_back=1; after=""; pem=1; key=1; idr=1; continue ;;
      '!public'|'!public/'|'!public/**') seen_pub=1; after=""; pem=1; key=1; idr=1; continue ;;
      '!'*) neg_other=1 ;;
    esac
    if [ "$seen_back" -eq 1 ] || [ "$seen_pub" -eq 1 ]; then
      after="${after}${line}"$'\n'
      case "$line" in
        '**/*.pem') pem=0 ;;
        '**/*.key') key=0 ;;
        '**/id_*') idr=0 ;;
      esac
    fi
  done <<< "$1"
  [ "$ok_first" -eq 0 ] && [ "$seen_back" -eq 1 ] && [ "$seen_pub" -eq 1 ] && [ "$neg_other" -eq 0 ] && [ "$pem" -eq 0 ] && [ "$key" -eq 0 ] && [ "$idr" -eq 0 ] \
    && di_ignores_env "$after"
}

COMPOSE_CHECKS=(
  "サービスは monitor の1つだけ:c_single_service"
  "ports はちょうど1件:c_one_port"
  "公開は 127.0.0.1 に bind（0.0.0.0 でも省略でもない）:c_bind_loopback"
  "公開ポート（published）が LOOP_MONITOR_PORT に追従:c_published_port"
  "コンテナ内ポート（target）が公開ポートと同一（Host 検査がポート込みのため）:c_target_port"
  "プロトコルは tcp:c_tcp_only"
  "コンテナ内の LOOP_MONITOR_PORT が公開ポートと一致（listen が追従する）:c_env_port"
  "MONITOR_BIND=0.0.0.0（公開の絞りは compose の 127.0.0.1 側）:c_env_bind"
  "read_only: true:c_read_only"
  "cap_drop: [ALL]:c_cap_drop"
  "cap_add を持たない:c_no_cap_add"
  "security_opt に no-new-privileges:true:c_no_new_priv"
  "privileged / network_mode: host / pid: host を使わない:c_not_privileged"
  "名前付きボリュームがちょうど1つ（定義済み・書き込み可）:c_one_named_volume"
  "DB（MONITOR_DB）は名前付きボリュームの直下の絶対パス:c_db_in_volume"
  "memory の bind がちょうど1つで read_only: true:c_memory_bind_ro"
  "bind は memory のみ（docker.sock やプロジェクト直下を渡さない）:c_only_memory_bind"
  "memory と DB の target が別で、入れ子でもない:c_mount_targets"
  "memory はファイル単位でなくディレクトリ単位（source が <直下>/.claude/memory）:c_memory_dir"
  "user を書くなら root 以外:c_user_not_root"
  "build.context が <直下>/.claude/monitor を指す:c_build_context"
  "build.dockerfile が context 内に実在する:c_dockerfile"
  "monitor は default ネットワークに属さず、定義済みの専用ネットワーク1つだけに属す:c_dedicated_net"
  "専用ネットワークは internal: true でも external でもない（internal だとホストから届かない）:c_net_not_internal"
  "monitor のネットワークは他サービスと共有されない（導入先のアプリと同居しない）:c_net_isolated"
)

# 実 compose config の出力（または自己診断の合成 JSON）に全チェックを当てる
run_compose_checks() { # <ラベル> <json> <期待ポート> <直下ディレクトリ>
  local label="$1" json="$2" port="$3" dir="$4" entry desc fn
  for entry in "${COMPOSE_CHECKS[@]}"; do
    desc="${entry%:*}"
    fn="${entry##*:}"
    it "${label} ${desc}"
    if "$fn" "$json" "$port" "$dir"; then
      pass
    else
      fail "判定関数: ${fn}（期待ポート ${port}）" "$(printf '%s' "$json" | jq -c '.services.monitor | {ports, read_only, cap_drop, security_opt, user, environment}' 2>/dev/null | cut -c1-300)"
    fi
  done
}

# docker compose config --format json。環境の COMPOSE_* と .env を拾わせない
compose_config() { # <実行ディレクトリ> <ポート|UNSET> <docker compose に渡す引数...>
  local dir="$1" port="$2"
  shift 2
  local -a runner=(env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_ENV_FILES -u LOOP_MONITOR_PORT)
  if [ "$port" != "UNSET" ]; then runner+=("LOOP_MONITOR_PORT=${port}"); fi
  ( cd "$dir" && "${runner[@]}" docker compose --env-file "$EMPTY_ENV" "$@" config --format json 2>"$ERR_FILE" )
}

# config を取って全チェックを当てる。失敗は1件の FAIL にまとめ、後続は走らせない（空 JSON で誤判定しない）
compose_case() { # <ラベル> <期待ポート> <直下> <ポート|UNSET> <docker compose の引数...>
  local label="$1" expect="$2" dir="$3" port="$4" json rc
  shift 4
  json="$(compose_config "$dir" "$port" "$@")"
  rc=$?
  it "${label} docker compose config が成功し JSON を返す"
  if [ "$rc" -ne 0 ] || [ -z "$json" ] || ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
    fail "終了コード ${rc}" "$(head -n 3 "$ERR_FILE" 2>/dev/null | cut -c1-200)"
    return 0
  fi
  pass
  run_compose_checks "$label" "$json" "$expect" "$dir"
}

# 合成した正常な config（自己診断用）。実ファイルに依存しない
golden_json() { # <直下> <ポート>
  jq -n --arg d "$1" --arg p "$2" '{
    name: "x",
    services: { monitor: {
      build: { context: ($d + "/.claude/monitor"), dockerfile: "Dockerfile" },
      cap_drop: ["ALL"],
      environment: { LOOP_MONITOR_PORT: $p, MONITOR_BIND: "0.0.0.0", MONITOR_DB: "/data/monitor.db" },
      networks: { "monitor-net": null },
      ports: [ { mode: "ingress", host_ip: "127.0.0.1", target: ($p | tonumber), published: $p, protocol: "tcp" } ],
      read_only: true,
      security_opt: ["no-new-privileges:true"],
      volumes: [
        { type: "volume", source: "monitor-data", target: "/data", volume: {} },
        { type: "bind", source: ($d + "/.claude/memory"), target: "/memory", read_only: true, bind: { create_host_path: true } }
      ] } },
    networks: { default: { name: "x_default", ipam: {} }, "monitor-net": { name: "x_monitor-net", ipam: {} } },
    volumes: { "monitor-data": { name: "x_monitor-data" } } }'
}

# ══════════════════════════════════════════════
suite "monitor-image: 前提（docker / compose。無ければ FAIL）"
# ══════════════════════════════════════════════

it "docker と docker compose（v2）が使える"
GATE_MSG="$(compose_gate 2>&1)"
GATE_RC=$?
if [ "$GATE_RC" -eq 0 ]; then pass; else fail "$GATE_MSG"; fi

it "jq が使える"
if command -v jq >/dev/null 2>&1; then pass; else fail "jq が PATH に無い"; fi

it "[自己診断] PATH から docker を外すと compose_gate は FAIL（1）を返す。スキップにならない"
EMPTY_BIN="$WORK/emptybin"
mkdir -p "$EMPTY_BIN"
( PATH="$EMPTY_BIN"; compose_gate >/dev/null 2>&1 )
assert_eq "$?" "1"

it "[自己診断] docker があっても compose プラグインが使えなければ compose_gate は FAIL（1）"
STUB_BIN="$WORK/stubbin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\nexit 1\n' > "$STUB_BIN/docker"
chmod +x "$STUB_BIN/docker"
( PATH="$STUB_BIN"; compose_gate >/dev/null 2>&1 )
assert_eq "$?" "1"

if [ "$GATE_RC" -ne 0 ] || ! command -v jq >/dev/null 2>&1; then
  report
  exit 1
fi

# ══════════════════════════════════════════════
suite "monitor-image: [自己診断] Dockerfile 検査器（既知の悪い入力を必ず落とす）"
# ══════════════════════════════════════════════
# 全部 PASS は何も検査していなくても起きる（lessons #5）。判定関数そのものを縛る

H64="$(printf 'a%.0s' $(seq 1 64))"
H63="$(printf 'a%.0s' $(seq 1 63))"
H65="$(printf 'a%.0s' $(seq 1 65))"
UPPER64="$(printf 'A%.0s' $(seq 1 64))"
NOTHEX64="$(printf 'g%.0s' $(seq 1 64))"

it "[自己診断] from_ok: node:24-alpine@sha256:<64桁小文字hex> だけを通す"
bad=""
from_ok "node:24-alpine@sha256:${H64}" || bad="${bad} 通るべき"
for v in "" "node:24-alpine" "node:24-alpine@sha256:abc" "node:24-alpine@sha256:${H63}" "node:24-alpine@sha256:${H65}" \
         "node:24-alpine@sha256:${UPPER64}" "node:24-alpine@sha256:${NOTHEX64}" "node:22-alpine@sha256:${H64}" \
         "node:24-slim@sha256:${H64}" "node:24@sha256:${H64}" "node:latest@sha256:${H64}" "node:24-alpine@sha256:" \
         "node:24-alpine@sha256:${H64} AS base" "--platform=linux/amd64 node:24-alpine@sha256:${H64}" \
         "ubuntu:24.04@sha256:${H64}" "node:24-alpine@sha1:${H64}" " node:24-alpine@sha256:${H64}"; do
  if from_ok "$v"; then bad="${bad} 拒否すべき:'${v}'"; fi
done
assert_eq "$bad" ""

it "[自己診断] user_ok: root（名前・数値・グループ含む）・変数・空・不正を拒否し、非 root だけを通す"
bad=""
for v in node 1000 node:node 1000:1000 app appuser _svc svc-1 node:1000 1000:node; do
  user_ok "$v" || bad="${bad} 通るべき:'${v}'"
done
for v in "" root ROOT Root 0 00 000 0:0 root:root node:root node:0 1000:0 0:1000 root:node '$USER' '${APP_USER}' "node extra" \
         '"root"' "'root'" 0x0 +0 -1 node: :node 1:2:3 99999999999999999999 'a\b'; do
  if user_ok "$v"; then bad="${bad} 拒否すべき:'${v}'"; fi
done
assert_eq "$bad" ""

it "[自己診断] df_user_ok: USER 行が無い・コメントだけ・最後が root・変数は FAIL、最後が非 root なら通る"
bad=""
df_user_ok $'FROM x\nUSER node\nCMD ["a"]' || bad="${bad} 通るべき:基本"
df_user_ok $'FROM x\nuser node' || bad="${bad} 通るべき:小文字"
df_user_ok $'FROM x\nUSER root\nUSER node' || bad="${bad} 通るべき:最後が有効"
df_user_ok $'FROM x\nUSER   1000:1000  ' || bad="${bad} 通るべき:空白"
if df_user_ok $'FROM x\nCMD ["a"]'; then bad="${bad} USER 無しが通った"; fi
if df_user_ok $'FROM x\n# USER node\nCMD ["a"]'; then bad="${bad} コメントの USER が通った"; fi
if df_user_ok $'FROM x\nUSER node\nUSER root'; then bad="${bad} 最後が root なのに通った"; fi
if df_user_ok $'FROM x\nUSER node\nUSER 0'; then bad="${bad} 最後が 0 なのに通った"; fi
if df_user_ok $'FROM x\nUSER ${APP}'; then bad="${bad} 変数が通った"; fi
if df_user_ok $'FROM x\nRUN echo USER node'; then bad="${bad} RUN の中の USER が通った"; fi
if df_user_ok ""; then bad="${bad} 空が通った"; fi
assert_eq "$bad" ""

it "[自己診断] df_from_ok / df_from_has_date: digest 無し・複数 FROM・取得日が FROM の直前に無い場合は FAIL"
bad=""
GOODFROM="FROM node:24-alpine@sha256:${H64}"
df_from_ok "${GOODFROM}"$'\nUSER node' || bad="${bad} 通るべき:from"
if df_from_ok $'FROM node:24-alpine\nUSER node'; then bad="${bad} digest 無しが通った"; fi
if df_from_ok "${GOODFROM}"$'\n'"${GOODFROM}"; then bad="${bad} 複数 FROM が通った"; fi
if df_from_ok $'# FROM '"node:24-alpine@sha256:${H64}"$'\nUSER node'; then bad="${bad} コメントの FROM が通った"; fi
if df_from_ok ""; then bad="${bad} 空が通った"; fi
df_from_has_date $'# digest 取得日: 2026-10-04\n'"${GOODFROM}" || bad="${bad} 通るべき:日付"
df_from_has_date $'# 出典の説明\n# 取得日 2026-10-04\n'"${GOODFROM}" || bad="${bad} 通るべき:複数行コメント"
if df_from_has_date "${GOODFROM}"; then bad="${bad} コメント無しが通った"; fi
if df_from_has_date $'# 取得日 2026-10-04\n\n'"${GOODFROM}"; then bad="${bad} 空行で切れているのに通った"; fi
if df_from_has_date $'# 日付なしの説明\n'"${GOODFROM}"; then bad="${bad} 日付無しが通った"; fi
if df_from_has_date $'# 2026-10-04\nARG X=1\n'"${GOODFROM}"; then bad="${bad} FROM の直前でないのに通った"; fi
if df_from_has_date $'# 2026-1-4\n'"${GOODFROM}"; then bad="${bad} 桁不足の日付が通った"; fi
assert_eq "$bad" ""

it "[自己診断] df_healthcheck_ok: node で /api/state を LOOP_MONITOR_PORT 付きで叩く場合だけ通す。curl / wget / 決め打ちポートは FAIL"
bad=""
HC_OK='HEALTHCHECK --interval=5s --timeout=3s CMD ["node", "-e", "fetch(`http://127.0.0.1:${process.env.LOOP_MONITOR_PORT}/api/state`)"]'
df_healthcheck_ok "FROM x"$'\n'"${HC_OK}" || bad="${bad} 通るべき:exec 形式"
df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK CMD node -e "fetch(process.env.LOOP_MONITOR_PORT+\"/api/state\")"' || bad="${bad} 通るべき:shell 形式"
df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK --interval=5s \'$'\n''  --timeout=3s \'$'\n''  CMD ["node","-e","LOOP_MONITOR_PORT /api/state"]' || bad="${bad} 通るべき:継続行"
if df_healthcheck_ok "FROM x"; then bad="${bad} HEALTHCHECK 無しが通った"; fi
if df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK NONE'; then bad="${bad} NONE が通った"; fi
if df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK CMD curl -f http://127.0.0.1:4319/api/state'; then bad="${bad} curl が通った"; fi
if df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK CMD wget -q -O- http://127.0.0.1:4319/api/state'; then bad="${bad} wget が通った"; fi
if df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK CMD ["curl","-f","LOOP_MONITOR_PORT/api/state"]'; then bad="${bad} exec 形式の curl が通った"; fi
if df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK CMD ["node","-e","fetch(\"http://127.0.0.1:4319/api/state\")"]'; then bad="${bad} ポート決め打ちが通った"; fi
if df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK CMD ["node","-e","LOOP_MONITOR_PORT /api/health"]'; then bad="${bad} /api/state 以外が通った"; fi
if df_healthcheck_ok "FROM x"$'\n''HEALTHCHECK CMD ["sh","-c","node -e LOOP_MONITOR_PORT /api/state"]'; then bad="${bad} sh 経由が通った"; fi
if df_healthcheck_ok "FROM x"$'\n'"${HC_OK}"$'\n'"${HC_OK}"; then bad="${bad} 複数 HEALTHCHECK が通った"; fi
if df_healthcheck_ok "FROM x"$'\n''# HEALTHCHECK CMD ["node","-e","LOOP_MONITOR_PORT /api/state"]'; then bad="${bad} コメントの HEALTHCHECK が通った"; fi
assert_eq "$bad" ""

it "[自己診断] df_no_http_tools: 命令に curl / wget があれば FAIL、コメント・語の一部は誤検出しない"
bad=""
df_no_http_tools $'FROM x\nUSER node' || bad="${bad} 通るべき:基本"
df_no_http_tools $'FROM x\n# curl は入れない\nUSER node' || bad="${bad} コメントの curl を誤検出"
df_no_http_tools $'FROM x\nRUN echo curlish wgetter' || bad="${bad} 語の一部を誤検出"
if df_no_http_tools $'FROM x\nRUN apk add --no-cache curl'; then bad="${bad} apk add curl が通った"; fi
if df_no_http_tools $'FROM x\nRUN apk add wget'; then bad="${bad} apk add wget が通った"; fi
if df_no_http_tools $'FROM x\nRUN apk add \\\n  jq \\\n  curl'; then bad="${bad} 継続行の curl が通った"; fi
if df_no_http_tools $'FROM x\nRUN apt-get install -y curl'; then bad="${bad} apt の curl が通った"; fi
if df_no_http_tools $'FROM x\nHEALTHCHECK CMD ["curl","-f","u"]'; then bad="${bad} exec 形式が通った"; fi
if df_no_http_tools $'FROM x\nRUN true && wget -q u'; then bad="${bad} && wget が通った"; fi
assert_eq "$bad" ""

it "[自己診断] df_supported: ヒアドキュメントと escape ディレクティブは読めないので拒否する"
bad=""
df_supported $'FROM x\nRUN echo hi' || bad="${bad} 通るべき"
if df_supported $'FROM x\nRUN <<EOF\napk add curl\nEOF'; then bad="${bad} ヒアドキュメントが通った"; fi
if df_supported $'# escape=`\nFROM x'; then bad="${bad} escape が通った"; fi
assert_eq "$bad" ""

# ══════════════════════════════════════════════
suite "monitor-image: Dockerfile（静的検査）"
# ══════════════════════════════════════════════

it "Dockerfile が実ファイルとして存在する（シンボリックリンクでない）"
if [ -f "$DOCKERFILE" ] && [ ! -L "$DOCKERFILE" ]; then pass; else fail "$DOCKERFILE が無い、またはリンク"; fi

DF=""
[ -f "$DOCKERFILE" ] && [ ! -L "$DOCKERFILE" ] && DF="$(cat "$DOCKERFILE")"

it "Dockerfile が検査器の対応範囲内（ヒアドキュメント・escape ディレクティブなし）"
if [ -n "$DF" ] && df_supported "$DF"; then pass; else fail "空、または対応外の書き方"; fi

it "FROM がちょうど1行で node:24-alpine@sha256:<64桁hex> 形式（digest 固定）"
if df_from_ok "$DF"; then pass; else fail "FROM: $(df_instr "$DF" FROM | head -n 3 | cut -c1-120)"; fi

it "FROM の直前の連続コメントに digest の取得日（YYYY-MM-DD）がある"
if df_from_has_date "$DF"; then pass; else fail "FROM 直前に途切れず続くコメントへ日付を書く"; fi

it "最後の USER が root 以外（USER 行が無い場合も FAIL）"
if df_user_ok "$DF"; then pass; else fail "USER: $(df_instr "$DF" USER | tr '\n' ' ' | cut -c1-120)"; fi

it "HEALTHCHECK がちょうど1行で、node 自身が /api/state を LOOP_MONITOR_PORT で叩く"
if df_healthcheck_ok "$DF"; then pass; else fail "HEALTHCHECK: $(df_instr "$DF" HEALTHCHECK | head -n 2 | cut -c1-160)"; fi

it "curl / wget をイメージに追加していない（命令のどこにも書かない）"
if [ -n "$DF" ] && df_no_http_tools "$DF"; then pass; else fail "Dockerfile が無い、または curl / wget を含む"; fi

# ENV の値を返す。`ENV K=V ...` と `ENV K V` の両形式。複数回あれば最後（Docker と同じ）。無ければ 1
df_env_value() { # <内容> <キー>
  local content="$1" key="$2" args tok found=1 val="" first
  while IFS= read -r args; do
    first="${args%%[[:space:]]*}"
    case "$first" in
      *=*)
        for tok in $args; do
          case "$tok" in "${key}="*) val="${tok#"${key}="}"; found=0 ;; esac
        done ;;
      *)
        if [ "$first" = "$key" ]; then
          val="${args#"$first"}"; val="${val#"${val%%[![:space:]]*}"}"; found=0
        fi ;;
    esac
  done < <(df_instr "$content" ENV)
  val="${val#\"}"; val="${val%\"}"
  printf '%s' "$val"
  return "$found"
}

# 0 なら: MONITOR_DB が /data 配下の絶対パス、かつ /data を node に chown する命令がある
df_db_env_ok() { # <内容>
  local v
  v="$(df_env_value "$1" MONITOR_DB)" || return 1
  case "$v" in /data/?*) ;; *) return 1 ;; esac
  case "$v" in *..*) return 1 ;; esac
  df_all_instr "$1" | grep -Eq '^RUN .*chown[[:space:]]+(-R[[:space:]]+)?node(:node)?[[:space:]]+/data([[:space:]]|$)'
}

# 0 なら ENV に MONITOR_BIND が無い（イメージ既定のループバック listen を保つ）
df_no_bind_env() { # <内容>
  ! df_env_value "$1" MONITOR_BIND >/dev/null
}

# ══════════════════════════════════════════════
suite "monitor-image: [自己診断] ENV 検査器（既知の悪い入力を必ず落とす）"
# ══════════════════════════════════════════════

it "[自己診断] df_db_env_ok / df_no_bind_env: 良い入力は通り、悪い入力は落ちる"
selfdiag_env() {
  local base=$'RUN mkdir /data && chown node:node /data\n'
  df_db_env_ok "${base}ENV MONITOR_DB=/data/monitor.db" || { echo "KEY=VAL 形式が通らない"; return 1; }
  df_db_env_ok "${base}ENV MONITOR_DB /data/monitor.db" || { echo "KEY VAL 形式が通らない"; return 1; }
  df_db_env_ok "${base}ENV A=1 MONITOR_DB=/data/monitor.db" || { echo "複数代入が通らない"; return 1; }
  df_db_env_ok "${base}ENV MONITOR_DB=/app/data/monitor.db" && { echo "/data 外が通った"; return 1; }
  df_db_env_ok "${base}ENV MONITOR_DB=/data" && { echo "/data そのものが通った"; return 1; }
  df_db_env_ok "${base}ENV MONITOR_DB=/data/../etc/x" && { echo "/data/.. が通った"; return 1; }
  df_db_env_ok "${base}ENV OTHER=/data/x" && { echo "別キーが通った"; return 1; }
  df_db_env_ok "ENV MONITOR_DB=/data/monitor.db" && { echo "chown 無しが通った"; return 1; }
  df_db_env_ok $'RUN chown root:root /data\nENV MONITOR_DB=/data/monitor.db' && { echo "chown 先が node でないのが通った"; return 1; }
  df_no_bind_env "ENV MONITOR_DB=/data/m.db" || { echo "BIND 無しが落ちた"; return 1; }
  df_no_bind_env "ENV MONITOR_BIND=0.0.0.0" && { echo "BIND=0.0.0.0 が通った"; return 1; }
  df_no_bind_env "ENV A=1 MONITOR_BIND=0.0.0.0" && { echo "複数代入中の BIND が通った"; return 1; }
  df_no_bind_env "ENV MONITOR_BIND 127.0.0.1" && { echo "KEY VAL 形式の BIND が通った"; return 1; }
  return 0
}
assert_ok selfdiag_env

# ══════════════════════════════════════════════
suite "monitor-image: Dockerfile の ENV（docker run が DB 指定なしでも起動できる）"
# ══════════════════════════════════════════════

it "ENV MONITOR_DB が /data 配下の絶対パスで、/data を node に chown している（docker run が DB 指定なしでも起動できる）"
if [ -n "$DF" ] && df_db_env_ok "$DF"; then pass; else fail "ENV MONITOR_DB: '$(df_env_value "$DF" MONITOR_DB)'"; fi

it "ENV MONITOR_BIND が無い（イメージ既定は 127.0.0.1 listen のまま。公開範囲を広げない）"
if [ -n "$DF" ] && df_no_bind_env "$DF"; then pass; else fail "ENV MONITOR_BIND がある: '$(df_env_value "$DF" MONITOR_BIND)'"; fi

it "Dockerfile が public/ を COPY する（Issue #21: ビューの静的ファイルがイメージに入る。.dockerignore の !public と対）"
df_copies_public() { # <内容>
  local line
  while IFS= read -r line; do
    case "$line" in
      "COPY public ./public"|"COPY public /app/public"|"COPY public public"|"COPY public ./public/"|"COPY public/ ./public/") return 0 ;;
    esac
  done <<< "$1"
  return 1
}
if [ -n "$DF" ] && df_copies_public "$DF"; then pass; else fail "COPY public ./public が無い"; fi

# ══════════════════════════════════════════════
suite "monitor-image: .dockerignore / compose 原本の存在"
# ══════════════════════════════════════════════
# ここは env 系除外の記述（**/ 付き・否定なし）だけを見る。除外の実効は smoke が docker build で確かめる（パターン文法を bash で近似しない。lessons #9）

it ".dockerignore が実ファイルとして存在し、空でない"
if [ -f "$DOCKERIGNORE" ] && [ ! -L "$DOCKERIGNORE" ] && [ -s "$DOCKERIGNORE" ]; then pass; else fail "$DOCKERIGNORE が無い・リンク・空"; fi

it ".dockerignore が .env 系を全階層で除外する（**/.env* または **/.env と **/.env.*。否定で戻さない）"
if [ -f "$DOCKERIGNORE" ] && di_ignores_env "$(cat "$DOCKERIGNORE")"; then pass; else fail "$DOCKERIGNORE に .env* が無い、または否定で戻している"; fi

it "[自己診断] di_allowlist_ok: 許可リスト（* → !server と !public → 秘密パターン）だけを通し、順序違い・否定の追加・パターン欠落は拒否する"
selfdiag_allowlist() {
  local good=$'*\n!server\n!public\n**/.env*\n**/*.pem\n**/*.key\n**/id_*\n'
  di_allowlist_ok "$good" || { echo "正しい形が拒否された"; return 1; }
  di_allowlist_ok $'# c\n*\n\n!server\n!public\n**/.env\n**/.env.*\n**/*.pem\n**/*.key\n**/id_*' || { echo "env の2行形が拒否された"; return 1; }
  di_allowlist_ok $'*\r\n!server\r\n!public\r\n**/.env*\r\n**/*.pem\r\n**/*.key\r\n**/id_*\r\n' || { echo "CRLF が拒否された"; return 1; }
  di_allowlist_ok $'test\ndocs\ndata\n**/.env*' && { echo "旧形式（許可リストでない）が通った"; return 1; }
  di_allowlist_ok $'test\n*\n!server\n!public\n**/.env*\n**/*.pem\n**/*.key\n**/id_*' && { echo "先頭が * でないのが通った"; return 1; }
  di_allowlist_ok $'*\n**/.env*\n**/*.pem\n**/*.key\n**/id_*' && { echo "!server が無いのが通った"; return 1; }
  di_allowlist_ok $'*\n**/.env*\n**/*.pem\n**/*.key\n**/id_*\n!server\n!public' && { echo "秘密パターンが !server より前（戻されてしまう）が通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n**/*.pem\n**/*.key\n**/id_*' && { echo "env 系が無いのが通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n**/.env*\n**/*.key\n**/id_*' && { echo "*.pem が無いのが通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n**/.env*\n**/*.pem\n**/id_*' && { echo "*.key が無いのが通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n**/.env*\n**/*.pem\n**/*.key' && { echo "id_* が無いのが通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n!test\n**/.env*\n**/*.pem\n**/*.key\n**/id_*' && { echo "!server 以外の否定が通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n**/.env*\n**/*.pem\n**/*.key\n**/id_*\n!server/.env' && { echo "env を戻す否定が通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n.env*\n**/*.pem\n**/*.key\n**/id_*' && { echo "直下だけの env パターンが通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n**/.env*\n**/*.pem\n**/*.key\n**/id_*\n!server\n!public\n**/.env*' && { echo "秘密パターンの後に再び !server（秘密が戻る）が通った"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n!server\n!public\n**/.env*\n**/*.pem\n**/*.key\n**/id_*' || { echo "!server の連続（秘密パターンは後ろ）が拒否された"; return 1; }
  di_allowlist_ok $'*\n!server\n**/.env*\n**/*.pem\n**/*.key\n**/id_*' && { echo "!public が無いのが通った"; return 1; }
  di_allowlist_ok $'*\n!public\n**/.env*\n**/*.pem\n**/*.key\n**/id_*' && { echo "!server が無い（!public のみ）のが通った"; return 1; }
  di_allowlist_ok $'*\n!server\n**/.env*\n**/*.pem\n**/*.key\n**/id_*\n!public' && { echo "秘密パターンが !public より前（public/ 配下の秘密が戻る）が通った"; return 1; }
  di_allowlist_ok $'*\n!public\n!server\n**/.env*\n**/*.pem\n**/*.key\n**/id_*' || { echo "!public が先の順が拒否された"; return 1; }
  di_allowlist_ok $'*\n!server\n!public\n!public/.env\n**/.env*\n**/*.pem\n**/*.key\n**/id_*' && { echo "public の秘密を戻す否定が通った"; return 1; }
  di_allowlist_ok "" && { echo "空が通った"; return 1; }
  return 0
}
assert_ok selfdiag_allowlist

it ".dockerignore が許可リスト方式（* で全除外 → !server と !public で戻す → その後ろで env 系・*.pem・*.key・id_* を除外）"
if [ -f "$DOCKERIGNORE" ] && di_allowlist_ok "$(cat "$DOCKERIGNORE")"; then pass; else fail "$DOCKERIGNORE が許可リスト形でない（先頭 * / !server / 後ろに秘密パターン）"; fi

it "compose 原本が実ファイルとして存在する（シンボリックリンクでない）"
if [ -f "$COMPOSE_SRC" ] && [ ! -L "$COMPOSE_SRC" ]; then pass; else fail "$COMPOSE_SRC が無い、またはリンク"; fi

# ══════════════════════════════════════════════
suite "monitor-image: [自己診断] compose 検査器（合成 JSON の変異を必ず落とす）"
# ══════════════════════════════════════════════

GOLD_DIR="$WORK/gold"
mkdir -p "$GOLD_DIR/.claude/memory" "$GOLD_DIR/.claude/monitor"
: > "$GOLD_DIR/.claude/monitor/Dockerfile"
: > "$GOLD_DIR/.claude/memory/loop-state.json"

for gp in 4319 4555; do
  it "[自己診断] 合成した正常な config（ポート ${gp}）は全チェックを通る"
  GJ="$(golden_json "$GOLD_DIR" "$gp")"
  bad=""
  for entry in "${COMPOSE_CHECKS[@]}"; do
    fn="${entry##*:}"
    "$fn" "$GJ" "$gp" "$GOLD_DIR" || bad="${bad} ${fn}"
  done
  assert_eq "$bad" ""
done

# 変異の jq 式 → 落ちるべき検査関数。ゴールデンは 4555（既定値とずれているので固定値の混入も検出できる）
GJ="$(golden_json "$GOLD_DIR" 4555)"
MUT_ROWS=(
  'del(.services.monitor.ports[0].host_ip)|c_bind_loopback'
  '.services.monitor.ports[0].host_ip = "0.0.0.0"|c_bind_loopback'
  '.services.monitor.ports[0].host_ip = "localhost"|c_bind_loopback'
  '.services.monitor.ports[0].published = "4319"|c_published_port'
  '.services.monitor.ports[0].target = 4319|c_target_port'
  '.services.monitor.environment.LOOP_MONITOR_PORT = "4319"|c_env_port'
  'del(.services.monitor.environment.LOOP_MONITOR_PORT)|c_env_port'
  '.services.monitor.environment.MONITOR_BIND = "127.0.0.1"|c_env_bind'
  '.services.monitor.ports += [.services.monitor.ports[0]]|c_one_port'
  '.services.monitor.ports[0].protocol = "udp"|c_tcp_only'
  '.services.extra = {}|c_single_service'
  'del(.services.monitor.read_only)|c_read_only'
  '.services.monitor.read_only = false|c_read_only'
  'del(.services.monitor.cap_drop)|c_cap_drop'
  '.services.monitor.cap_drop = ["NET_RAW"]|c_cap_drop'
  '.services.monitor.cap_add = ["SYS_ADMIN"]|c_no_cap_add'
  'del(.services.monitor.security_opt)|c_no_new_priv'
  '.services.monitor.security_opt = ["seccomp=unconfined"]|c_no_new_priv'
  '.services.monitor.privileged = true|c_not_privileged'
  '.services.monitor.network_mode = "host"|c_not_privileged'
  '.services.monitor.pid = "host"|c_not_privileged'
  '.services.monitor.volumes |= map(select(.type != "volume"))|c_one_named_volume'
  '.services.monitor.volumes |= map(if .type == "volume" then .read_only = true else . end)|c_one_named_volume'
  'del(.volumes["monitor-data"])|c_one_named_volume'
  '.services.monitor.environment.MONITOR_DB = "/tmp/monitor.db"|c_db_in_volume'
  '.services.monitor.environment.MONITOR_DB = "/data"|c_db_in_volume'
  '.services.monitor.environment.MONITOR_DB = "monitor.db"|c_db_in_volume'
  'del(.services.monitor.environment.MONITOR_DB)|c_db_in_volume'
  '.services.monitor.environment.MONITOR_DB = "/data/sub/monitor.db"|c_db_in_volume'
  '.services.monitor.volumes |= map(if .type == "bind" then del(.read_only) else . end)|c_memory_bind_ro'
  '.services.monitor.volumes |= map(if .type == "bind" then .read_only = false else . end)|c_memory_bind_ro'
  '.services.monitor.volumes |= map(select(.type != "bind"))|c_memory_bind_ro'
  '.services.monitor.volumes += [{type:"bind",source:"/var/run/docker.sock",target:"/var/run/docker.sock",read_only:true}]|c_only_memory_bind'
  '.services.monitor.volumes |= map(if .type == "bind" then .source = "/" else . end)|c_only_memory_bind'
  '.services.monitor.volumes |= map(if .type == "bind" then .target = "/data" else . end)|c_mount_targets'
  '.services.monitor.volumes |= map(if .type == "bind" then .target = "/data/memory" else . end)|c_mount_targets'
  '.services.monitor.volumes |= map(if .type == "bind" then .source += "/loop-state.json" else . end)|c_memory_dir'
  '.services.monitor.volumes |= map(if .type == "bind" then .source = "/nonexistent-dir/.claude/memory" else . end)|c_memory_dir'
  '.services.monitor.user = "root"|c_user_not_root'
  '.services.monitor.user = "0"|c_user_not_root'
  '.services.monitor.user = "0:0"|c_user_not_root'
  '.services.monitor.build.context = "/"|c_build_context'
  'del(.services.monitor.build)|c_build_context'
  '.services.monitor.build.context += "/server"|c_build_context'
  '.services.monitor.build.dockerfile = "../Dockerfile"|c_dockerfile'
  '.services.monitor.build.dockerfile = "/etc/passwd"|c_dockerfile'
  '.services.monitor.build.dockerfile = "Missing.Dockerfile"|c_dockerfile'
  '.services.monitor.networks = {default: null}|c_dedicated_net'
  'del(.services.monitor.networks)|c_dedicated_net'
  '.services.monitor.networks = {}|c_dedicated_net'
  '.services.monitor.networks = {"monitor-net": null, default: null}|c_dedicated_net'
  '.services.monitor.networks = {"undefined-net": null}|c_dedicated_net'
  'del(.networks["monitor-net"])|c_dedicated_net'
  '.networks["monitor-net"].internal = true|c_net_not_internal'
  '.networks["monitor-net"].external = true|c_net_not_internal'
  'del(.services.monitor.networks)|c_net_not_internal'
  '.services.app = {networks: {default: null}} | .services.monitor.networks = {default: null}|c_net_isolated'
  '.services.app = {} | .services.monitor.networks = {default: null}|c_net_isolated'
  '.services.app = {} | del(.services.monitor.networks)|c_net_isolated'
  '.services.app = {networks: {"monitor-net": null}}|c_net_isolated'
  '.services.app = {networks: {default: null, "monitor-net": null}}|c_net_isolated'
)
MUT_BAD=""
for row in "${MUT_ROWS[@]}"; do
  expr="${row%|*}"
  fn="${row##*|}"
  mutated="$(printf '%s' "$GJ" | jq -c "$expr" 2>/dev/null)"
  if [ -z "$mutated" ]; then MUT_BAD="${MUT_BAD} 変異が作れない:${expr};"; continue; fi
  if "$fn" "$mutated" 4555 "$GOLD_DIR"; then MUT_BAD="${MUT_BAD} 落ちるべきなのに通った(${fn}):${expr};"; fi
done
it "[自己診断] ${#MUT_ROWS[@]} 件の変異（127.0.0.1 外し・ポートずれ・read_only 外し等）が対応するチェックで FAIL する"
assert_eq "$MUT_BAD" ""

it "[自己診断] c_net_isolated: app が default だけ・別の専用ネットワークだけなら通る（誤爆しない）"
bad=""
c_net_isolated "$(printf '%s' "$GJ" | jq -c '.services.app = {networks: {default: null}}')" 4555 "$GOLD_DIR" || bad="${bad} app が default"
c_net_isolated "$(printf '%s' "$GJ" | jq -c '.services.app = {} | .services.worker = {networks: {"app-net": null}}')" 4555 "$GOLD_DIR" || bad="${bad} app 無指定・別ネット"
assert_eq "$bad" ""

it "[自己診断] di_ignores_env: **/.env* か（**/.env と **/.env.*）だけを通す。直下だけ・無い・コメント・否定・片方だけは FAIL"
selfdiag_di() {
  di_ignores_env $'test\n**/.env*\ndata' || { echo "**/.env* が通らない"; return 1; }
  di_ignores_env $'**/.env\n**/.env.*' || { echo "**/.env + **/.env.* が通らない"; return 1; }
  di_ignores_env $'test\r\n**/.env*\r\n' || { echo "CRLF が通らない"; return 1; }
  di_ignores_env $'test\ndata\n.env*' && { echo "直下だけの .env* が通った"; return 1; }
  di_ignores_env $'.env\n.env.*' && { echo "直下だけの .env + .env.* が通った"; return 1; }
  di_ignores_env $'/.env*' && { echo "直下固定の /.env* が通った"; return 1; }
  di_ignores_env $'test\ndocs' && { echo ".env 無しが通った"; return 1; }
  di_ignores_env $'# **/.env*' && { echo "コメントが通った"; return 1; }
  di_ignores_env $'**/.env' && { echo "**/.env だけが通った"; return 1; }
  di_ignores_env $'**/.env.*' && { echo "**/.env.* だけが通った"; return 1; }
  di_ignores_env $'**/.env*\n!**/.env.production' && { echo "否定で戻すのが通った"; return 1; }
  di_ignores_env "" && { echo "空が通った"; return 1; }
  return 0
}
assert_ok selfdiag_di

it "[自己診断] 空 JSON・壊れた JSON を全チェックが拒否する（判定不能を合格にしない）"
bad=""
for entry in "${COMPOSE_CHECKS[@]}"; do
  fn="${entry##*:}"
  for junk in "" "not json" "{}" "null" '{"services":{}}'; do
    if "$fn" "$junk" 4319 "$GOLD_DIR"; then bad="${bad} ${fn}:'${junk}'"; fi
  done
done
assert_eq "$bad" ""

# ══════════════════════════════════════════════
suite "monitor-image: 原本 compose（原本の置き場所 + --project-directory .）"
# ══════════════════════════════════════════════
# 受け入れ条件: docker compose -f .claude/monitor/compose.monitor.yml --project-directory . config

ORIG_ARGS=(-f "$COMPOSE_SRC" --project-directory .)

compose_case "[原本/既定ポート]" "$DEFAULT_PORT" "$REPO_ROOT" UNSET "${ORIG_ARGS[@]}"
compose_case "[原本/LOOP_MONITOR_PORT=4555]" 4555 "$REPO_ROOT" 4555 "${ORIG_ARGS[@]}"

# ${VAR:-既定} は「未設定」と「空文字」の両方で既定に倒れる（${VAR-既定} は空文字で倒れない）
compose_case "[原本/LOOP_MONITOR_PORT が空文字]" "$DEFAULT_PORT" "$REPO_ROOT" "" "${ORIG_ARGS[@]}"

it "ポートを変えると config の出力が実際に変わる（固定値の埋め込みでない）"
J_A="$(compose_config "$REPO_ROOT" UNSET "${ORIG_ARGS[@]}")"
J_B="$(compose_config "$REPO_ROOT" 4555 "${ORIG_ARGS[@]}")"
PUB_A="$(printf '%s' "$J_A" | jq -r '.services.monitor.ports[0].published // "none"' 2>/dev/null)"
PUB_B="$(printf '%s' "$J_B" | jq -r '.services.monitor.ports[0].published // "none"' 2>/dev/null)"
if [ "$PUB_A" = "$DEFAULT_PORT" ] && [ "$PUB_B" = "4555" ]; then pass; else fail "既定: '${PUB_A}' / 4555 指定: '${PUB_B}'"; fi

# ══════════════════════════════════════════════
suite "monitor-image: 複製時のパス解決（原本をプロジェクト直下へ複製 / include 経由）"
# ══════════════════════════════════════════════
# 推測しない（lessons #6）。リポジトリ構造を一時ディレクトリに再現し、実際に compose config を回す。
# 複製は #24（bootstrap）が行う。ここでは「バイト一致で複製した原本が、直下から ./.claude/monitor を指す」ことを固定する

mk_replica() { # <ディレクトリ> <include を使うか: yes|no>
  local d="$1"
  mkdir -p "$d/.claude/monitor" "$d/.claude/memory"
  if [ -f "$COMPOSE_SRC" ]; then cp "$COMPOSE_SRC" "$d/compose.monitor.yml"; fi
  if [ -f "$DOCKERFILE" ]; then cp "$DOCKERFILE" "$d/.claude/monitor/Dockerfile"; fi
  if [ -f "$DOCKERIGNORE" ]; then cp "$DOCKERIGNORE" "$d/.claude/monitor/.dockerignore"; fi
  : > "$d/.claude/memory/loop-state.json"
  if [ "$2" = "yes" ]; then printf 'include:\n  - compose.monitor.yml\n' > "$d/compose.yaml"; fi
}

REPL_DIRECT="$WORK/replica-direct"
REPL_INCLUDE="$WORK/replica-include"
mk_replica "$REPL_DIRECT" no
mk_replica "$REPL_INCLUDE" yes

compose_case "[複製/直下の compose.monitor.yml を -f 指定]" "$DEFAULT_PORT" "$REPL_DIRECT" UNSET -f compose.monitor.yml
compose_case "[複製/LOOP_MONITOR_PORT=4555]" 4555 "$REPL_DIRECT" 4555 -f compose.monitor.yml
compose_case "[複製/compose.yaml の include 経由]" "$DEFAULT_PORT" "$REPL_INCLUDE" UNSET
compose_case "[複製/include 経由・LOOP_MONITOR_PORT=4555]" 4555 "$REPL_INCLUDE" 4555

# 導入先のアプリ（app）が同居した状況を再現する。monitor が default に居ると app と同じネットワークに入る（G5 retry 2）
mk_app_override() { # <ディレクトリ> <direct|include>
  local dir="$1" mode="$2"
  case "$mode" in
    direct) printf 'services:\n  app:\n    image: node:24-alpine\n' > "${dir}/compose.app.yml" ;;
    include) printf 'include:\n  - compose.monitor.yml\nservices:\n  app:\n    image: node:24-alpine\n' > "${dir}/compose.yaml" ;;
  esac
}

REPL_DIRECT_APP="$WORK/replica-direct-app"
REPL_INCLUDE_APP="$WORK/replica-include-app"
mk_replica "$REPL_DIRECT_APP" no
mk_app_override "$REPL_DIRECT_APP" direct
mk_replica "$REPL_INCLUDE_APP" yes
mk_app_override "$REPL_INCLUDE_APP" include

net_case() { # <ラベル> <直下> <ポート|UNSET> <docker compose の引数...>
  local label="$1" dir="$2" port="$3" json rc
  shift 3
  json="$(compose_config "$dir" "$port" "$@")"
  rc=$?
  it "${label} docker compose config が成功し、monitor と app の両方が居る（検査が空振りでない）"
  if [ "$rc" -ne 0 ] || ! jqe "$json" '(.services.monitor | type == "object") and (.services.app | type == "object")'; then
    fail "終了コード ${rc}" "$(head -n 3 "$ERR_FILE" 2>/dev/null | cut -c1-200)"
    return 0
  fi
  pass
  it "${label} monitor は default に属さず専用ネットワーク1つだけ"
  if c_dedicated_net "$json"; then pass; else fail "monitor の networks" "$(printf '%s' "$json" | jq -c '.services.monitor.networks' 2>/dev/null)"; fi
  it "${label} 専用ネットワークは internal: true でも external でもない"
  if c_net_not_internal "$json"; then pass; else fail "トップレベル networks" "$(printf '%s' "$json" | jq -c '.networks' 2>/dev/null | cut -c1-300)"; fi
  it "${label} monitor と app の networks のキー集合が交わらない（同じネットワークに同居しない）"
  if c_net_isolated "$json"; then
    pass
  else
    fail "monitor: $(printf '%s' "$json" | jq -c '.services.monitor.networks' 2>/dev/null) / app: $(printf '%s' "$json" | jq -c '.services.app.networks' 2>/dev/null)"
  fi
}

net_case "[app 同居/直下複製]" "$REPL_DIRECT_APP" UNSET -f compose.monitor.yml -f compose.app.yml
net_case "[app 同居/直下複製・LOOP_MONITOR_PORT=4555]" "$REPL_DIRECT_APP" 4555 -f compose.monitor.yml -f compose.app.yml
net_case "[app 同居/include 経由]" "$REPL_INCLUDE_APP" UNSET
net_case "[app 同居/include 経由・LOOP_MONITOR_PORT=4555]" "$REPL_INCLUDE_APP" 4555

it "複製は原本とバイト一致（複製側の検査が原本の検査として通用する）"
if [ -f "$COMPOSE_SRC" ] && cmp -s "$COMPOSE_SRC" "$REPL_DIRECT/compose.monitor.yml"; then pass; else fail "原本が無い、または複製が一致しない"; fi


# ══════════════════════════════════════════════
suite "monitor-image: security.md「監視の限界」のコンテナ側の限界"
# ══════════════════════════════════════════════
# 節の切り出しは awk（lessons #10: grep の行単位判定で節境界を近似しない）。
# 「## 監視の限界…」節の配下の、見出しに「コンテナ」を含む小節（見出し自体が監視の限界かつコンテナでも可）を取る。
# 見出し名は固定しない。語の判定は case（部分文字列）

SECURITY_MD=".claude/rules/security.md"

container_limits() { # <ファイル>
  awk '
    /^## / { in_lim = ($0 ~ /監視の限界/); p = (in_lim && $0 ~ /コンテナ/); next }
    /^### / { p = (in_lim && $0 ~ /コンテナ/); next }
    p { print }
  ' "$1"
}

# 必須語が全て本文にあるか。欠けた語を $MISSING に入れ、1つでも欠ければ 1
# 先頭9語は初版のコンテナ側の限界（ローカル bind・認証なし・硬化設定）。
CONTAINER_TERMS=("127.0.0.1" "MONITOR_BIND" "0.0.0.0" "認証" "非 root" "cap_drop" "no-new-privileges" "digest" "compose"
  # 次の5語（専用ネットワーク〜internal）は G5 retry 2: 同じ Docker ネットワークの別コンテナが Host を偽って到達できる限界と、専用ネットワーク・internal を使わない理由
  "専用ネットワーク" "Docker ネットワーク" "Host を偽" "認証ではない" "internal"
  # 末尾4語は G5 retry 3: 別ネットワークのコンテナが host.docker.internal 経由で届く限界（monitor-net で止まるのはコンテナ間の直接通信だけ。
  #   Docker Desktop で実測、Linux Engine は未実測）。実測の固定はスモーク側。ここは語の有無だけ
  "host.docker.internal" "Docker Desktop" "コンテナ間の直接通信" "未実測")
container_terms_ok() { # <本文>
  local t
  MISSING=""
  case "$1" in *"read_only"*|*"読み取り専用"*) ;; *) MISSING="read_only|読み取り専用" ;; esac
  for t in "${CONTAINER_TERMS[@]}"; do
    case "$1" in *"$t"*) ;; *) MISSING="$MISSING $t" ;; esac
  done
  # compose を使わず全インターフェースへ公開すると止まらない、という趣旨（docker run -p 等）
  case "$1" in *"docker run"*|*"-p "*) ;; *) MISSING="$MISSING docker-run(-p)" ;; esac
  [ -z "$MISSING" ]
}

CONTAINER_SEC="$(container_limits "$SECURITY_MD")"

it "「監視の限界」節の配下に、コンテナ側の限界を書く小節がある（空なら FAIL）"
if [ -n "$CONTAINER_SEC" ]; then pass; else fail "コンテナ側の小節が無い、または空"; fi

it "コンテナ側の小節が必須語（ローカル bind・認証なし・硬化設定・docker run -p の限界）を全て含む"
if container_terms_ok "$CONTAINER_SEC"; then pass; else fail "欠けている語:$MISSING"; fi

it "[自己診断] container_terms_ok: 全語ありは通り、語を1つ消した合成本文・空本文は FAIL する"
selfdiag_container() {
  local full="" t drop mut
  for t in "${CONTAINER_TERMS[@]}"; do full="$full $t"; done
  full="$full read_only docker run"
  container_terms_ok "$full" || { echo "全語ありが FAIL した: $MISSING"; return 1; }
  for drop in "${CONTAINER_TERMS[@]}" read_only "docker run"; do
    mut="${full//"$drop"/}"
    if container_terms_ok "$mut"; then echo "「${drop}」を消しても通った"; return 1; fi
  done
  container_terms_ok "${full//read_only/読み取り専用}" || { echo "読み取り専用の代替が通らない: $MISSING"; return 1; }
  if container_terms_ok ""; then echo "空本文が通った"; return 1; fi
  return 0
}
assert_ok selfdiag_container

it "[自己診断] container_limits: 監視の限界の外のコンテナ見出し・次の小節の本文は拾わない"
selfdiag_section() {
  local f="$WORK/sec.md" out
  printf '%s\n' '## 別の節' '### コンテナ側' 'OUT' '## 監視の限界（受信側）' '### 既知の限界' 'NO' '### コンテナ側' 'IN' '### 次' 'NO2' > "$f"
  out="$(container_limits "$f")"
  [ "$out" = "IN" ] || { echo "想定外の抽出: '$out'"; return 1; }
}
assert_ok selfdiag_section

report
