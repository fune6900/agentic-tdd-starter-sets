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
suite "docs: CI の外部依存の取得"
# ══════════════════════════════════════════════
# タグ固定だけでは足りない。GitHub Releases のアセットは同じタグのまま差し替えられる。

it "actionlint をチェックサム検証してから展開する"
assert_file_contains ".github/workflows/template-ci.yml" "sha256sum -c -"

it "外部バイナリの取得に sudo を使わない"
assert_file_not_contains ".github/workflows/template-ci.yml" "sudo tar"

it "pip の依存はバージョンを固定する"
assert_file_contains ".github/workflows/template-ci.yml" "pyyaml=="

report
