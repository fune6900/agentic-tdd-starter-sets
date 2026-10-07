#!/usr/bin/env bash
# 監視イメージのスモーク: ビルド → 起動 → ヘルス待ち → /api/state 200 → 実ユーザー → 再起動 → 後始末（Issue #20 / Red）
#
# Docker デーモンが必須。重い（初回はベースイメージの取得とビルドで数分）ので、静的検査
# （monitor-image.test.sh）とは別スイートにしてある。
#
#   bash tests/run.sh monitor-image-smoke      ← CI の monitor-smoke ジョブと同じ呼び方（lessons #18: 手元でも回せる形）
#   bash tests/run.sh                          ← 全スイート。このスイートも含まれる（Docker が無ければ FAIL）
#
# ── 前提（lessons #10: 判定不能は合格にしない）────────────────────────────────
#   docker / compose / デーモンが無い、ビルド・起動が失敗する、ヘルスが上限内に healthy にならない場合は、
#   スキップではなく FAIL。判定関数は自己診断で縛る（PATH から docker を外す・デーモンが死んだ docker を差す）
#
# ── 何を確かめるか ─────────────────────────────────────────────────────────
#   .dockerignore  実際のビルドコンテキストから test/ docs/ data/ と、全階層（直下・server/ 配下・さらに深い階層）の env 系の囮が消え、server/ は残る（scratch への COPY を書き出して確認。
#                  .dockerignore を外した場合に test/ docs/ が現れることも確認し、検査が空振りでないことを固定）
#   ビルド         原本 compose（-f .claude/monitor/compose.monitor.yml --project-directory .）で build が通る
#                  = digest がレジストリに実在する
#   起動・ヘルス   HEALTHCHECK が効いている（Health が存在する）。上限 HEALTH_WAIT_SECONDS 秒で healthy になる
#                  ランダムな空きポート（LOOP_MONITOR_PORT）で回す = 内外ポート同一・HEALTHCHECK のポート追従の実証
#   HTTP           ホストの 127.0.0.1:<ポート>/api/state が 200 かつ JSON。Host が偽なら 403（検査が生きている）
#                  公開は 127.0.0.1 に bind（docker compose port）
#   実ユーザー     コンテナ内 id -u が 0 でない。DB の所有 UID がプロセスの UID と一致（ボリュームの所有者ずれ = chmod 失敗の再発防止）
#                  CapEff が空・NoNewPrivs=1・ルートファイルシステムに書けない・curl が無い
#   別ネットワーク 別の Docker ネットワークの使い捨てコンテナから host.docker.internal:<ポート>/api/state を叩く（--add-host host.docker.internal:host-gateway 付き）。
#                  (i) Host 偽装なしは 403 か到達不能（200 にならない）。(ii) Host: 127.0.0.1:<ポート> は Docker Desktop で 200（限界の実測固定）。
#                  Docker Desktop 以外（Linux Engine）は未実測なので値を決め打たない。観測値を出力し、security.md の記述との矛盾だけを検査する（lessons #10）
#                  プラットフォームは docker info の OperatingSystem から決める（推測しない）。判定不能は FAIL
#   再起動         down（ボリュームは残す）→ up で既存 DB の上でも起動し healthy になる
#   後始末         コンテナ・ボリューム・ネットワーク・イメージが残らない（trap でも必ず実行）
#
# ── 変異テスト対応表（隔離コピー: REPO_ROOT=<コピー> bash tests/scripts/monitor-image-smoke.test.sh）──────
#   USER 行を消す                  → 「コンテナ内 id -u が 0 でない」
#   digest を外す / 偽の digest    → 「ビルドが成功する」（実在しない digest はビルドで落ちる）
#   127.0.0.1 を外す               → 「公開は 127.0.0.1 に bind」
#   公開ポートと内側ポートのずれ   → 「/api/state が 200」（Host 検査がポート込みなのでホストから 403 または接続不能）
#   HEALTHCHECK のポート決め打ち   → 「上限内に healthy」（ランダムポートでは不健康のまま）
#   ボリュームの所有者ずれ         → 「上限内に healthy」または「DB の所有 UID」
#   .dockerignore から test を外す → 「ビルドコンテキストに test/ が無い」
#   .dockerignore の許可リスト(*)を外す → 「秘密鍵・証明書の囮が入らない」（server/ 配下の *.pem *.key id_* の囮）
#   文書の docker run に ; 任意コマンド や -v /:/host を足す → 「実行前に許可形で拒否」（実行せず FAIL）
#   env 系の除外を直下だけ（.env*）にする → 「全階層で env 系の囮が入らない」（Docker はパターンを直下基準で解釈する。**/ が要る）

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

cd "$REPO_ROOT" || exit 1

MONITOR_DIR=".claude/monitor"
COMPOSE_SRC="$MONITOR_DIR/compose.monitor.yml"
HEALTH_WAIT_SECONDS=120
PROJ="monitorsmoke$$"
PORT=""
STARTED=0
RUN_IMAGE=""
PROBE_NET=""

WORK="$(mktemp -d)" || { echo "mktemp に失敗した" >&2; exit 1; }
SANDBOXES+=("$WORK")
EMPTY_ENV="$WORK/empty.env"
: > "$EMPTY_ENV"

# 原本 compose を、環境の COMPOSE_* や .env に左右されず回す
COMPOSE() {
  ( cd "$REPO_ROOT" && env -u COMPOSE_FILE -u COMPOSE_PROJECT_NAME -u COMPOSE_PROFILES -u COMPOSE_PATH_SEPARATOR -u COMPOSE_ENV_FILES \
      LOOP_MONITOR_PORT="$PORT" \
      docker compose --env-file "$EMPTY_ENV" -p "$PROJ" -f "$COMPOSE_SRC" --project-directory . "$@" )
}

# RUN_IMAGE 由来のコンテナを全て強制削除（BSD/GNU xargs の差を避けて変数に取る）
rm_run_containers() {
  local ids
  ids="$(docker ps -aq --filter "ancestor=${RUN_IMAGE}" 2>/dev/null)"
  # shellcheck disable=SC2086 # ids は改行区切りの複数IDで、意図的に単語分割する
  [ -z "$ids" ] || docker rm -fv $ids >/dev/null 2>&1
}

# 後始末（冪等）。起動した形跡がある時だけ compose down を呼ぶ。成否は後片付けの it で別に確かめる
smoke_cleanup() {
  if [ -n "${RUN_IMAGE:-}" ]; then
    rm_run_containers
    docker rmi -f "$RUN_IMAGE" >/dev/null 2>&1
    RUN_IMAGE=""
  fi
  if [ -n "${PROBE_NET:-}" ]; then
    docker rm -f "${PROJ}-probe-ctr" >/dev/null 2>&1
    docker network rm "$PROBE_NET" >/dev/null 2>&1
    PROBE_NET=""
  fi
  if [ "$STARTED" -eq 1 ]; then
    COMPOSE down -v --rmi all --remove-orphans >/dev/null 2>&1
    STARTED=0
  fi
  cleanup_sandboxes
}
trap smoke_cleanup EXIT
trap 'smoke_cleanup; exit 130' INT
trap 'smoke_cleanup; exit 143' TERM

# 127.0.0.1 の空きポート。見つからなければ 1
pick_free_port() {
  local p
  for _ in $(seq 1 30); do
    p=$((20000 + RANDOM % 30000))
    if ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# コンテナが healthy になるまで待つ。上限内に healthy なら 0。理由を標準出力へ
wait_healthy() { # <コンテナ ID> <上限秒>
  local cid="$1" max="$2" waited=0 health state
  while [ "$waited" -lt "$max" ]; do
    state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
    case "$health" in
      healthy) echo "healthy"; return 0 ;;
      none) echo "HEALTHCHECK が効いていない（State.Health が無い）"; return 1 ;;
      unhealthy) echo "unhealthy（state=${state}）"; return 1 ;;
    esac
    case "$state" in
      exited|dead) echo "コンテナが停止した（state=${state}）"; return 1 ;;
    esac
    sleep 2
    waited=$((waited + 2))
  done
  echo "上限 ${max} 秒内に healthy にならない（health=${health} state=${state}）"
  return 1
}

# ホストからの HTTP。<ステータスコード> を出し、本文は $BODY_FILE へ。接続できなければ 000
BODY_FILE="$WORK/body.json"
http_code() { # <パス> [curl の追加引数...]
  local path="$1"
  shift
  curl -sS -o "$BODY_FILE" -w '%{http_code}' --max-time 5 "$@" "http://127.0.0.1:${PORT}${path}" 2>/dev/null || true
}

# ホストからの HTTP（ポート指定版）。<ステータスコード> を出す。接続できなければ 000
http_code_at() { # <ポート> <パス> [curl の追加引数...]
  local port="$1" path="$2"
  shift 2
  curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$@" "http://127.0.0.1:${port}${path}" 2>/dev/null || true
}

# 起動したコンテナ（イメージ祖先で引く）の最新 1 件
last_run_container() { docker ps -aq -l --filter "ancestor=${RUN_IMAGE}" 2>/dev/null; }

# コンテナ内から自身の /api/state を叩いて 200 か（Host は 127.0.0.1:<コンテナ内ポート>）
inside_state_ok() { # <コンテナ> <コンテナ内ポート>
  docker exec "$1" node -e "require('http').get({host:'127.0.0.1',port:$2,path:'/api/state'},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))" >/dev/null 2>&1
}

# security.md「コンテナ側」小節のコードブロックから `docker run` を1コマンド1行で取り出す（継続行は連結）
# 契約: ```（言語指定は任意）で囲んだブロックの中に、行頭 `docker run` で書く。<port> と <image> は置換される
extract_doc_runs() { # <security.md>
  awk '
    /^## / { insec = 0; infence = 0; next }
    /^### / { insec = ($0 ~ /^### コンテナ側/); infence = 0; next }
    !insec { next }
    /^```/ { infence = !infence; buf = ""; next }
    !infence { next }
    {
      line = $0
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      if (buf == "" && line !~ /^docker run/) next
      if (line ~ /\\ ?$/) { sub(/ ?\\ ?$/, "", line); buf = buf line " "; next }
      print buf line
      buf = ""
    }
  ' "$1"
}

# 文書（または固定文字列）のコマンドを書いたとおり実行する。<port> と <image> だけ置換。cid は RUN_CID、終了コードは RUN_RC
run_cmd() { # <コマンド文字列> <ポート>
  local cmd="${1//<port>/$2}"
  cmd="${cmd//<image>/$RUN_IMAGE}"
  ( cd "$WORK" && bash -c "$cmd" ) >"$WORK/run.out" 2>&1
  RUN_RC=$?
  RUN_CID="$(last_run_container)"
}

stop_runs() { rm_run_containers; }

# 文書の docker run の許可形。外れた行は実行しない（文書由来の文字列を bash -c に渡す前の門）。
# 値は英数字と _ . : / - と <port> だけ。空白・; | & $ ` ( ) < > ' " \ 改行・タブは通さない。-v / --privileged 等のオプションも通さない。
# 照合は文字列全体（case と [[ =~ ]]。行単位の grep で判定しない）
DOC_RUN_RE='^docker run( -d| -e [A-Z_]+=([A-Za-z0-9_./:-]|<port>)+| -p 127\.0\.0\.1:<port>:<port>)+ <image>$'
doc_run_allowed() { # <1コマンド文字列>
  case "$1" in *$'\n'*|*$'\r'*|*$'\t'*|'') return 1 ;; esac
  [[ $1 =~ $DOC_RUN_RE ]]
}

# プラットフォーム。docker info の OperatingSystem から決める。desktop / other / unknown（取れない）
docker_platform() {
  local os
  os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)" || { echo unknown; return 0; }
  case "$os" in
    "Docker Desktop"*) echo desktop ;;
    '') echo unknown ;;
    *) echo other ;;
  esac
}

# 別ネットワークのコンテナから host.docker.internal 経由で /api/state を叩く。標準出力に CODE=<ステータス>（接続不能は 000）。
# 起動できない・出力が無いときは何も出さず 1。イメージは監視イメージ自身を流用（node がある。追加の pull を要さない）
PROBE_JS='const h={};if(process.env.PROBE_HOST)h.Host=process.env.PROBE_HOST;require("http").get({host:"host.docker.internal",port:Number(process.env.PROBE_PORT),path:"/api/state",headers:h,timeout:5000},r=>{console.log("CODE="+r.statusCode);r.resume()}).on("error",()=>console.log("CODE=000")).on("timeout",function(){this.destroy()})'
probe_cross_net() { # <イメージ> <ネットワーク> <ポート> <Host 値（空なら既定）>
  local out
  out="$(docker run --rm --name "${PROJ}-probe-ctr" --network "$2" --add-host host.docker.internal:host-gateway --entrypoint node \
    -e "PROBE_PORT=$3" -e "PROBE_HOST=$4" "$1" -e "$PROBE_JS" 2>/dev/null)" || return 1
  case "$out" in CODE=[0-9][0-9][0-9]) printf '%s' "${out#CODE=}" ;; *) return 1 ;; esac
}

# security.md「コンテナ側」から、host.docker.internal を含むリスト項目（継続行を連結）を取り出す
extract_host_bullet() { # <security.md>
  awk '
    function flush() { if (b != "" && b ~ /host\.docker\.internal/) print b; b = "" }
    /^## / { flush(); insec = 0; infence = 0; next }
    /^### / { flush(); insec = ($0 ~ /^### コンテナ側/); infence = 0; next }
    !insec { next }
    /^```/ { flush(); infence = !infence; next }
    infence { next }
    /^- / { flush(); b = $0; next }
    /^[[:space:]]+[^[:space:]]/ { sub(/^[[:space:]]+/, ""); if (b != "") b = b " " $0; next }
    { flush() }
    END { flush() }
  ' "$1"
}

# 観測値と文書の矛盾検査。0 なら矛盾なし。理由は CLAIM_MSG
# 契約: 到達できる／できないは「到達できる」「到達できない」「届かない」「Linux では到達できる」等の固定語で書く
claim_consistent() { # <desktop|other|unknown> <(ii)の観測コード> <項の本文>
  local plat="$1" code="$2" b="$3"
  CLAIM_MSG=""
  case "$plat" in desktop|other) ;; *) CLAIM_MSG="プラットフォームを判定できない"; return 1 ;; esac
  [ -n "$b" ] || { CLAIM_MSG="host.docker.internal を書いた項が文書に無い"; return 1; }
  case "$code" in [0-9][0-9][0-9]) ;; *) CLAIM_MSG="観測値が取れていない: '${code}'"; return 1 ;; esac
  if [ "$code" = "200" ]; then
    case "$b" in *"到達できない"*|*"届かない"*) CLAIM_MSG="観測は到達（200）なのに文書が到達しないと書いている"; return 1 ;; esac
    case "$plat" in
      desktop) case "$b" in *"到達できる"*) ;; *) CLAIM_MSG="Docker Desktop で到達（200）したのに『到達できる』が無い"; return 1 ;; esac ;;
      other) case "$b" in *"Linux では到達できない"*) CLAIM_MSG="Linux で到達したのに文書が到達できないと書いている"; return 1 ;; esac ;;
    esac
  else
    case "$plat" in
      desktop) case "$b" in *"到達できる"*) CLAIM_MSG="Docker Desktop で到達しなかった（${code}）のに文書が『到達できる』と書いている"; return 1 ;; esac ;;
      other) case "$b" in *"Linux でも到達できる"*|*"Linux では到達できる"*) CLAIM_MSG="Linux で到達しなかった（${code}）のに文書が到達できると書いている"; return 1 ;; esac ;;
    esac
  fi
  return 0
}

# ══════════════════════════════════════════════
suite "monitor-image-smoke: 前提（docker / compose / デーモン。無ければ FAIL）"
# ══════════════════════════════════════════════

it "docker・compose プラグイン・デーモンが使える"
GATE_MSG="$(docker_daemon_gate 2>&1)"
GATE_RC=$?
if [ "$GATE_RC" -eq 0 ]; then pass; else fail "$GATE_MSG"; fi

it "curl と jq が使える"
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then pass; else fail "curl / jq が PATH に無い"; fi

it "[自己診断] PATH から docker を外すと docker_daemon_gate は FAIL（1）を返す。スキップにならない"
EMPTY_BIN="$WORK/emptybin"
mkdir -p "$EMPTY_BIN"
( PATH="$EMPTY_BIN"; docker_daemon_gate >/dev/null 2>&1 )
assert_eq "$?" "1"

it "[自己診断] compose が使えてもデーモンに繋がらなければ docker_daemon_gate は FAIL（1）、compose_gate は 0"
STUB_BIN="$WORK/stubbin"
mkdir -p "$STUB_BIN"
printf '#!/bin/sh\ncase "$1" in\n  compose) exit 0 ;;\n  *) exit 1 ;;\nesac\n' > "$STUB_BIN/docker"
chmod +x "$STUB_BIN/docker"
( PATH="$STUB_BIN"; docker_daemon_gate >/dev/null 2>&1 )
DAEMON_RC=$?
( PATH="$STUB_BIN"; compose_gate >/dev/null 2>&1 )
COMPOSE_RC=$?
assert_eq "${DAEMON_RC}/${COMPOSE_RC}" "1/0"

it "[自己診断] wait_healthy: 存在しないコンテナは上限まで待たずに healthy 扱いにしない（1 を返す）"
WAIT_OUT="$(wait_healthy "no-such-container-$$" 2 2>&1)"
WAIT_RC=$?
if [ "$WAIT_RC" -eq 1 ]; then pass; else fail "終了コード ${WAIT_RC}" "$WAIT_OUT"; fi

if [ "$GATE_RC" -ne 0 ] || ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  report
  exit 1
fi

# ══════════════════════════════════════════════
suite "monitor-image-smoke: .dockerignore の実効（docker build でビルドコンテキストを書き出して確かめる）"
# ══════════════════════════════════════════════
# 「test/ docs/ が除外される」を grep で近似しない。BuildKit が実際に送ったコンテキストを見る

probe_context() { # <コンテキスト> <出力先> → 0 なら書き出せた
  local ctx="$1" out="$2"
  printf 'FROM scratch\nCOPY . /\n' > "$WORK/probe.Dockerfile"
  DOCKER_BUILDKIT=1 docker build -q -f "$WORK/probe.Dockerfile" -o "type=local,dest=${out}" "$ctx" >"$WORK/probe.log" 2>&1
}

PROBE_CTX="$WORK/ctx"
mkdir -p "$PROBE_CTX"
if [ -d "$MONITOR_DIR" ]; then cp -R "$MONITOR_DIR/." "$PROBE_CTX/"; fi
# 手元に実 DB があっても、検査を左右させない。決まった囮だけを置く
if [ -d "$PROBE_CTX/data" ]; then find "$PROBE_CTX/data" -depth -delete; fi
mkdir -p "$PROBE_CTX/data"
: > "$PROBE_CTX/data/decoy.db"
# env 系の囮は、取り込まれる全ての階層に置く（lessons: 除外は全階層に囮を置いて確かめる）。
# パターンはコンテキスト直下基準なので、直下だけで検査すると server/ 配下の漏れを見逃す
ENV_DECOYS=(
  ".env"
  ".env.local"
  "server/.env"
  "server/.env.local"
  "server/sub/deeper/.env"
  "server/sub/deeper/.env.production"
)
mkdir -p "$PROBE_CTX/server/sub/deeper"
for d in "${ENV_DECOYS[@]}"; do : > "$PROBE_CTX/$d"; done
# 秘密鍵・証明書の囮（多層防御）。ファイル名に env 系を含まないので、env 系の除外では落ちない。server/ 配下（許可リストで戻される場所）にも置く
SECRET_DECOYS=(
  "cert.pem"
  "id_rsa"
  "server/cert.pem"
  "server/tls.key"
  "server/id_rsa"
  "server/id_ed25519"
  "server/sub/deeper/key.pem"
  "server/sub/deeper/server.key"
  "server/sub/deeper/id_ecdsa"
)
for d in "${SECRET_DECOYS[@]}"; do : > "$PROBE_CTX/$d"; done

PROBE_OUT="$WORK/probe-out"
probe_context "$PROBE_CTX" "$PROBE_OUT"
PROBE_RC=$?

it "ビルドコンテキストを書き出せる（.dockerignore ありの実コンテキスト）"
if [ "$PROBE_RC" -eq 0 ]; then pass; else fail "終了コード ${PROBE_RC}" "$(tail -n 5 "$WORK/probe.log" | cut -c1-200)"; fi

it "ビルドコンテキストに test/ が無い"
if [ "$PROBE_RC" -eq 0 ] && [ ! -e "$PROBE_OUT/test" ]; then pass; else fail "test/ が送られている、または書き出せていない"; fi

it "ビルドコンテキストに docs/ が無い"
if [ "$PROBE_RC" -eq 0 ] && [ ! -e "$PROBE_OUT/docs" ]; then pass; else fail "docs/ が送られている、または書き出せていない"; fi

it "ビルドコンテキストに data/（実行時の SQLite）が無い"
if [ "$PROBE_RC" -eq 0 ] && [ ! -e "$PROBE_OUT/data" ]; then pass; else fail "data/ が送られている、または書き出せていない"; fi

it "ビルドコンテキストに env 系の囮が1つも入らない（直下・server/ 配下・さらに深い階層の全て）"
LEAKED=""
for d in "${ENV_DECOYS[@]}"; do
  if [ -e "$PROBE_OUT/$d" ]; then LEAKED="${LEAKED} ${d}"; fi
done
if [ "$PROBE_RC" -eq 0 ] && [ -z "$LEAKED" ]; then pass; else fail "入っている:${LEAKED:- （書き出せていない）}"; fi

it "ビルドコンテキストに秘密鍵・証明書の囮（*.pem *.key id_*。直下・server/ 配下・深い階層）が1つも入らない"
LEAKED=""
for d in "${SECRET_DECOYS[@]}"; do
  if [ -e "$PROBE_OUT/$d" ]; then LEAKED="${LEAKED} ${d}"; fi
done
if [ "$PROBE_RC" -eq 0 ] && [ -z "$LEAKED" ]; then pass; else fail "入っている:${LEAKED:- （書き出せていない）}"; fi

it "ビルドコンテキストに server/server.mjs は残る（除外しすぎていない）"
if [ "$PROBE_RC" -eq 0 ] && [ -f "$PROBE_OUT/server/server.mjs" ]; then pass; else fail "server/server.mjs が無い"; fi

# 自己診断: .dockerignore を外した同じ構造では test/ docs/ data/ が現れる = 上の「無い」は空振りでない
NOIGNORE_CTX="$WORK/ctx-noignore"
mkdir -p "$NOIGNORE_CTX"
cp -R "$PROBE_CTX/." "$NOIGNORE_CTX/"
if [ -f "$NOIGNORE_CTX/.dockerignore" ]; then find "$NOIGNORE_CTX/.dockerignore" -delete; fi
NOIGNORE_OUT="$WORK/noignore-out"
probe_context "$NOIGNORE_CTX" "$NOIGNORE_OUT"
NOIGNORE_RC=$?

it "[自己診断] .dockerignore が無ければ test/ docs/ data/ と全階層の env 系・秘密鍵系の囮はコンテキストに現れる（検査が空振りでない）"
MISSING=""
for d in "${ENV_DECOYS[@]}"; do
  if [ ! -e "$NOIGNORE_OUT/$d" ]; then MISSING="${MISSING} ${d}"; fi
done
for d in "${SECRET_DECOYS[@]}"; do
  if [ ! -e "$NOIGNORE_OUT/$d" ]; then MISSING="${MISSING} ${d}"; fi
done
if [ "$NOIGNORE_RC" -eq 0 ] && [ -e "$NOIGNORE_OUT/test" ] && [ -e "$NOIGNORE_OUT/docs" ] && [ -e "$NOIGNORE_OUT/data/decoy.db" ] && [ -z "$MISSING" ]; then
  pass
else
  fail "書き出し終了コード ${NOIGNORE_RC}（現れない: test/docs/data または${MISSING:- なし}）"
fi

# ══════════════════════════════════════════════
suite "monitor-image-smoke: ビルド（原本 compose。digest がレジストリに実在しないと落ちる）"
# ══════════════════════════════════════════════

PORT="$(pick_free_port)"
it "空きポートを選べる"
case "$PORT" in
  ''|*[!0-9]*) fail "選べなかった: '${PORT}'"; report; exit 1 ;;
  *) pass ;;
esac

STARTED=1
BUILD_LOG="$WORK/build.log"
COMPOSE build >"$BUILD_LOG" 2>&1
BUILD_RC=$?

it "docker compose build が成功する（-f .claude/monitor/compose.monitor.yml --project-directory .）"
if [ "$BUILD_RC" -eq 0 ]; then pass; else fail "終了コード ${BUILD_RC}" "$(tail -n 12 "$BUILD_LOG" | cut -c1-200)"; fi

if [ "$BUILD_RC" -ne 0 ]; then
  smoke_cleanup
  report
  exit 1
fi

# ══════════════════════════════════════════════
suite "monitor-image-smoke: 起動・ヘルス（ポート ${PORT}）"
# ══════════════════════════════════════════════

COMPOSE up -d >"$WORK/up.log" 2>&1
UP_RC=$?
it "docker compose up -d が成功する"
if [ "$UP_RC" -eq 0 ]; then pass; else fail "終了コード ${UP_RC}" "$(tail -n 8 "$WORK/up.log" | cut -c1-200)"; fi

CID="$(COMPOSE ps -q monitor 2>/dev/null)"
it "monitor サービスのコンテナがある"
if [ -n "$CID" ]; then pass; else fail "compose ps -q monitor が空"; fi

if [ "$UP_RC" -ne 0 ] || [ -z "$CID" ]; then
  smoke_cleanup
  report
  exit 1
fi

HEALTH_MSG="$(wait_healthy "$CID" "$HEALTH_WAIT_SECONDS")"
HEALTH_RC=$?
it "HEALTHCHECK が効き、上限 ${HEALTH_WAIT_SECONDS} 秒内に healthy になる"
if [ "$HEALTH_RC" -eq 0 ]; then
  pass
else
  fail "$HEALTH_MSG" "$(COMPOSE logs --no-color --tail 15 monitor 2>&1 | cut -c1-200)"
fi

it "イメージの HEALTHCHECK は node が実行する（curl / wget ではない）"
HC_TEST="$(docker inspect -f '{{json .Config.Healthcheck.Test}}' "$CID" 2>/dev/null)"
if printf '%s' "$HC_TEST" | jq -e '(.[0] == "CMD" and .[1] == "node") or (.[0] == "CMD-SHELL" and (.[1] | startswith("node ")))' >/dev/null 2>&1; then
  pass
else
  fail "Healthcheck.Test: $(printf '%s' "$HC_TEST" | cut -c1-200)"
fi

# ══════════════════════════════════════════════
suite "monitor-image-smoke: ホストからの実挙動（ポート ${PORT}）"
# ══════════════════════════════════════════════

it "公開は 127.0.0.1 に bind されている（docker compose port）"
PORT_MAP="$(COMPOSE port monitor "$PORT" 2>/dev/null)"
assert_eq "$PORT_MAP" "127.0.0.1:${PORT}"

it "ホストから /api/state が 200（Host: 127.0.0.1:${PORT}。内外ポート同一でないと Host 検査で落ちる）"
CODE="$(http_code /api/state)"
assert_eq "$CODE" "200"

it "/api/state の本文が JSON"
if jq -e . "$BODY_FILE" >/dev/null 2>&1; then pass; else fail "JSON として読めない（先頭 120 字: $(head -c 120 "$BODY_FILE" 2>/dev/null)）"; fi

it "Host が偽なら 403（コンテナ越しでも Host 検査が生きている）"
CODE="$(http_code /api/state -H "Host: evil.example")"
assert_eq "$CODE" "403"

it "Sec-Fetch-Site: cross-site なら 403（クロスサイトのブラウザ経由を止める）"
CODE="$(http_code /api/state -H "Sec-Fetch-Site: cross-site")"
assert_eq "$CODE" "403"

# ══════════════════════════════════════════════
suite "monitor-image-smoke: コンテナ内（非 root・堅牢化・DB の所有者）"
# ══════════════════════════════════════════════

CUID="$(COMPOSE exec -T monitor id -u 2>/dev/null | tr -d '\r\n')"
it "コンテナ内 id -u が 0 でない（数値で取れて、かつ非 0）"
case "$CUID" in
  ''|*[!0-9]*) fail "id -u を取得できない: '${CUID}'" ;;
  0) fail "root（uid 0）で動いている" ;;
  *) pass ;;
esac

it "DB（MONITOR_DB）の所有 UID がプロセスの UID と一致する（ボリュームの所有者ずれで chmod が落ちない）"
DB_UID="$(COMPOSE exec -T monitor sh -c 'stat -c %u "$MONITOR_DB"' 2>/dev/null | tr -d '\r\n')"
if [ -n "$CUID" ] && [ "$DB_UID" = "$CUID" ]; then pass; else fail "DB の UID: '${DB_UID}' / プロセスの UID: '${CUID}'"; fi

it "ルートファイルシステムに書き込めない（read_only）"
if COMPOSE exec -T monitor sh -c 'touch /smoke-write-probe' >/dev/null 2>&1; then fail "書き込めてしまった"; else pass; fi

it "実効ケーパビリティが空（cap_drop: ALL）"
CAP_EFF="$(COMPOSE exec -T monitor awk '/^CapEff/ {print $2}' /proc/self/status 2>/dev/null | tr -d '\r\n')"
assert_eq "$CAP_EFF" "0000000000000000"

it "NoNewPrivs が 1（no-new-privileges）"
NNP="$(COMPOSE exec -T monitor awk '/^NoNewPrivs/ {print $2}' /proc/self/status 2>/dev/null | tr -d '\r\n')"
assert_eq "$NNP" "1"

it "curl がイメージに無い"
if COMPOSE exec -T monitor sh -c 'command -v curl' >/dev/null 2>&1; then fail "curl が入っている"; else pass; fi

# ══════════════════════════════════════════════
suite "monitor-image-smoke: 再起動（ボリュームを残して down → up。既存 DB の上でも起動する）"
# ══════════════════════════════════════════════

COMPOSE down >"$WORK/down.log" 2>&1
DOWN_RC=$?
it "docker compose down が成功する（ボリュームは残す）"
if [ "$DOWN_RC" -eq 0 ]; then pass; else fail "終了コード ${DOWN_RC}" "$(tail -n 5 "$WORK/down.log" | cut -c1-200)"; fi

COMPOSE up -d >"$WORK/up2.log" 2>&1
UP2_RC=$?
CID="$(COMPOSE ps -q monitor 2>/dev/null)"
if [ "$UP2_RC" -eq 0 ] && [ -n "$CID" ]; then
  HEALTH_MSG="$(wait_healthy "$CID" "$HEALTH_WAIT_SECONDS")"
  HEALTH_RC=$?
else
  HEALTH_MSG="再 up に失敗（終了コード ${UP2_RC}）"
  HEALTH_RC=1
fi
it "再 up 後に上限 ${HEALTH_WAIT_SECONDS} 秒内に healthy になる"
if [ "$HEALTH_RC" -eq 0 ]; then
  pass
else
  fail "$HEALTH_MSG" "$(COMPOSE logs --no-color --tail 15 monitor 2>&1 | cut -c1-200)"
fi

it "再 up 後もホストから /api/state が 200"
CODE="$(http_code /api/state)"
assert_eq "$CODE" "200"

# ══════════════════════════════════════════════
suite "monitor-image-smoke: 別の Docker ネットワークからの到達（host.docker.internal 経由。限界の実測固定）"
# ══════════════════════════════════════════════
# monitor-net で止まるのはコンテナ間の直接通信だけ。別ネットワークのコンテナは host.docker.internal:<ポート> で
# ホストの公開ポートへ出られ、Host を偽れば /api/state に届く（Docker Desktop で実測）。受信は認証なし（マスター決定）なので、直さず限界として固定する。
# Linux Engine は未実測: 値は決め打たず、観測値を出力し、security.md の記述との矛盾だけを見る

SEC_MD="$REPO_ROOT/.claude/rules/security.md"
PLATFORM="$(docker_platform)"
OS_NAME="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)"
PROBE_IMAGE="$(docker inspect -f '{{.Image}}' "$CID" 2>/dev/null)"
PROBE_NET="${PROJ}-probe"
docker network create "$PROBE_NET" >/dev/null 2>&1
NET_RC=$?
CODE_PLAIN=""
CODE_FORGED=""
if [ "$NET_RC" -eq 0 ] && [ -n "$PROBE_IMAGE" ]; then
  CODE_PLAIN="$(probe_cross_net "$PROBE_IMAGE" "$PROBE_NET" "$PORT" "")"
  CODE_FORGED="$(probe_cross_net "$PROBE_IMAGE" "$PROBE_NET" "$PORT" "127.0.0.1:${PORT}")"
fi
docker rm -f "${PROJ}-probe-ctr" >/dev/null 2>&1
docker network rm "$PROBE_NET" >/dev/null 2>&1
PROBE_NET=""

echo "  obs  プラットフォーム=${PLATFORM}（docker info OperatingSystem='${OS_NAME}'）"
echo "  obs  別ネットワークから host.docker.internal:${PORT}/api/state: (i) Host 偽装なし=${CODE_PLAIN:-取得不能} / (ii) Host: 127.0.0.1:${PORT}=${CODE_FORGED:-取得不能}"

it "プラットフォームを docker info から判定できる（判定不能は合格にしない）"
case "$PLATFORM" in desktop|other) pass ;; *) fail "OperatingSystem='${OS_NAME}'" ;; esac

it "別ネットワークの使い捨てコンテナ（--add-host host.docker.internal:host-gateway）から2つの観測値が取れる"
if [ "$NET_RC" -eq 0 ] && [ -n "$PROBE_IMAGE" ] && [ -n "$CODE_PLAIN" ] && [ -n "$CODE_FORGED" ]; then pass; else fail "ネットワーク作成 rc=${NET_RC} / イメージ='${PROBE_IMAGE}' / (i)='${CODE_PLAIN}' (ii)='${CODE_FORGED}'"; fi

it "(i) Host 偽装なしは 403 か到達不能（200 にならない。Host 検査が効いている）"
case "$CODE_PLAIN" in 403|000) pass ;; *) fail "観測値: '${CODE_PLAIN}'" ;; esac

it "(ii) Docker Desktop: Host: 127.0.0.1:<ポート> を付けると別ネットワークから 200（限界の実測。認証が無いので Host を合わせれば通る）"
case "$PLATFORM" in
  desktop) assert_eq "$CODE_FORGED" "200" ;;
  other) pass ;; # Docker Desktop 以外は値を期待しない（未実測）。観測値は上の obs 行。文書との矛盾は次の検査
  *) fail "プラットフォーム不明で判定できない" ;;
esac

DOC_HOST_BULLET="$(extract_host_bullet "$SEC_MD")"
it "security.md の記述がこのプラットフォームの観測値と矛盾しない（観測で到達したのに『届かない』と書いていれば FAIL）"
if claim_consistent "$PLATFORM" "$CODE_FORGED" "$DOC_HOST_BULLET"; then pass; else fail "$CLAIM_MSG" "該当項: $(printf '%s' "$DOC_HOST_BULLET" | cut -c1-200)"; fi

it "[自己診断] docker_platform: Docker Desktop は desktop、それ以外の OS 名は other、取れない・docker 失敗は unknown"
selfdiag_platform() {
  local bin="$WORK/platbin" r
  mkdir -p "$bin"
  printf '#!/bin/sh\nif [ -n "$STUB_FAIL" ]; then exit 1; fi\nprintf "%%s\\n" "$STUB_OS"\n' > "$bin/docker"
  chmod +x "$bin/docker"
  r="$(PATH="$bin:$PATH" STUB_OS="Docker Desktop" docker_platform)"; [ "$r" = "desktop" ] || { echo "Docker Desktop -> '$r'"; return 1; }
  r="$(PATH="$bin:$PATH" STUB_OS="Ubuntu 24.04.1 LTS" docker_platform)"; [ "$r" = "other" ] || { echo "Ubuntu -> '$r'"; return 1; }
  r="$(PATH="$bin:$PATH" STUB_OS="" docker_platform)"; [ "$r" = "unknown" ] || { echo "空 -> '$r'"; return 1; }
  r="$(PATH="$bin:$PATH" STUB_FAIL=1 docker_platform)"; [ "$r" = "unknown" ] || { echo "失敗 -> '$r'"; return 1; }
}
assert_ok selfdiag_platform

it "[自己診断] claim_consistent: 到達したのに到達しないと書く文書・到達しないのに到達すると書く文書・不明な入力は FAIL、整合する文書は通る"
selfdiag_claim() {
  local ok_desktop="host.docker.internal 経由なら Docker Desktop では別ネットワークから到達できる（実測）。止まるのはコンテナ間の直接通信だけ。Linux は未実測"
  local ok_linux="Docker Desktop では到達できる。Linux は未実測"
  claim_consistent desktop 200 "$ok_desktop" || { echo "整合する Desktop 文書が FAIL: $CLAIM_MSG"; return 1; }
  claim_consistent other 200 "$ok_linux" || { echo "整合する Linux(未実測) 文書が FAIL: $CLAIM_MSG"; return 1; }
  claim_consistent other 000 "$ok_linux" || { echo "到達不能でも未実測の文書は矛盾でない: $CLAIM_MSG"; return 1; }
  claim_consistent desktop 200 "Docker Desktop では届かない。未実測" && { echo "Desktop で到達したのに『届かない』が通った"; return 1; }
  claim_consistent other 200 "Linux では到達できない。Docker Desktop では到達できる" && { echo "Linux で到達したのに『到達できない』が通った"; return 1; }
  claim_consistent other 200 "Linux では到達できない" && { echo "同上（Desktop 語なし）が通った"; return 1; }
  claim_consistent desktop 200 "Docker Desktop の記述だけで『到達』の語が無い" && { echo "到達の語が無いのに Desktop で通った"; return 1; }
  claim_consistent other 000 "Linux でも到達できる" && { echo "到達しなかったのに『Linux でも到達できる』が通った"; return 1; }
  claim_consistent desktop 403 "Docker Desktop では到達できる" && { echo "Desktop で 403 なのに『到達できる』が通った"; return 1; }
  claim_consistent unknown 200 "$ok_desktop" && { echo "プラットフォーム不明が通った"; return 1; }
  claim_consistent other "" "$ok_linux" && { echo "観測値なしが通った"; return 1; }
  claim_consistent other abc "$ok_linux" && { echo "観測値が数値でないのが通った"; return 1; }
  claim_consistent other 200 "" && { echo "該当項なしが通った"; return 1; }
  return 0
}
assert_ok selfdiag_claim

it "[自己診断] extract_host_bullet: コンテナ側の host.docker.internal を含む項だけを、継続行ごと取り出す（別小節・フェンス内・別項は拾わない）"
selfdiag_bullet() {
  local f="$WORK/hb.md" out
  printf '%s\n' '### 別' '- host.docker.internal NO1' '### コンテナ側' '- 別の項' '- ほげ host.docker.internal は' '  継続行 到達できる' '- 次の項' '```' '- host.docker.internal NO2' '```' '## 次' '- host.docker.internal NO3' > "$f"
  out="$(extract_host_bullet "$f")"
  [ "$out" = "- ほげ host.docker.internal は 継続行 到達できる" ] || { echo "想定外: '$out'"; return 1; }
}
assert_ok selfdiag_bullet

# ══════════════════════════════════════════════
suite "monitor-image-smoke: 素の docker run（compose なし・--read-only なし・MONITOR_DB 指定なしでも起動する）"
# ══════════════════════════════════════════════
# ユーザーが security.md を見て打つ形。ENV MONITOR_DB（イメージ既定）が無いと、既定の /app/data（root 所有）に書けず起動失敗する

RUN_IMAGE="monitorsmoke-run${$}:test"
docker build -q -t "$RUN_IMAGE" "$MONITOR_DIR" >"$WORK/runbuild.log" 2>&1
RUNBUILD_RC=$?
it "docker build で素の docker run 用イメージが作れる"
if [ "$RUNBUILD_RC" -eq 0 ]; then pass; else fail "終了コード ${RUNBUILD_RC}" "$(tail -n 8 "$WORK/runbuild.log" | cut -c1-200)"; fi

# docker 不要な前提側の自己診断（ビルド成否に左右されない）
it "[自己診断] extract_doc_runs: フェンス外・別小節・継続行・行頭以外の docker run を正しく扱う"
selfdiag_extract() {
  local f="$WORK/ex.md" out
  printf '%s\n' '### 別' '```' 'docker run NO1' '```' '### コンテナ側' 'docker run NO2' 'text' '```bash' '  docker run -d \' '  -p 1:1 <image>' '# docker run NO3' '```' '```' 'docker run B' '```' '## 次' '```' 'docker run NO4' '```' > "$f"
  out="$(extract_doc_runs "$f")"
  [ "$out" = $'docker run -d -p 1:1 <image>\ndocker run B' ] || { echo "想定外: '$out'"; return 1; }
}
assert_ok selfdiag_extract

it "[自己診断] doc_run_allowed: 許可形だけを通し、; 任意コマンド・-v・特権・置換・改行などを含む行は拒否する"
selfdiag_allow() {
  local good bad
  for good in \
    'docker run -d -e MONITOR_BIND=0.0.0.0 -e LOOP_MONITOR_PORT=<port> -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -e A_B=x-1.2:/y <image>'; do
    doc_run_allowed "$good" || { echo "許可形が拒否された: $good"; return 1; }
  done
  for bad in \
    'docker run -d -p 127.0.0.1:<port>:<port> <image>; touch /tmp/pwned' \
    'docker run -d -p 127.0.0.1:<port>:<port> <image> && id' \
    'docker run -d -v /:/host -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d --privileged -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -e A=$(id) -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -e A=`id` -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -e A=b;c -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -e A=b|c -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -e A=>/tmp/x -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -p 0.0.0.0:<port>:<port> <image>' \
    'docker run -d -p <port>:<port> <image>' \
    'docker run -d -p 127.0.0.1:<port>:<port>' \
    'docker run -d -p 127.0.0.1:<port>:<port> <image> id' \
    'docker run -d -dx -p 127.0.0.1:<port>:<port> <image>' \
    'docker run  -d -p 127.0.0.1:<port>:<port> <image>' \
    'docker run -d -p 127.0.0.1:<port>:<port> alpine' \
    'x docker run -d -p 127.0.0.1:<port>:<port> <image>' \
    ''; do
    if doc_run_allowed "$bad"; then echo "拒否すべき行が通った: $bad"; return 1; fi
  done
  doc_run_allowed $'docker run -d -p 127.0.0.1:<port>:<port> <image>\ntouch /tmp/pwned' && { echo "改行つきが通った"; return 1; }
  doc_run_allowed $'docker run -d -e A=b\t-v\t/:/host -p 127.0.0.1:<port>:<port> <image>' && { echo "タブ区切りの注入が通った"; return 1; }
  return 0
}
assert_ok selfdiag_allow

if [ "$RUNBUILD_RC" -eq 0 ]; then
  # (a) MONITOR_DB・MONITOR_BIND なし
  PA="$(pick_free_port)"
  run_cmd 'docker run -d -p 127.0.0.1:<port>:4319 <image>' "$PA"
  it "(a) DB・BIND 指定なしの docker run が起動し healthy になる（起動失敗しない）"
  if [ "$RUN_RC" -eq 0 ] && [ -n "$RUN_CID" ]; then
    A_MSG="$(wait_healthy "$RUN_CID" "$HEALTH_WAIT_SECONDS")"
    A_RC=$?
    if [ "$A_RC" -eq 0 ]; then pass; else fail "$A_MSG" "$(docker logs --tail 8 "$RUN_CID" 2>&1 | cut -c1-200)"; fi
  else
    A_RC=1
    fail "docker run 終了コード ${RUN_RC}" "$(tail -n 4 "$WORK/run.out" | cut -c1-200)"
  fi

  it "(a) コンテナ内からは /api/state が 200（HEALTHCHECK と同じ経路）"
  if [ "$A_RC" -eq 0 ] && inside_state_ok "$RUN_CID" 4319; then pass; else fail "起動していない、または 200 でない"; fi

  it "(a) ホストからは到達できない（コンテナ内 127.0.0.1 listen。公開範囲を広げていない）"
  if [ "$A_RC" -eq 0 ]; then assert_eq "$(http_code_at "$PA" /api/state)" "000"; else fail "起動していないので判定できない（到達不能の合格にしない）"; fi
  stop_runs

  # (b)(c) security.md に書く例と同形の固定文字列
  FIXED='docker run -d -e MONITOR_BIND=0.0.0.0 -e LOOP_MONITOR_PORT=<port> -p 127.0.0.1:<port>:<port> <image>'
  PB="$(pick_free_port)"
  run_cmd "$FIXED" "$PB"
  it "(b) MONITOR_BIND=0.0.0.0・内外同一ポートの docker run が healthy になる"
  if [ "$RUN_RC" -eq 0 ] && [ -n "$RUN_CID" ]; then
    B_MSG="$(wait_healthy "$RUN_CID" "$HEALTH_WAIT_SECONDS")"
    B_RC=$?
    if [ "$B_RC" -eq 0 ]; then pass; else fail "$B_MSG" "$(docker logs --tail 8 "$RUN_CID" 2>&1 | cut -c1-200)"; fi
  else
    fail "docker run 終了コード ${RUN_RC}" "$(tail -n 4 "$WORK/run.out" | cut -c1-200)"
  fi
  it "(b) ホストから /api/state が 200"
  assert_eq "$(http_code_at "$PB" /api/state)" "200"
  stop_runs

  # (c) 外側ポートだけずらす（Host 検査がポート込み）
  PC_IN="$(pick_free_port)"
  PC_OUT="$(pick_free_port)"
  if [ "$PC_OUT" = "$PC_IN" ]; then PC_OUT="$((PC_IN + 1))"; fi
  run_cmd 'docker run -d -e MONITOR_BIND=0.0.0.0 -e LOOP_MONITOR_PORT=<port> -p 127.0.0.1:'"$PC_OUT"':<port> <image>' "$PC_IN"
  it "(c) 外側ポートだけずらすと、起動はするがホストからは 403（Host 検査）"
  if [ "$RUN_RC" -eq 0 ] && [ -n "$RUN_CID" ] && wait_healthy "$RUN_CID" "$HEALTH_WAIT_SECONDS" >/dev/null; then
    assert_eq "$(http_code_at "$PC_OUT" /api/state)" "403"
  else
    fail "起動・healthy にならない" "$(tail -n 4 "$WORK/run.out" | cut -c1-200)"
  fi
  stop_runs

  # 文書と実行の一致: security.md のコードブロックの docker run を、書いたとおりに実行する
  DOC_RUNS="$WORK/doc-runs.txt"
  extract_doc_runs "$SEC_MD" >"$DOC_RUNS"

  it "security.md「コンテナ側」にコードブロックの docker run が1つ以上あり、全て <image>・<port>・-d・-p 127.0.0.1: を持つ"
  DOC_OK=1
  [ -s "$DOC_RUNS" ] || DOC_OK=0
  while IFS= read -r line; do
    case "$line" in *"<image>"*) ;; *) DOC_OK=0 ;; esac
    case "$line" in *"<port>"*) ;; *) DOC_OK=0 ;; esac
    case "$line" in *" -d "*) ;; *) DOC_OK=0 ;; esac
    case "$line" in *"-p 127.0.0.1:"*) ;; *) DOC_OK=0 ;; esac
  done <"$DOC_RUNS"
  if [ "$DOC_OK" -eq 1 ]; then pass; else fail "契約違反、またはコードブロックが無い: $(head -n 3 "$DOC_RUNS" | cut -c1-120)"; fi

  it "文書の例に MONITOR_BIND=0.0.0.0 付きの docker run がある（ホストから到達する例）"
  if grep -qF 'MONITOR_BIND=0.0.0.0' "$DOC_RUNS" 2>/dev/null; then pass; else fail "無い"; fi

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    PD="$(pick_free_port)"
    it "文書の例を書いたとおり実行すると healthy になる: $(printf '%s' "$line" | cut -c1-90)"
    if ! doc_run_allowed "$line"; then
      fail "許可形（docker run の -d / -e KEY=値 / -p 127.0.0.1:<port>:<port> と末尾の <image> だけ）から外れたので実行しない"
      continue
    fi
    run_cmd "$line" "$PD"
    if [ "$RUN_RC" -eq 0 ] && [ -n "$RUN_CID" ]; then
      D_MSG="$(wait_healthy "$RUN_CID" "$HEALTH_WAIT_SECONDS")"
      D_RC=$?
      if [ "$D_RC" -eq 0 ]; then pass; else fail "$D_MSG" "$(docker logs --tail 8 "$RUN_CID" 2>&1 | cut -c1-200)"; fi
    else
      D_RC=1
      fail "docker run 終了コード ${RUN_RC}" "$(tail -n 4 "$WORK/run.out" | cut -c1-200)"
    fi
    case "$line" in
      *MONITOR_BIND=0.0.0.0*)
        it "文書の例（MONITOR_BIND=0.0.0.0）: ホストから /api/state が 200"
        if [ "$D_RC" -eq 0 ]; then assert_eq "$(http_code_at "$PD" /api/state)" "200"; else fail "起動していない"; fi ;;
    esac
    stop_runs
  done <"$DOC_RUNS"
fi

# ══════════════════════════════════════════════
suite "monitor-image-smoke: 後片付け（コンテナ・ボリューム・ネットワーク・イメージを残さない）"
# ══════════════════════════════════════════════

# down の前にイメージ名を確定する。compose に image: があればそれ、無ければ <プロジェクト>-monitor
IMAGE="$(COMPOSE config --format json 2>/dev/null | jq -r --arg d "${PROJ}-monitor" '.services.monitor.image // $d' 2>/dev/null)"
[ -n "$IMAGE" ] || IMAGE="${PROJ}-monitor"

COMPOSE down -v --rmi all --remove-orphans >"$WORK/cleanup.log" 2>&1
CLEAN_RC=$?
STARTED=0

it "docker compose down -v --rmi all が成功する"
if [ "$CLEAN_RC" -eq 0 ]; then pass; else fail "終了コード ${CLEAN_RC}" "$(tail -n 5 "$WORK/cleanup.log" | cut -c1-200)"; fi

LABEL="label=com.docker.compose.project=${PROJ}"

it "コンテナが残っていない"
assert_eq "$(docker ps -aq --filter "$LABEL" 2>/dev/null)" ""

it "ボリュームが残っていない"
assert_eq "$(docker volume ls -q --filter "$LABEL" 2>/dev/null)" ""

it "ネットワークが残っていない"
assert_eq "$(docker network ls -q --filter "$LABEL" 2>/dev/null)" ""

it "別ネットワーク検査用のネットワークが残っていない"
assert_eq "$(docker network ls -q --filter "name=${PROJ}-probe" 2>/dev/null)" ""

it "ビルドしたイメージが残っていない"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then fail "残っている: ${IMAGE}"; else pass; fi

it "停止後はホストのポートが閉じている"
CODE="$(http_code /api/state)"
assert_eq "$CODE" "000"

report
