#!/usr/bin/env bash
# ドキュメントと実体の整合テスト
#
# このリポジトリの成果物はドキュメントそのものだ。
# 「ルールに書いてあるファイルが存在しない」「コマンド表に載っているのに定義が無い」は
# 機能不全そのものなので、機械で検出する。

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck source=tests/scripts/lib.sh
. "$REPO_ROOT/tests/scripts/lib.sh"

cd "$REPO_ROOT" || exit 1

# ══════════════════════════════════════════════
suite "docs: @参照の解決"
# ══════════════════════════════════════════════

# CLAUDE.md / AGENTS.md / rules が `@.claude/...` で参照するファイルは実在しなければならない
missing=""
while IFS= read -r ref; do
  [ -f "$ref" ] || missing="$missing $ref"
done < <(grep -rhoE '@\.claude/[A-Za-z0-9._/-]+\.md' CLAUDE.md AGENTS.md .claude/rules/*.md .claude/memory/*.md 2>/dev/null \
         | sed 's/^@//' | sort -u)

it "@参照されたファイルが全て実在する"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "docs: スラッシュコマンドの定義"
# ══════════════════════════════════════════════

missing=""
while IFS= read -r cmd; do
  [ -f ".claude/commands/${cmd}.md" ] || missing="$missing /$cmd"
done < <(grep -oE '^\| `/[a-z-]+`' CLAUDE.md | sed 's/^| `\///; s/`$//' | sort -u)

it "CLAUDE.md のコマンド表に載る全コマンドに定義がある"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "Claude と Codex のコマンド定義が同数ある"
assert_eq "$(find .codex/commands -name '*.md' | wc -l | tr -d ' ')" \
          "$(find .claude/commands -name '*.md' | wc -l | tr -d ' ')"

missing=""
for f in .claude/commands/*.md; do
  base="$(basename "$f")"
  [ -f ".codex/commands/$base" ] || missing="$missing $base"
done

it "全 Claude コマンドに対応する Codex 版がある"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "docs: サブエージェントの定義"
# ══════════════════════════════════════════════

missing=""
while IFS= read -r agent; do
  [ -f ".claude/agents/${agent}.md" ] || missing="$missing $agent"
done < <(grep -rhoE 'sub-agent-[a-z-]+' CLAUDE.md .claude/rules/*.md .claude/commands/*.md 2>/dev/null | sort -u)

it "参照される全サブエージェントに定義がある"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "Claude と Codex のエージェント定義が同数ある"
assert_eq "$(find .codex/agents -name '*.toml' | wc -l | tr -d ' ')" \
          "$(find .claude/agents -name '*.md' | wc -l | tr -d ' ')"

# ══════════════════════════════════════════════
suite "docs: スクリプト参照"
# ══════════════════════════════════════════════

missing=""
while IFS= read -r script; do
  [ -f "$script" ] || missing="$missing $script"
done < <(grep -rhoE '\.claude/scripts/[a-z-]+\.sh' \
           CLAUDE.md AGENTS.md README.md .claude .codex .github 2>/dev/null | sort -u)

it "ドキュメントが参照する全スクリプトが実在する"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "全スクリプトに実行権がある"
noexec=""
for f in .claude/scripts/*.sh; do
  [ -x "$f" ] || noexec="$noexec $f"
done
assert_eq "$(echo "$noexec" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "docs: フック設定の実体"
# ══════════════════════════════════════════════

missing=""
while IFS= read -r hook; do
  [ -f "$hook" ] || missing="$missing $hook"
done < <(grep -oE '\.claude/(hooks|scripts)/[a-z-]+\.sh' .claude/settings.json | sort -u)

it "settings.json が参照する全フック・スクリプトが実在する"
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "settings.json が妥当な JSON である"
assert_ok jq empty .claude/settings.json

# Claude Code がパス付きで照合するのは Edit(path) だけ。Write(path) の deny は何も止めない。
# 起動時に警告は出るが、読み飛ばされると .env への書き込みが素通りのまま配布される。
it "deny に照合されない Write(path) ルールが無い"
assert_eq "$(jq -r '.permissions.deny[] | select(startswith("Write("))' .claude/settings.json)" ""

it "シークレット系ファイルの書き込みが Edit(path) で deny されている"
missing=""
for pattern in .env .env.local .env.development .env.production \
         '**/.env' '**/.env.local' '**/.env.development' '**/.env.production' '**/*secret*'; do
  jq -e --arg r "Edit($pattern)" '.permissions.deny | index($r)' .claude/settings.json >/dev/null \
    || missing="$missing $pattern"
done
assert_eq "$(echo "$missing" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "docs: 外部記憶の記載整合"
# ══════════════════════════════════════════════

it "ジャーナルの一時ポインタが .gitignore されている"
assert_ok git check-ignore -q .claude/memory/journal/.vault

it "ジャーナル本体は .gitignore されていない"
assert_fails git check-ignore -q .claude/memory/journal/README.md

it "loop-journal.sh のサブコマンドがドキュメントと一致する"
undocumented=""
for sub in init context start inner outer flush status where; do
  grep -qF "loop-journal.sh $sub" .claude/rules/loop-engineering.md \
    .claude/commands/*.md .claude/memory/journal/README.md README.md 2>/dev/null \
    || undocumented="$undocumented $sub"
done
assert_eq "$(echo "$undocumented" | tr -s ' ')" ""

# ══════════════════════════════════════════════
suite "docs: CI ワークフローの発火条件"
# ══════════════════════════════════════════════
# 受け入れ条件「pull_request と push(main) で発火する」を機械で固定する。
# 誤って on: を消しても、CI 自身は緑のまま何も検査しなくなるため気づけない。

it "template-ci.yml が pull_request で発火する"
assert_file_contains ".github/workflows/template-ci.yml" "pull_request:"

it "template-ci.yml が main への push で発火する"
assert_file_contains ".github/workflows/template-ci.yml" "branches: [main]"

it "template-ci.yml に必須の5ジョブが揃っている（monitor-smoke は #20 で追加）"
missing=""
for job in "shell:" "tests:" "docs:" "hygiene:" "monitor-smoke:"; do
  grep -qF "  $job" .github/workflows/template-ci.yml || missing="$missing $job"
done
assert_eq "$(echo "$missing" | tr -s ' ')" ""

it "テストランナーが CI から呼ばれている"
assert_file_contains ".github/workflows/template-ci.yml" "bash tests/run.sh"

it "loop-automation.yml は PR では発火しない"
# ループ起動は Issue ラベル/手動のみ。PR で回すとコストが読めない
assert_file_not_contains ".github/workflows/loop-automation.yml" "pull_request:"

# ══════════════════════════════════════════════
suite "docs: 監視イメージのスモークジョブ（monitor-smoke）"
# ══════════════════════════════════════════════
# Issue #20: docker build → 起動 → ヘルス待ち → /api/state 200 → 停止。中身は tests/scripts/monitor-image-smoke.test.sh に置き、
# CI は手元と同じスクリプトを呼ぶだけにする（lessons #18: CI にだけある検査を作らない）。
# 構造は YAML パーサで見る（grep の行単位判定を使わない）。PyYAML が無ければスキップではなく FAIL

smoke_job_field() { # <jq 風ではなく python の式。job 辞書を j として評価する>
  python3 - "$1" <<'PY' 2>/dev/null
import sys
try:
    import yaml
except ImportError:
    sys.exit(3)
doc = yaml.safe_load(open(".github/workflows/template-ci.yml", encoding="utf-8"))
j = (doc.get("jobs") or {}).get("monitor-smoke")
if j is None:
    sys.exit(4)
steps = j.get("steps") or []
runs = "\n".join(str(s.get("run", "")) for s in steps if isinstance(s, dict))
uses = [str(s.get("uses", "")) for s in steps if isinstance(s, dict)]
cont = [s for s in steps if isinstance(s, dict) and s.get("continue-on-error")]
env = {"j": j, "runs": runs, "uses": uses, "cont": cont}
print(eval(sys.argv[1], {"__builtins__": {"any": any, "str": str, "len": len, "isinstance": isinstance, "int": int, "bool": bool}}, env))
PY
}

it "PyYAML が使える（無ければ以降の検査が成立しないので FAIL）"
if python3 -c 'import yaml' 2>/dev/null; then pass; else fail "PyYAML が無い。スキップせず FAIL"; fi

it "monitor-smoke ジョブが存在する"
assert_eq "$(smoke_job_field '"yes"')" "yes"

it "monitor-smoke は ubuntu で動き、timeout-minutes が設定されている"
assert_eq "$(smoke_job_field 'str(j.get("runs-on", "")).startswith("ubuntu-") and isinstance(j.get("timeout-minutes"), int)' | tr 'A-Z' 'a-z')" "true"

it "monitor-smoke が actions/checkout を使う"
assert_eq "$(smoke_job_field 'any(u.startswith("actions/checkout@") for u in uses)')" "True"

it "monitor-smoke が手元と同じスクリプトを呼ぶ（bash tests/run.sh monitor-image-smoke）"
assert_eq "$(smoke_job_field '"bash tests/run.sh monitor-image-smoke" in runs')" "True"

it "monitor-smoke に continue-on-error がない（失敗を握りつぶさない）"
assert_eq "$(smoke_job_field 'len(cont) == 0 and not j.get("continue-on-error")')" "True"

it "monitor-smoke の実行に || true などの握りつぶしがない"
assert_eq "$(smoke_job_field '"|| true" in runs or "||true" in runs')" "False"

it "スモークスクリプト自身が存在する"
assert_file "tests/scripts/monitor-image-smoke.test.sh"

# ══════════════════════════════════════════════
suite "docs: tests ジョブのスモーク除外（二重実行の解消。穴にしない）"
# ══════════════════════════════════════════════
# Issue #20 / PR #30: tests ジョブの全件実行が monitor-image-smoke を含み、monitor-smoke と二重に走っていた。
# tests ジョブは RUN_EXCLUDE=monitor-image-smoke で外す。ただし除外は「誰も走らせない」穴になりうる。
# 除外した全スイートが別ジョブで `bash tests/run.sh <名前>` として走っていることまで構造で固定する。

# ci_exclusion_problems <yaml パス>  → 問題を1行ずつ出力。出力が空なら健全。
#   no-tests-job / no-full-run / not-excluded:monitor-image-smoke / hole:<名前>
#   no-run-exclude / excluded-outside-tests:<ジョブ名> / python-failed:<rc>
#   python が落ちたら python-failed を必ず出す（判定不能を合格にしない）。
ci_exclusion_problems() {
  local out rc tmp
  tmp="$(mktemp)" || { echo "python-failed:mktemp"; return; }
  python3 - "$1" > "$tmp" 2>&1 <<'PY'
import re, sys
try:
    import yaml
except ImportError:
    print("no-pyyaml"); sys.exit(0)
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs = doc.get("jobs") or {}
RUN = re.compile(r'^(?P<pre>(?:\w+=(?:\'[^\']*\'|"[^"]*"|\S*)\s+)*)bash\s+tests/run\.sh(?P<args>(?:\s+\S+)*)\s*$')

def run_lines(job):
    out = []
    for s in (job.get("steps") or []):
        if isinstance(s, dict):
            for ln in str(s.get("run", "")).splitlines():
                out.append(ln.strip())
    return out

def parse(ln):
    m = RUN.match(ln)
    if not m:
        return None
    excl = []
    for kv in re.finditer(r'(\w+)=(\'[^\']*\'|"[^"]*"|\S*)', m.group("pre")):
        if kv.group(1) == "RUN_EXCLUDE":
            excl = kv.group(2).strip("'\"").split()
    return excl, m.group("args").split()

tests = jobs.get("tests")
if tests is None:
    print("no-tests-job"); sys.exit(0)
if not any("RUN_EXCLUDE" in l for l in run_lines(tests)):
    print("no-run-exclude")
for jn, job in jobs.items():
    if jn != "tests" and isinstance(job, dict) and any("RUN_EXCLUDE" in l for l in run_lines(job)):
        print("excluded-outside-tests:" + jn)
full = [parse(l) for l in run_lines(tests)]
full = [p for p in full if p is not None and p[1] == []]
if not full:
    print("no-full-run"); sys.exit(0)
excluded = set()
for excl, _ in full:
    excluded.update(excl)
if "monitor-image-smoke" not in excluded:
    print("not-excluded:monitor-image-smoke")
for name in sorted(excluded):
    covered = False
    for jn, job in jobs.items():
        if jn == "tests" or not isinstance(job, dict):
            continue
        for l in run_lines(job):
            p = parse(l)
            if p and p[1] == [name] and name not in p[0]:
                covered = True
    if not covered:
        print("hole:" + name)
PY
  rc=$?
  out="$(cat "$tmp")"; rm -f "$tmp"
  if [ "$rc" -ne 0 ]; then echo "python-failed:$rc"; fi
  if [ -n "$out" ]; then echo "$out"; fi
}

# ci_problems_of <yaml> <ERE>  → 該当する問題行。python-failed は常に含める（素通り防止）。
ci_problems_of() {
  ci_exclusion_problems "$1" | grep -E -e '^python-failed' -e "$2" || true
}

CI_YML=".github/workflows/template-ci.yml"
DIAG_MISSING_YML="/nonexistent/ci-$$.yml"

it "PyYAML が使える（除外の検査が成立する前提）"
if python3 -c 'import yaml' 2>/dev/null; then pass; else fail "PyYAML が無い。スキップせず FAIL"; fi

it "tests ジョブの全件実行が monitor-image-smoke を RUN_EXCLUDE で除外している"
assert_eq "$(ci_problems_of "$CI_YML" '^(not-excluded:|no-full-run|no-tests-job)')" ""

it "除外した全スイートが別ジョブで bash tests/run.sh <スイート> として走っている（穴が無い）"
assert_eq "$(ci_exclusion_problems "$CI_YML")" ""

it "tests ジョブに RUN_EXCLUDE の記述が実在する（検査が素通りしていない確認）"
assert_eq "$(ci_problems_of "$CI_YML" '^no-run-exclude')" ""

it "monitor-smoke ジョブが従来どおり存在し、monitor-image-smoke だけを走らせる"
assert_eq "$(smoke_job_field '"bash tests/run.sh monitor-image-smoke" in runs')" "True"

it "tests ジョブ以外の run 段で RUN_EXCLUDE を使っていない（専用ジョブで除外が効かなくなる事故を防ぐ）"
assert_eq "$(ci_problems_of "$CI_YML" '^excluded-outside-tests:')" ""

it "検査器は python が落ちたら python-failed を出す（存在しない YAML パス）"
assert_contains "$(ci_exclusion_problems "$DIAG_MISSING_YML")" "python-failed:"

it "python 失敗時は各検査が空にならず FAIL になる（素通りしない）"
assert_contains "$(ci_problems_of "$DIAG_MISSING_YML" '^excluded-outside-tests:')" "python-failed:"

# ---------- 自己診断: 検査器が壊れた CI を FAIL にできること（合成 YAML） ----------
DIAG="$(mktemp -d)" || exit 1
SANDBOXES+=("$DIAG")
trap cleanup_sandboxes EXIT

diag_yaml() { # <名前> <tests ジョブの run> <別ジョブの run>
  cat > "$DIAG/$1.yml" <<YML
jobs:
  tests:
    steps:
      - run: $2
  other:
    steps:
      - run: $3
YML
}

diag_yaml good       "RUN_EXCLUDE=monitor-image-smoke bash tests/run.sh" "bash tests/run.sh monitor-image-smoke"
diag_yaml no-job     "RUN_EXCLUDE=monitor-image-smoke bash tests/run.sh" "echo nothing"
diag_yaml partial    "RUN_EXCLUDE=monitor-image-smoke bash tests/run.sh" "bash tests/run.sh monitor-image"
diag_yaml self-excl  "RUN_EXCLUDE=monitor-image-smoke bash tests/run.sh" "RUN_EXCLUDE=monitor-image-smoke bash tests/run.sh monitor-image-smoke"
diag_yaml no-exclude "bash tests/run.sh" "bash tests/run.sh monitor-image-smoke"
diag_yaml other-excl "RUN_EXCLUDE=docs-consistency bash tests/run.sh" "bash tests/run.sh docs-consistency"
diag_yaml outside   "RUN_EXCLUDE=monitor-image-smoke bash tests/run.sh" "RUN_EXCLUDE=docs-consistency bash tests/run.sh monitor-image-smoke"
diag_yaml hole2      "RUN_EXCLUDE='monitor-image-smoke bash-lint' bash tests/run.sh" "bash tests/run.sh monitor-image-smoke"

it "自己診断: 正しい CI は問題なし"
assert_eq "$(ci_exclusion_problems "$DIAG/good.yml")" ""

it "自己診断: 専用ジョブが無い除外は hole として検出する"
assert_eq "$(ci_exclusion_problems "$DIAG/no-job.yml")" "hole:monitor-image-smoke"

it "自己診断: 専用ジョブが部分一致の名前（monitor-image）では hole として検出する"
assert_eq "$(ci_exclusion_problems "$DIAG/partial.yml")" "hole:monitor-image-smoke"

it "自己診断: 専用ジョブ自身が同じスイートを除外していれば hole として検出する"
assert_contains "$(ci_exclusion_problems "$DIAG/self-excl.yml")" "hole:monitor-image-smoke"

it "自己診断: tests ジョブが何も除外していなければ検出する"
assert_contains "$(ci_exclusion_problems "$DIAG/no-exclude.yml")" "not-excluded:monitor-image-smoke"

it "自己診断: 別スイートを除外していても monitor-image-smoke の未除外は検出する"
assert_contains "$(ci_exclusion_problems "$DIAG/other-excl.yml")" "not-excluded:monitor-image-smoke"

it "自己診断: tests 以外のジョブで RUN_EXCLUDE を使えば検出する"
assert_contains "$(ci_exclusion_problems "$DIAG/outside.yml")" "excluded-outside-tests:other"

it "自己診断: 複数除外のうち片方だけ専用ジョブがあれば残りを hole として検出する"
assert_eq "$(ci_exclusion_problems "$DIAG/hole2.yml")" "hole:bash-lint"

# ══════════════════════════════════════════════
suite "docs: CI の外部依存の取得"
# ══════════════════════════════════════════════
# タグ固定だけでは足りない。GitHub Releases のアセットは同じタグのまま差し替えられる。

it "actionlint をチェックサム検証してから展開する"
assert_file_contains ".github/workflows/template-ci.yml" "sha256sum -c -"

it "外部バイナリの取得に sudo を使わない"
assert_file_not_contains ".github/workflows/template-ci.yml" "sudo tar"

it "pip の依存はバージョンを固定する"
assert_file_contains ".github/workflows/template-ci.yml" "pyyaml=="

# ══════════════════════════════════════════════
suite "docs: 監視の導入手順と限界（Issue #25）"
# ══════════════════════════════════════════════
# README の「監視」を含む ## 見出しの配下に、導入者が迷わないための事項が全て書かれていること。
# 節の切り出しは awk（lessons #10: grep の行単位で節境界を近似しない。コードフェンス内の ## は見出しにしない）。
# 見出し名は固定しない。抽出結果が空なら FAIL（#22: 節が無い・空のとき素通りさせない）。
# 既定ポートと Compose 最低版は実体から読む（値を直書きしない）。

# doc_section <ファイル> <## 見出しに含まれる語>  → 該当する ## 節（### 以下を含む）の本文
doc_section() {
  awk -v key="$2" '
    /^```/ { fence = !fence }
    !fence && /^## / { p = (index($0, key) > 0); next }
    p { print }
  ' "$1"
}

# 実体から引用する値
EMIT_PORT="$(sed -n 's/^port=\([0-9][0-9]*\)$/\1/p' .claude/hooks/monitor-emit.sh | head -n 1)"
COMPOSE_PORT="$(sed -n 's/.*LOOP_MONITOR_PORT:-\([0-9][0-9]*\)}.*/\1/p' .claude/monitor/compose.monitor.yml | sort -u)"
COMPOSE_MIN="$(sed -n 's/^#.*include は Compose \(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' .claude/scripts/bootstrap-monitor.sh | head -n 1)"

README_MON="$(doc_section README.md 監視)"

# 必須語。1行1項目「番号|語」。欠けた項目を MON_MISSING に入れ、1つでも欠ければ 1。
mon_terms_ok() { # <本文> <既定ポート> <Compose 最低版>
  local line t n
  MON_MISSING=""
  while IFS='|' read -r n t; do
    [ -n "$n" ] || continue
    case "$1" in *"$t"*) ;; *) MON_MISSING="${MON_MISSING} [${n}]${t}" ;; esac
  done <<TERMS
1|bootstrap-monitor
1|SessionStart
1|docker compose up
2|LOOP_MONITOR_PORT
2|$2
3|LOOP_MONITOR=0
3|docker compose down
4|$3
5|include
5|project_directory
6|Codex
6|対象外
7a|初回
7a|--quiet
7b|COMPOSE_FILE
7b|-f
7c|perl
8|monitor-net
8|monitor-data
8|衝突
TERMS
  # 項目9: 個人パス（/Users/<名前> /home/<名前>）を含まない（#17）
  line="$(printf '%s\n' "$1" | grep -E '/(Users|home)/[A-Za-z0-9._-]+' || true)"
  [ -z "$line" ] || MON_MISSING="${MON_MISSING} [9]個人パス混入"
  [ -z "$MON_MISSING" ]
}

it "[前提] 既定ポートが実体（monitor-emit.sh と compose.monitor.yml）から一意に読める"
assert_eq "${EMIT_PORT}/${COMPOSE_PORT}" "${EMIT_PORT}/${EMIT_PORT}"

it "[前提] 既定ポートが数値で取れている（空なら突き合わせが成立しない）"
case "$EMIT_PORT" in ''|*[!0-9]*) fail "既定ポートを実体から読めない" ;; *) pass ;; esac

it "[前提] Compose 最低版が bootstrap-monitor.sh の出典コメントから読め、v2.20.0 である"
assert_eq "$COMPOSE_MIN" "v2.20.0"

it "README に「監視」を含む ## 見出しの節があり、中身が空でない"
if [ -n "$README_MON" ]; then pass; else fail "README に監視の節が無い、または空"; fi

it "README の監視の節に導入手順（bootstrap-monitor / SessionStart / docker compose up）がある"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[1]"*) fail "欠け:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空" ;; esac

it "README の監視の節に LOOP_MONITOR_PORT と実体の既定ポートがある"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[2]"*) fail "欠け:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空" ;; esac

it "README の監視の節に停止方法（LOOP_MONITOR=0 と docker compose down）がある"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[3]"*) fail "欠け:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空" ;; esac

it "README の監視の節に Compose 最低版が実体（bootstrap-monitor.sh）と同じ値で書かれている"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[4]"*) fail "欠け:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空" ;; esac

it "README の監視の節に include の追記スニペット（include と project_directory）がある"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[5]"*) fail "欠け:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空" ;; esac

it "README の監視の節に Codex 版は対象外である旨がある"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[6]"*) fail "欠け:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空" ;; esac

it "README の監視の節に #24 G3 の3点（初回のみの案内・COMPOSE_FILE と -f・perl 必須）がある"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[7"*) fail "欠け:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空" ;; esac

it "README の監視の節に monitor-net / monitor-data の名前の衝突への注意がある"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[8]"*) fail "欠け:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空" ;; esac

it "README の監視の節に個人パス（/Users/<名前> /home/<名前>）が無い"
mon_terms_ok "$README_MON" "$EMIT_PORT" "$COMPOSE_MIN" || true
case "$MON_MISSING" in *"[9]"*) fail "混入:${MON_MISSING}" ;; *) [ -n "$README_MON" ] && pass || fail "節が空（空の節を合格にしない）" ;; esac

it "[自己診断] mon_terms_ok: 全語ありは通り、語を1つ消した合成本文・空本文・個人パス混入は FAIL する"
selfdiag_mon() {
  local full drop mut
  full="bootstrap-monitor SessionStart docker compose up LOOP_MONITOR_PORT ${EMIT_PORT} LOOP_MONITOR=0 docker compose down ${COMPOSE_MIN} include project_directory Codex 対象外 初回 --quiet COMPOSE_FILE -f perl monitor-net monitor-data 衝突"
  mon_terms_ok "$full" "$EMIT_PORT" "$COMPOSE_MIN" || { echo "全語ありが FAIL した:${MON_MISSING}"; return 1; }
  for drop in bootstrap-monitor SessionStart "docker compose up" LOOP_MONITOR_PORT "$EMIT_PORT" "LOOP_MONITOR=0" \
              "docker compose down" "$COMPOSE_MIN" include project_directory Codex 対象外 初回 --quiet \
              COMPOSE_FILE -f perl monitor-net monitor-data 衝突; do
    mut="${full//"$drop"/}"
    if mon_terms_ok "$mut" "$EMIT_PORT" "$COMPOSE_MIN"; then echo "「${drop}」を消しても通った"; return 1; fi
  done
  if mon_terms_ok "" "$EMIT_PORT" "$COMPOSE_MIN"; then echo "空本文が通った"; return 1; fi
  if mon_terms_ok "${full} /Users/someone/project" "$EMIT_PORT" "$COMPOSE_MIN"; then echo "/Users/ 混入が通った"; return 1; fi
  if mon_terms_ok "${full} /home/someone/project" "$EMIT_PORT" "$COMPOSE_MIN"; then echo "/home/ 混入が通った"; return 1; fi
  return 0
}
assert_ok selfdiag_mon

it "[自己診断] doc_section: 監視の節だけを取り、コードフェンス内の ## と別節は拾わない"
selfdiag_docsec() {
  local f="${DIAG_MON}/sec.md" out
  printf '%s\n' '## 別' 'OUT1' '## 🔭 監視' 'IN1' '```' '## 偽見出し' '```' '### 小節' 'IN2' '## 次' 'OUT2' > "$f"
  out="$(doc_section "$f" 監視 | tr '\n' ' ')"
  [ "$out" = 'IN1 ``` ## 偽見出し ``` ### 小節 IN2 ' ] || { echo "想定外の抽出: '${out}'"; return 1; }
  printf '%s\n' '## 別' 'OUT' > "$f"
  [ -z "$(doc_section "$f" 監視)" ] || { echo "見出しが無いのに抽出された"; return 1; }
}
DIAG_MON="$(mktemp -d)" || exit 1
SANDBOXES+=("$DIAG_MON")
assert_ok selfdiag_docsec

# ---------- CLAUDE.md / AGENTS.md ----------
CLAUDE_DIR_SEC="$(doc_section CLAUDE.md ディレクトリ構造)"
CLAUDE_SETUP_SEC="$(doc_section CLAUDE.md 初回セットアップ)"
AGENTS_SETUP_SEC="$(doc_section AGENTS.md 初回セットアップ)"

it "CLAUDE.md のディレクトリ構造の節があり、.claude/monitor/ が載っている（節が空なら FAIL）"
case "$CLAUDE_DIR_SEC" in '') fail "節が無い、または空" ;; *".claude/monitor/"*) pass ;; *) fail ".claude/monitor/ が無い" ;; esac

it "CLAUDE.md の初回セットアップ節があり、bootstrap-monitor.sh が載っている（節が空なら FAIL）"
case "$CLAUDE_SETUP_SEC" in '') fail "節が無い、または空" ;; *"bootstrap-monitor.sh"*) pass ;; *) fail "bootstrap-monitor.sh が無い" ;; esac

# AGENTS.md はディレクトリ構造の節を持たず、初回セットアップは「Codex に SessionStart が無いので手動」の節。
# 監視は Codex 版対象外（README と同じ）なので、導入手順の代わりに「対象外」であることと
# 該当スクリプト名（自動生成されないこと）を初回セットアップ節に書かせる。
it "AGENTS.md の初回セットアップ節に、監視（bootstrap-monitor.sh）が Codex 版では対象外である旨がある（節が空なら FAIL）"
if [ -z "$AGENTS_SETUP_SEC" ]; then fail "節が無い、または空"
else
  agents_missing=""
  for t in 監視 bootstrap-monitor.sh 対象外; do
    case "$AGENTS_SETUP_SEC" in *"$t"*) ;; *) agents_missing="${agents_missing} ${t}" ;; esac
  done
  assert_eq "$(echo "$agents_missing" | tr -s ' ')" ""
fi

report
