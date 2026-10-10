# Epic: ai-monitor — AI オーケストレーション監視ツールの組み込み

## ゴール（一行）
導入先で `docker compose up` すると監視コンテナが立ち、専用ビューでメイン／サブエージェントの状態・ループ状態・トークン／推定コスト・イベント時系列が見える。

## 前提（確定事項・出典）
- マスター確定: 自作の軽量版（hooks → HTTP 受信サーバ → SQLite → 専用 Web UI）。OTel / Grafana は使わない
- マスター確定: compose は**別ファイル生成**。既存 compose ファイルは絶対に触らない
- マスター確定: 表示はエージェント状態 / ループ状態 / トークン・コスト / イベント時系列の全部
- 設計叩き台: `~/.claude/plans/indexed-yawning-glacier.md`（承認済み）
- 調査で確認した事実（2026-09-28 時点）
  - テンプレに `package.json` は無い。テストは純 bash（`tests/run.sh` → `tests/scripts/*.test.sh`、`lib.sh`）
  - `lib.sh` の `new_sandbox`（L90 付近）はコピー対象スクリプトを**固定列挙**している。新スクリプトは追記しないとサンドボックスに入らない
  - `bootstrap-project.sh` は `ci.yml` 既存時に早期 `exit` する単一成果物設計。監視の生成は同居させない
  - `loop-state.sh` は `$STATE_FILE.tmp.$$` に書いて `mv` で置き換える（L68-77）。**単一ファイルの bind mount は旧 inode を掴み続けて更新が見えなくなる**ため、マウントはディレクトリ単位でなければならない
  - `loop-state.sh` の状態ファイルは `${CLAUDE_PROJECT_DIR}/.claude/memory/loop-state.json`。worktree 実行時の置き場所は未実測（未確定事項へ）
  - 手元の Node は **v22.22.0**。`node:sqlite` は動くが `ExperimentalWarning` が出る。Docker Compose は v2.38.2。**Docker デーモンは現在停止中**
  - `docs-consistency.test.sh` は「settings.json が参照する全フック・スクリプトが実在する」「ドキュメントが参照する `.claude/scripts/*.sh` が実在する」を既に検査している。`shell-lint` / CI の `bash -n` / `shellcheck` は `find .claude .codex tests -name '*.sh'` で新規 `.sh` を自動で拾う
  - 既存 settings.json のフックは PreToolUse(Bash/Task) / PostToolUse(Write|Edit) / Stop / SessionStart のみ。Subagent 系は未使用

## 叩き台からの切り直し（理由）

| 叩き台 | 正式分解 | 理由 |
| --- | --- | --- |
| #A 収集基盤 | **1 / 2 / 3 / 4** | #A は「実測」「フック（送信側）」「HTTP 受信境界＋SQL」「コンテナイメージ（依存追加）」という**信頼境界が4つ**混ざっていた。G5 を1回で通す面積ではない（lessons: 5巡連続で「直した箇所の隣」から高指摘）。また実測結果次第でスキーマが変わるため、実測を独立 Issue にして**結果を人間が見てから**後続を走らせる |
| #B 専用ビュー | **5 / 6** | ループ状態は「HTTP で届くイベント」ではなく「ホストのファイルを読む」別の入力経路。symlink・原子的置換・読めない時の表示（fail closed の表示版）という別の障害クラスを持つので分ける |
| #C トークン・コスト | **7** | そのまま。ただしフックが transcript ファイルを読む新経路を含むので G5 必須 |
| #D 導入先配置 | **8 / 9** | 「自動実行で導入先に書き込む生成スクリプト」と「ドキュメント＋実環境 E2E」は性質が違う。前者は G5 対象、後者は不要 |

叩き台の `compose.monitor.yml` はスクリプト内ヒアドキュメントではなく、**原本を `.claude/monitor/compose.monitor.yml` に置いて Issue 4 で `docker compose config` により検証**し、Issue 8 はそれを複製するだけにする。生成ロジックと中身の検証を分離でき、中身は実コマンドで機械判定できるため。

## 参照した教訓（lessons.md）と反映先

| 教訓 | 反映 |
| --- | --- |
| #6 推測で値を決めない（生成物の値は事実から） | Issue 1 を実測スパイクとして独立。フィールド名・`async` 対応・usage の重複有無を実測してから確定。単価表（Issue 7）は出典 URL と取得日を必須化。base image digest（Issue 4）は実取得値のみ。compose の探索ファイル名・`include` の最低版は公式ドキュメントで確認して出典を書く |
| #11 入力の行き先を全数列挙 | Issue 2 / 3 / 6 / 7 の受け入れ条件に「行き先一覧（DB・SSE・UI・stderr・ログ）を技術メモに列挙」を入れた。Issue 2 は**stdin の全リーフに番兵文字列を注入**して allowlist 外が1つも漏れないことを検査（既知フィールドだけの検査にしない） |
| #5 変異テスト | 全実装 Issue に「列挙した防御を1つずつ無効化した隔離コピーで対応テストが FAIL すること」を受け入れ条件として入れ、結果を journal の `impl` に記録させる |
| #10 fail closed vs fail open の区別 | **フック送信は fail open**（監視が仕事を止めない＝常に exit 0・stdout 空）。**サーバ入力検証は fail closed**（不明キー・型違いは拒否）。**ループ状態の表示は「読めない」を「正常」と見せない**（Issue 6）。**テストランナーは node 不在なら FAIL**（スキップ扱いにしない）。各 Issue にどちらに倒すかを明記 |
| #10 / #11 symlink を追わない | Issue 6（loop-state.json）、Issue 7（transcript）、Issue 8（生成先・原本・既存 compose 候補の4名全て）で `-L` / `lstat` 拒否を受け入れ条件化。ダングリングリンクを「存在しない」と誤判定して書き込む経路を明示的にテスト |
| #10 grep ではなく case で検証 | Issue 2 / 7 / 8 のシェル側検証（ポート番号・イベント名・モデル ID・ツール名）は `case` のみ。複数行入力（`4319\n80` 等）を拒否するテストを必須化 |
| #5 多バイト隣接の `${var}` | 新規 `.sh` は既存 `shell-lint` が自動検出する。受け入れ条件に `bash tests/run.sh shell-lint` PASS を入れた。`hooks/` は `set -u` 検査の対象外なので、monitor-emit は `set -u` を宣言した上で多バイト隣接を `${var}` で書く |
| #10 `$( )` 内の die は親を止めない | Issue 8 の「書き込み前判定」は親シェルで行う（既存 shell-lint が検出） |
| bootstrap: フックの stdout はコンテキストに入る（ci-workflows エピックの学習） | Issue 2: monitor-emit の stdout は**全イベントで常に空**。Issue 8: bootstrap-monitor の出力は固定文字列のみ |
| #15 限界は「止まる範囲」で書く | 各 Issue で導入した防御の限界を `security.md` の「監視の限界」節へその Issue 内で書き、通ってしまう代表経路を1件「既知の限界」テストで固定する |
| 運用: 自己レビューは機能しない | G5 必須 Issue が多いのは意図的。新しいネットワークサービスを足すエピックなので削らない |
| 運用: テスト結果を見ずにコミット | 各 Issue の G1 は `if bash tests/run.sh; then ...` 形式で終了コード分岐 |

## Issue 一覧

---

### Issue 1: フック stdin と transcript の実フィールドが実測値として fixtures とスキーマ文書に固定されている

- **目的**: 以降の全 Issue が「推測したフィールド名」で書かれるのを防ぐ（lessons #6）。`agent_id` / `agent_type` / `agent_transcript_path` / `SubagentStart` / `async` はいずれも未実測
- **意図**: 実セッションで各フックイベントの stdin と transcript JSONL を採取し、**キー構造と型だけ**を匿名化した fixtures とスキーマ文書として確定した状態。後続 Issue はこの fixtures を唯一の入力仕様として使う
- **受け入れ条件**:
  - [ ] 次のイベントそれぞれについて「発火した / しなかった」が実測で記録されている: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PostToolUse, SubagentStart, SubagentStop, Stop, Notification, PreCompact（`.claude/monitor/docs/hook-events.md`）
  - [ ] 同文書に、測定した Claude Code のバージョン、測定日、測定手順が書かれている
  - [ ] サブエージェント内部のツール呼び出し（PreToolUse / PostToolUse）で `agent_id` / `agent_type` が来るか、SubagentStop で `agent_transcript_path`（または相当するキー）が来るかが「来た / 来なかった / キー名は X だった」の形で記録されている
  - [ ] フック定義の `"async": true` が受理されるか、およびフックが背景子プロセスを残して exit した場合に Claude Code が待つか（待たないか）が実測で記録されている
  - [ ] transcript JSONL の `message.usage` のキー名一覧と、**同一 `message.id` の行が複数回出現するか**が実測で記録されている（Issue 7 の重複排除の要否が決まる）
  - [ ] `.claude/monitor/test/fixtures/hook-stdin/<Event>.json` が発火した全イベント分あり、実測時のキー集合と一致している
  - [ ] 送信ペイロードのスキーマ（イベント種別の列挙・各キーの型・最大バイト長・必須/任意）が `.claude/monitor/docs/event-schema.md` に定義され、各イベントの期待送信形が `.claude/monitor/test/fixtures/emitted/<Event>.json` にある（Issue 2 と Issue 3 の契約）
  - [ ] `tests/scripts/monitor-fixtures.test.sh` が以下を検査し PASS する: 全 fixtures が妥当な JSON / emitted fixtures のキーがスキーマ文書の列挙の部分集合 / 全 fixtures の文字列値に実行時の `$HOME`・`whoami` の値・`/Users`・`/home` 配下のパスが含まれない
  - [ ] 採取用のダンプフックはコミットされていない（`git ls-files` に存在しない）。`settings.local.json` への一時登録は撤去済み
  - [ ] 変異テスト: fixtures に `$HOME` を含む値を1つ注入した隔離コピーで上記テストが FAIL する
- **依存**: なし
- **影響範囲**: `.claude/monitor/docs/`, `.claude/monitor/test/fixtures/`, `tests/scripts/monitor-fixtures.test.sh`（新規のみ。既存ファイルの変更なし）
- **セキュリティ確認**: 不要（G5 起動条件に該当しない。プロダクト実行経路の追加なし。ただし実データをコミットするため、個人情報・プロンプト本文が fixtures に残らないことを受け入れ条件で機械判定する）
- **リトライ上限**: 3
- **技術的メモ**:
  - 採取は gitignore 済みの `settings.local.json` に一時フックを登録し、stdin をスクラッチ領域へ保存する。サブエージェントを最低1体（Explore など）起動する
  - 実測の結果 `agent_id` 相当が存在しない場合、エージェント木（Issue 3 / 5）の前提が崩れる。**その時点でハードストップ扱いにしてマスターへ報告**し、後続 Issue を再定義する
  - 匿名化は値の置換のみ。キー名と入れ子構造は変えない
  - 参照教訓: #6（推測禁止）/ #5（変異テスト）

---

### Issue 2: monitor-emit フックが allowlist 抽出したイベントだけを 1 秒以内・常に exit 0 で 127.0.0.1 へ送る

- **目的**: エージェントの動きを外部へ観測可能にする最初の入口。ただし監視が本来の作業を止めたり遅らせたり、秘密を外へ運んだりしてはならない
- **意図**: `.claude/hooks/monitor-emit.sh` が Issue 1 で確定したイベントを1本で受け、スキーマどおりの JSON だけを `http://127.0.0.1:${LOOP_MONITOR_PORT:-4319}/api/events` へ送る。監視サーバの有無に関係なく、Claude Code の挙動・速度・コンテキストに一切影響しない（**fail open**）
- **受け入れ条件**:
  - [ ] Issue 1 の全 `hook-stdin` fixture を入力したとき、送信ボディが対応する `emitted` fixture とキー集合・型で一致する（node 製スタブ受信器で捕捉）
  - [ ] **stdin の全文字列リーフに固有の番兵文字列を注入**した入力で、送信ボディに現れる番兵が allowlist 化したフィールド由来のものだけである（`tool_input.content` / `new_string` / `prompt` / `tool_response` 等、スキーマ外の番兵が1つも出ない）
  - [ ] Bash ツールのコマンドはスキーマで定めた形（既定案: 先頭トークンのベース名のみ・`[A-Za-z0-9._-]` 以外を含めば `?`・最大 32 バイト。未確定事項 1 参照）でしか送られない。`export API_KEY=xxx` / `curl -H "Authorization: Bearer xxx"` の fixture で `xxx` が送信ボディに現れない
  - [ ] `file_path` はベース名のみ送られ、C0 / DEL / C1 / 双方向制御文字が除去され、スキーマの最大バイト長で切り詰められる（`loop-journal.sh` の `safe_display` と同じ方針・同じテストケース）
  - [ ] 全イベント・全異常系で **stdout が 0 バイト**、**終了コードが 0**（異常系: stdin が不正 JSON / 空 / jq 不在 / curl 不在 / サーバ不在 / サーバが接続を受けて応答しない）
  - [ ] 「接続を受けて応答しない」スタブに対し、フックの実行時間が 20 回全て 1 秒未満（perl `Time::HiRes` で計測）
  - [ ] `LOOP_MONITOR=0` のときスタブへの接続が 0 件
  - [ ] `LOOP_MONITOR_PORT` が `abc` / `0` / `70000` / `4319\n80`（複数行）/ 空 のとき既定 4319 へ倒れ、stdout は空のまま（検証は `case`）
  - [ ] `http_proxy` / `HTTPS_PROXY` / `ALL_PROXY` をスタブに向けても、プロキシ側スタブへの接続が 0 件（`--noproxy` 相当）
  - [ ] 送信先ホストは `127.0.0.1` 固定で、環境変数で変更できない（`LOOP_MONITOR_HOST` 等を設定しても送信先が変わらないテスト）
  - [ ] ペイロードは curl の argv に載らない（stdin 経由）。フック実行中の子プロセスの argv に番兵が現れないことをテストで確認
  - [ ] `.claude/settings.json` に Issue 1 で発火が確認された全イベントへ monitor-emit が登録され、既存フック（pre-tool-guard / loop-guard / post-tool-format / stop-quality-check / bootstrap-project）の定義は jq で比較して不変
  - [ ] `security.md` に「監視の限界（送信側）」節があり、送る項目・送らない項目・既知の限界が書かれ、既知の限界の代表経路1件が `assert_ok` の「既知の限界」テストで固定されている
  - [ ] `bash tests/run.sh` 全 PASS（shell-lint・docs-consistency 含む）
  - [ ] 変異テスト: 次の防御を1つずつ外した隔離コピーでそれぞれ対応テストが FAIL し、結果が journal `impl` に記録されている — allowlist 抽出 / 制御文字除去 / 長さ制限 / 背景化と stdout 切り離し / `--max-time` / `--noproxy` / ポート検証 / `LOOP_MONITOR=0`
- **依存**: Issue 1
- **影響範囲**: `.claude/hooks/monitor-emit.sh`（新規）, `.claude/settings.json`, `tests/scripts/monitor-emit.test.sh`（新規）, `tests/scripts/fixtures/`（スタブ受信器）, `tests/scripts/lib.sh`（必要なら）, `.claude/rules/security.md`
- **セキュリティ確認**: **必須**（外部由来の値＝ツール入力・ファイル名を受け取り、ネットワークへ送る新しい境界。秘密情報の流出経路になりうる。フックは全セッションで自動実行される）
- **リトライ上限**: 3
- **技術的メモ**:
  - **fail open の側**。loop-guard とは逆で、失敗は黙って捨てる。ただし「黙って捨てる」のはネットワーク失敗だけ。入力を検証できなかった値は送らない（空・`?` に倒す）
  - SessionStart / UserPromptSubmit のフック stdout はコンテキストに入る。PreToolUse の exit 2 はツールを止める。だから stdout 空・exit 0 は最重要条件
  - 背景化した curl が親の stdout / stderr を継承すると Claude Code が待つ可能性がある。Issue 1 の実測結果に従い `async` 登録か `>/dev/null 2>&1 &` のどちらか（両方でも可）を選ぶ
  - 値の行き先の列挙（技術メモとして PR に書く）: 送信ボディ / curl の argv / stderr / 一時ファイル（作らない）
  - `hooks/` は shell-lint の `set -u` 検査対象外だが、monitor-emit は `set -u` を宣言する。多バイト隣接は `${var}`
  - スタブ受信器は node で書く（`nc` は BSD / GNU で挙動が違う）。スタブは `tests/` 配下に置き、導入先へは持ち込まない
  - 参照教訓: #11（行き先の全数列挙）/ #10（case・fail open と fail closed の区別）/ #5（変異テスト・多バイト）/ #15（限界の書き方）/ ci-workflows（フック stdout はコンテキスト）

---

### Issue 3: 受信サーバが検証済みイベントを SQLite に保存し、セッション・エージェント木を `/api/state` と SSE で返す

- **目的**: 送られてきたイベントを永続化し、ビューが読む単一の状態源を作る
- **意図**: `.claude/monitor/server/` の Node（`node:` 組み込みモジュールのみ・依存ゼロ）サーバが、スキーマ外を全て拒否（**fail closed**）した上でイベントを保存し、セッション一覧・エージェント木（メイン→サブ、稼働中 / 待機 / 完了、実行中ツール）を返し、新着を SSE で配信する
- **受け入れ条件**:
  - [ ] Issue 1 の全 `emitted` fixture を POST すると 2xx で受理され、`GET /api/state` に反映される（Issue 2 との契約テスト）
  - [ ] 次は全て 4xx で拒否され DB 行数が増えない: 不正 JSON(400) / 64KB 超(413、上限到達時点で読み取りを打ち切る) / `Content-Type` が `application/json` 以外(415) / スキーマ外のキーを含む / 型違い / 列挙外のイベント種別 / 最大長超過
  - [ ] `Host` ヘッダが `127.0.0.1:<port>` / `localhost:<port>` 以外なら拒否される（DNS リバインディング対策）
  - [ ] `Origin` ヘッダが存在し同一オリジンでなければ拒否される。レスポンスに `Access-Control-Allow-Origin` を一切付けない
  - [ ] 既定の listen アドレスは `127.0.0.1`。`MONITOR_BIND` でのみ変更できる
  - [ ] SQL は全てプレースホルダ付きプリペアドステートメント。文字列値に `'); DROP TABLE events;--` を含むイベントが原文のまま保存・返却され、テーブルが残る
  - [ ] ソース全体に SQL 文字列へのテンプレート埋め込み（`` prepare(`...${`` 形）が無いことを node テストで静的に検査する
  - [ ] 全 `.mjs` の import 指定子が `node:` か相対パスのみ（依存ゼロの機械判定）。`package.json` を置く場合 `dependencies` / `devDependencies` が空
  - [ ] 時刻・順序はサーバ受信時刻と連番で付与し、送信側の値は保存しても順序決定に使わない
  - [ ] エージェント状態の導出（fixture 系列で検証）: SubagentStart（または当該 `agent_id` の初出）→ 稼働中、SubagentStop → 完了、メインは UserPromptSubmit → 稼働中、Stop / Notification → 待機、SessionEnd → 終了。PreToolUse があり同一 `tool_use_id` の PostToolUse が無いツールが「実行中ツール」
  - [ ] `GET /api/stream` が新着イベントを SSE で配信する。同時接続が上限（提案既定 16）を超えると 503
  - [ ] 5xx 応答の本文に例外メッセージ・スタックトレース・ファイルパスを含まない（DB を閉じて強制的に失敗させて検証）
  - [ ] 保持期間ポリシー（未確定事項 3）に従い古い行が削除される
  - [ ] `tests/scripts/monitor-server.test.sh` が `node --test .claude/monitor/test/` を実行し、`bash tests/run.sh` から回る。**node が無い場合はスキップではなく FAIL**
  - [ ] `template-ci.yml` の `tests` ジョブで Node 24 を用意してこのスイートが走る。docs-consistency の必須ジョブ検査が引き続き PASS
  - [ ] `security.md` の「監視の限界」節に受信側の限界（認証なし・同一端末の任意プロセスは書き込み・読み出しできる・セキュリティ境界ではない）が書かれ、代表経路1件が「既知の限界」テストで固定されている
  - [ ] 変異テスト: Host 検査 / Origin 検査 / Content-Type 検査 / ボディ上限 / 未知キー拒否 / プレースホルダ を1つずつ外した隔離コピーで対応テストが FAIL し、journal `impl` に記録されている
- **依存**: Issue 1（スキーマ）。Issue 2 と並列可能だが、契約テストの実データ確認のため 2 → 3 の順を推奨
- **影響範囲**: `.claude/monitor/server/`（新規: `server.mjs`, `store.mjs`, `validate.mjs` 等）, `.claude/monitor/test/`, `tests/scripts/monitor-server.test.sh`（新規）, `.github/workflows/template-ci.yml`, `tests/scripts/docs-consistency.test.sh`（必要なら）, `.claude/rules/security.md`
- **セキュリティ確認**: **必須**（HTTP の外部入力境界を新設、SQL を新規追加。CI に `actions/setup-node` を追加＝外部 Action 依存の追加）
- **リトライ上限**: 3
- **技術的メモ**:
  - **fail closed の側**。未知キーは「落として受理」ではなく「拒否」。フック側（Issue 2）とは倒す方向が逆であることを PR に明記する
  - 値の行き先の列挙: SQLite / `/api/state` の JSON / SSE / stderr ログ。ログにはイベント本文を出さない
  - 認証は持たない（マスター承認済みの叩き台の前提）。代わりに Host / Origin / Content-Type でブラウザ経由の書き込み・読み出しを塞ぐ。これは「同一端末の悪意あるプロセス」は止めない。限界として明記
  - `node:sqlite` は Node 22.13 以降でフラグ不要だが ExperimentalWarning を出す。手元 v22.22 と CI の Node 24 の両方で通すかは未確定事項 4
  - 参照教訓: #10（fail closed）/ #11（行き先列挙）/ #5（変異テスト）/ #15（限界）/ #6（上限値は提案既定値として明示し承認を得る）

---

### Issue 4: `node:24-alpine`（digest 固定）の監視イメージが非 root・ヘルスチェック付きでビルドされ CI でスモークされる

- **目的**: 導入先の Docker 環境で監視サーバを確実に立ち上げる実体を用意する
- **意図**: `.claude/monitor/Dockerfile` と原本 `.claude/monitor/compose.monitor.yml` が存在し、`docker compose config` が通り、イメージが非 root で起動して `/api/state` に 200 を返す
- **受け入れ条件**:
  - [ ] Dockerfile の `FROM` が `node:24-alpine@sha256:<digest>` 形式（digest はレジストリから実取得した値。取得日をコメントに書く）であることを docs-consistency で機械判定
  - [ ] `USER` が root 以外であることを機械判定。コンテナ内 `id -u` が 0 でない（CI スモーク）
  - [ ] `HEALTHCHECK` が node 自身で `/api/state` を叩く（curl / wget をイメージに追加しない）
  - [ ] `.dockerignore` により `test/`・`docs/` がビルドコンテキストから除外される
  - [ ] 原本 `compose.monitor.yml` について `docker compose -f .claude/monitor/compose.monitor.yml --project-directory . config` が成功し、出力で次を確認: ports が `127.0.0.1:${LOOP_MONITOR_PORT:-4319}` に bind / `read_only: true` / `cap_drop: [ALL]` / `security_opt: no-new-privileges:true` / 名前付きボリュームに DB / `./.claude/memory` を**ディレクトリ単位で** `:ro` マウント
  - [ ] ビルドコンテキストのパスが、原本をプロジェクト直下へ複製した場合（Issue 8）に `./.claude/monitor` を指すことを実コマンドで確認（`include` 時の相対パス解決は推測しない）
  - [ ] `template-ci.yml` に docker build → 起動 → ヘルス待ち → `/api/state` 200 → 停止のスモークがあり、docs-consistency の必須ジョブ検査が更新されて PASS
  - [ ] `security.md` の「監視の限界」節にコンテナ側の限界（ポートはローカル bind のみ・認証なし）が追記されている
  - [ ] 変異テスト: `USER` 行を消す / digest を外す / `127.0.0.1` を外す を1つずつ行った隔離コピーで対応テストが FAIL
- **依存**: Issue 3
- **影響範囲**: `.claude/monitor/Dockerfile`, `.claude/monitor/.dockerignore`, `.claude/monitor/compose.monitor.yml`（新規・原本）, `.github/workflows/template-ci.yml`, `tests/scripts/docs-consistency.test.sh`, `.claude/rules/security.md`
- **セキュリティ確認**: **必須**（base image の追加＝依存追加。ポート公開範囲の決定）
- **リトライ上限**: 3
- **技術的メモ**:
  - loop-state.json は `mv` で置き換えられるため、ファイル単位の bind mount は更新が見えなくなる（事実: `loop-state.sh` L68-77）。ディレクトリ単位でマウントする
  - コンテナ内の listen は `MONITOR_BIND=0.0.0.0`、公開は compose の `127.0.0.1:` bind で絞る。両方そろって初めてローカル限定になることを限界節に書く
  - 手元の Docker デーモンは停止中。G2 実施時は起動が前提（未確定事項 5）
  - 参照教訓: #6（digest・パス解決は実値）/ #5（変異テスト）/ #15（限界）

---

### Issue 5: 専用ビューでセッション一覧・エージェント木・イベント時系列がリアルタイムに表示される

- **目的**: 人間が「今どのメイドが何をしているか」を一目で把握できるようにする
- **意図**: サーバが配信するビルド無しの静的ビュー（`index.html` / `app.js` / `style.css`）が `/api/state` と SSE を読み、①セッション一覧 ②エージェント木（`sub-agent-*` はメイド名で表示、稼働中 / 待機 / 完了、実行中ツール）④イベント時系列を描画する
- **受け入れ条件**:
  - [ ] 静的配信は固定の許可リスト（`/`, `/app.js`, `/style.css`）のみ。`/../server/server.mjs`・`/%2e%2e/`・`/app.js/..` 等は 404（URL からパスを組み立てない）
  - [ ] 全応答に `Content-Security-Policy: default-src 'self'`（インラインスクリプト不可）・`X-Content-Type-Options: nosniff`・`X-Frame-Options: DENY` が付く
  - [ ] `public/*.js` に `innerHTML` / `outerHTML` / `insertAdjacentHTML` / `document.write` / `eval` / `new Function` が無いことを node テストで静的に検査
  - [ ] 状態導出・メイド名対応（CLAUDE.md の 11 名。未知の `agent_type` は長さ制限付きの原文）は DOM 非依存の純関数として `node --test` で検証
  - [ ] G2（Playwright MCP）: fixture 系列を POST すると、メイン→サブの木・状態・実行中ツールが画面に出て、SubagentStop で完了表示に変わる
  - [ ] G2: `<img src=x onerror=alert(1)>` を含むイベントを送ると、画面に文字列として表示され、`img` 要素が生成されずダイアログも出ない
  - [ ] G2: 時系列は SSE で追記され、DOM 上の保持件数が上限（提案既定 500）を超えない
  - [ ] G2 で撮ったスクリーンショットが削除され `git status` に残骸が無い
  - [ ] 変異テスト: 静的パス許可リスト / CSP ヘッダ / innerHTML 静的検査 を1つずつ外した隔離コピーで対応テストが FAIL
- **依存**: Issue 3
- **影響範囲**: `.claude/monitor/public/`（新規）, `.claude/monitor/server/`（静的配信ルート・ヘッダ）, `.claude/monitor/test/`
- **セキュリティ確認**: **必須**（HTTP ルートの追加＝外部入力境界の変更。外部由来文字列を DOM に描画する XSS 面）
- **リトライ上限**: 3
- **技術的メモ**:
  - DOM 生成は `textContent` と `createElement` のみ
  - ループ状態パネル（③）は Issue 6、トークン・コスト（Issue 7）はこの Issue では枠も作らない（過剰先取りをしない）
  - 参照教訓: #11（描画は行き先の一つとして列挙）/ #5（変異テスト）
  - **#19 / #20 で確定した前提**:
    - `.claude/monitor/.dockerignore` は許可リスト方式（`*` で全除外 → `!server` で戻す → 秘密パターン）。ビューの静的ファイルを `server/` 以外（例: `public/`）に置くなら、`!public` を秘密パターンより前に足し、Dockerfile に `COPY` を足す。足さないとイメージに入らない。`monitor-image.test.sh` の許可リスト検査（`di_allowlist_ok`）の前提も同時に更新する
    - ビューは相対 URL だけを使い、`localhost` と `127.0.0.1` を混在させない（Sec-Fetch-Site / Host 検査）
    - `file_path` には `<` や `"` を含む値が通る。描画時にエスケープする
    - 待機状態は Stop 由来（#18 は Notification を送らない）
    - `/api/state` は seq が進むたびに全行から導出する。高頻度ポーリングの前に増分導出か上限を検討する

---

### Issue 6: ビューのループ状態パネルが loop-state.json を安全に読み、halted を赤・読めない状態を「不明」と表示する

- **目的**: インナーループの retry / ゲート結果 / ハードストップを人間がビューで即座に把握できるようにする
- **意図**: サーバが読み取り専用マウントされた `loop-state.json` を許可リストのフィールドだけ取り出して `/api/state` に載せ、ビューが issue・retry/上限・G1〜G5・経過時間/上限・halted を表示する。**読めない状態を「正常」と見せない**
- **受け入れ条件**:
  - [ ] `loop-state.json` がシンボリックリンク（リンク先が妥当な JSON でも）なら読まず「不明（リンク）」を返す（`lstat` で判定）
  - [ ] 不在 / 0 バイト / 不正 JSON / 上限（提案既定 64KB）超 / 必須フィールド欠落 / 型違い のいずれでも `status: "unknown"` 相当を返し、`running` / `completed` として返さない
  - [ ] 返すフィールドは許可リスト（`issue`, `branch`, `epic`, `status`, `retry`, `limits.*`, `gates.G1..G5.result`, `halt_reason`, `started_at`）のみ。未知フィールドや `gates.*.reason` 等は返さない（`halt_reason` は長さ制限・制御文字除去）
  - [ ] `mv` による置き換え後、ポーリング周期（提案既定 2 秒）以内に新しい内容が `/api/state` と SSE に反映される（原子的置換を再現するテスト）
  - [ ] G2: `loop-state.sh stop "理由"` 相当の状態で halted が赤表示、状態ファイル削除で「不明」表示になる
  - [ ] `security.md` の「監視の限界」節に、読み取りの限界（worktree 側の状態は対象外など、未確定事項 2 の結論）が追記されている
  - [ ] 変異テスト: `lstat` 拒否 / サイズ上限 / 「不明」への倒し / フィールド許可リスト を1つずつ外した隔離コピーで対応テストが FAIL
- **依存**: Issue 3, Issue 5
- **影響範囲**: `.claude/monitor/server/`（読み取り・配信）, `.claude/monitor/public/`（パネル）, `.claude/monitor/test/`, `.claude/rules/security.md`
- **セキュリティ確認**: **必須**（ホストのファイルを読んで UI へ出す新しい入力経路。gitignore 済みファイルも `git add -f` やリンクで持ち込めることは過去に実証済み）
- **リトライ上限**: 3
- **技術的メモ**:
  - fail closed の**表示版**。lessons #10 の「判定できなかったを合格と同じ扱いにしない」をビューにも適用する
  - fs.watch ではなくポーリング。正しさがイベント通知の到達性に依存しないため
  - **#20 で確定した前提**: コンテナ内では `./.claude/memory` が `/memory` にディレクトリ単位・読み取り専用でマウントされる（`compose.monitor.yml`）。読む先は `/memory/loop-state.json`。コンテナ外で動かす場合のパスの決め方（環境変数で渡すか）は本 Issue で決める。サーバ（`server.mjs`）にはまだ参照コードが無い
  - 参照教訓: #10（fail closed・symlink）/ #11（行き先列挙）/ #5（変異テスト）

---

### Issue 7: Stop / SubagentStop 時のトークン使用量が session / agent 別に集計され、推定コストとしてビューに表示される

- **目的**: どのメイドがどれだけトークンとコストを燃やしているかを可視化し、ループ設計の判断材料にする
- **意図**: monitor-emit が transcript の `message.usage` を数値だけ集計して送り、サーバがスナップショットとして保存し、単価表で推定コストを算出、ビューに「推定」ラベル付きで表示する
- **受け入れ条件**:
  - [ ] Issue 1 で記録した usage キー（input / output / cache 生成 / cache 読み取り）ごとの合計が、fixture transcript に対して手計算値と一致する
  - [ ] Issue 1 で同一 `message.id` の重複行が確認されていれば、重複を1回として数える（重複を含む fixture で検証）
  - [ ] transcript のパスがシンボリックリンク・通常ファイル以外・サイズ上限超（提案既定: 未確定事項 6）なら集計せず「不明」を送る（部分合計を送らない）
  - [ ] 送信されるのは数値とモデル ID のみ。モデル ID は `case` で `[A-Za-z0-9._-]` かつ最大長以内のみ許可、それ以外は `unknown`。transcript の本文・プロンプト文字列が送信ボディに現れない（番兵注入で検証）
  - [ ] サーバは同一 session / agent のスナップショットを**置き換え**で保存する（同じスナップショットを2回送っても合計が倍にならない）
  - [ ] 単価表 `.claude/monitor/server/pricing.mjs` に出典 URL と取得日があり、単価表に無いモデルはコスト「不明」（0 円扱いにしない）
  - [ ] Issue 2 の条件（stdout 0 バイト・exit 0・1 秒未満・`LOOP_MONITOR=0`）が Stop / SubagentStop でも維持される（10MB 級 fixture transcript で計測）
  - [ ] G2: 実セッションでサブエージェント完了後、ビューのトークン数が増え「推定」と表示される
  - [ ] 変異テスト: symlink 拒否 / サイズ上限 / 重複排除 / 置き換え保存 / 不明モデル扱い を1つずつ外した隔離コピーで対応テストが FAIL
- **依存**: Issue 1, 2, 3, 5
- **影響範囲**: `.claude/hooks/monitor-emit.sh`, `.claude/monitor/docs/event-schema.md`（usage イベントの追加）, `.claude/monitor/server/`, `.claude/monitor/public/`, `.claude/monitor/test/`, `tests/scripts/monitor-emit.test.sh`, `.claude/rules/security.md`
- **セキュリティ確認**: **必須**（フックがファイルを読む新経路の追加と、受信スキーマの拡張＝外部入力境界の変更）
- **リトライ上限**: 3
- **技術的メモ**:
  - transcript は累積なので「差分の加算」ではなく「最新スナップショットの置き換え」
  - 単価は推測で書かない。公式価格ページから取得し、マスターの確認を得る（未確定事項 7）
  - 参照教訓: #6（単価・キー名は事実から）/ #10（symlink・case・部分結果を送らない）/ #11（行き先列挙）/ #5（変異テスト）

---

### Issue 8: bootstrap-monitor.sh が導入先に compose.monitor.yml を生成し、compose ファイルが無ければ include だけの compose.yaml を作る

- **目的**: 導入先で `docker compose up` した時に監視コンテナが必ず一緒に立つ状態を、既存ファイルを一切壊さずに作る
- **意図**: SessionStart から自動実行される別スクリプトが、原本 `.claude/monitor/compose.monitor.yml` をプロジェクト直下へ複製し、compose ファイルが1つも無ければ `include` だけの `compose.yaml` を生成、有れば触らずに追記方法を案内する
- **受け入れ条件**:
  - [ ] compose ファイル候補が無い場合: `compose.monitor.yml`（原本とバイト一致）と `compose.yaml`（`include` で `compose.monitor.yml` を参照するだけ）が生成され、`docker compose config` が成功する
  - [ ] 候補（公式ドキュメントで確認した探索名。技術メモ参照）が1つでも存在する場合: その全ファイルのバイト内容と mtime が実行前後で不変、`compose.yaml` は生成されず、`include` 追記の案内が出力される
  - [ ] 既存の `compose.monitor.yml` は上書きされない（バイト不変）
  - [ ] 生成先・原本・compose 候補のいずれかがシンボリックリンク（**ダングリング含む**）なら書き込まず警告して exit 0。リンク先にファイルが作られていないことを検査
  - [ ] 書き込みは noclobber（`set -C`）で行い、書き込み直前にリンク性と存在を再確認する（#24 G5 で強化: perl の `sysopen(O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK|O_NOCTTY)` に置換。既存の上書き・リンクの追従・判定後の差し替えを 1 回の open で原子的に拒む。noclobber は通常ファイル以外へのリンクを拒めないため）
  - [ ] 2回連続実行で2回目は何も変更しない（冪等）
  - [ ] `--dry-run` は何も書かず生成内容を出す / `--quiet` は何もしなかった時に黙る / `LOOP_BOOTSTRAP=0` で何もしない / 未知の引数で exit 1
  - [ ] 出力は固定文字列のみ（外部由来の値を載せない）
  - [ ] 生成条件は未確定事項 8 の決定に従う（テンプレート自身のリポジトリで SessionStart 時に生成物が出ないことを含めてテスト）
  - [ ] `settings.json` の SessionStart に bootstrap-project の**後**に登録され、既存フックは不変。`bootstrap-project.sh` の差分が 0
  - [ ] `lib.sh` の `new_sandbox` コピー対象に `bootstrap-monitor.sh` と原本 compose が追加されている
  - [ ] `tests/scripts/bootstrap-monitor.test.sh` と `bash tests/run.sh` 全 PASS（shell-lint の多バイト隣接・`$( )` 内 die 検査を含む）
  - [ ] 変異テスト: symlink 検査（各対象）/ noclobber / 既存候補検出 / 冪等判定 を1つずつ外した隔離コピーで対応テストが FAIL
- **依存**: Issue 4
- **影響範囲**: `bootstrap-monitor.sh`（新規・`.claude` 配下の scripts ディレクトリ）, `.claude/settings.json`, `tests/scripts/bootstrap-monitor.test.sh`（新規）, `tests/scripts/lib.sh`, `.claude/rules/security.md`（#24 G3 で追加: 自動書き込み経路の止まる範囲・既知の限界。教訓 #15）
- **セキュリティ確認**: **必須**（ユーザー操作ゼロで導入先リポジトリに書き込む自動実行経路。symlink による書き込み先すり替えは本リポジトリで実際に指摘された障害クラス）
- **リトライ上限**: 3
- **技術的メモ**:
  - `bootstrap-project.sh` の `say` / `note` / 早期 exit / 再確認 + noclobber（L29-40, L56-74, L412-430）の型を流用する。**同居はさせない**（あちらは ci.yml 既存で早期 exit する単一成果物設計）
  - compose の探索ファイル名と `include` が使える最低の Compose 版は公式ドキュメントで確認し、出典をスクリプトのコメントに書く（推測で列挙しない）
  - 書き込み前判定は親シェルで行う（`$( )` 内の die は親を止めない）
  - 参照教訓: #10（symlink・親シェル判定・case）/ #11（照合値の偽装経路）/ #6（探索名は事実から）/ #5（変異テスト・多バイト）/ ci-workflows（出力はコンテキストに入る）
  - **#20 で確定した前提（実測）**:
    - `include` で取り込む場合は `include: [{path: compose.monitor.yml, project_directory: .}]` の形が必須。`project_directory` が無いと build context が `.claude/monitor/.claude/monitor` に解決されて失敗する。生成後に `docker compose config` で build context が `./.claude/monitor` を指すことを実コマンドで確認する
    - 原本は monitor を専用ネットワーク `monitor-net` に置く（導入先のアプリと同居させないため。同居すると Host 偽装で読み書きできる）。実ネットワーク名は compose プロジェクト名で prefix される。導入先が同名の `monitor-net` を定義していると衝突するので、案内文に書く（既存ファイルは触らない方針）
    - 原本は複製後もバイト一致であることを前提にしたテストがある（`tests/scripts/monitor-image.test.sh`）
- **#21 / #22 / #23 への共通の前提（#20 で確定）**: 監視用 compose にサービスを足す場合、`monitor-net` に入れたサービスは monitor と同居し、Host を偽れば読み書きできる。監視系以外を入れない。足す場合は Issue に明記し、`monitor-image.test.sh` の分離検査（`c_dedicated_net` / `c_net_isolated`）の前提を見直す

---

### Issue 9: 導入手順と限界が文書化され、サンドボックス導入先で監視ビューに実セッションのメイン＋サブが表示されることが実証されている

- **目的**: マスターの要件（環境構築で監視コンテナが必ず立ち、専用ビューで状態が見える）を端から端まで実環境で証明し、導入者が迷わない状態にする
- **意図**: README / CLAUDE.md / AGENTS.md が実体と一致し、E2E 手順が再現可能に記録されている
- **受け入れ条件**:
  - [ ] README に導入手順・ポート変更（`LOOP_MONITOR_PORT`）・停止方法（`LOOP_MONITOR=0`、コンテナ停止）・Compose の最低版・既存 compose がある場合の `include` 追記手順・Codex 版は対象外であることが書かれている
  - [ ] CLAUDE.md（と AGENTS.md）のディレクトリ構造・初回セットアップ節に `.claude/monitor/` と `bootstrap-monitor.sh` が載り、docs-consistency が PASS
  - [ ] E2E（G2）: 空の Next.js 風 `package.json` のサンドボックスで bootstrap-monitor → `docker compose up -d` → `http://127.0.0.1:4319` をブラウザで開ける
  - [ ] E2E（G2）: そのサンドボックスで実セッションを開始しサブエージェントを1体起動 → 木にメイン＋サブが出る → 完了で状態遷移 → トークン数が増える → `loop-state.sh` の halted が赤で出る
  - [ ] E2E（G2）: コンテナ停止状態でツール呼び出しを行い、monitor-emit の実行時間が 1 秒未満
  - [ ] スクリーンショットは確認後に削除され、`git status` に残骸が無い
  - [ ] `bash tests/run.sh` 全 PASS
  - [ ] （#24 G3 で追加）README に次を書く: 既存 compose（直下・祖先）がある導入先では bootstrap-monitor の案内は `compose.monitor.yml` を生成した初回のセッションにしか出ない（`--quiet` のため）ので、`include` の追記は README の手順が恒久的な導線であること／環境変数や環境ファイルの `COMPOSE_FILE`・`-f` を使う導入先では生成した `compose.yaml` は読まれないので、使っている compose ファイルに `include` を追記すること／bootstrap-monitor は perl（Fcntl）を使い、perl が無い環境では compose を生成しない（#24 G3 で追加）
- **依存**: Issue 1〜8 全て
- **影響範囲**: `README.md`, `CLAUDE.md`, `AGENTS.md`, `tests/scripts/docs-consistency.test.sh`（必要なら）
- **セキュリティ確認**: 不要（ドキュメントと検証のみ。G5 起動条件に該当しない。セキュリティ上の限界の記述は各実装 Issue で security.md に書き済み）
- **リトライ上限**: 3
- **技術的メモ**:
  - E2E はサンドボックスで行い、テンプレート本体に compose ファイルを生成させない
  - 参照教訓: 運用（テスト結果の終了コードで分岐）/ dev-flow Step 7-1（スクショ後始末）

---

## 実行順序

```
1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9
```

- 依存上の並列可: 2 と 3（ともに 1 のみに依存）、4 と 5（ともに 3 に依存）
- ただし **逐次実行を推奨**。5 / 6 / 7 は同じ `public/app.js` を触り、2 / 7 は同じ `monitor-emit.sh` を触る。journal の並列追記はコンフリクトになる（journal/README.md）
- Issue 1 完了時点で、実測結果（特に `agent_id` の有無）をマスターが確認してから 2 に進むことを推奨

## 未確定事項（マスターの判断が必要）

1. **Bash コマンドの送信範囲**: 叩き台は「先頭 80 文字」だったが、`export API_KEY=...` や `curl -H "Authorization: Bearer ..."` の先頭 80 文字には秘密が入る。本分解では既定案を「先頭トークンのベース名のみ」にした。80 文字（制御文字除去付き）を採るならリスク受容の明示が必要
2. **worktree 実行時のループ状態**: `loop-state.sh` は `${CLAUDE_PROJECT_DIR}/.claude/memory` に書く。`/issue-flow` を worktree で回した時に状態がどちらに書かれるかは未実測。worktree 側に書かれる場合、コンテナのマウント（メインのチェックアウトの `.claude/memory`）からは見えない。「対象外として限界に明記」か「別途対応 Issue を追加」か
3. **保持期間**: SQLite の保持ポリシー（例: 7 日 or 10 万行で古い順に削除）。値の決定が必要
4. **Node のバージョン方針**: コンテナは Node 24。手元は v22.22.0。サーバコードとテストを Node 22.13 以上でも動く範囲に留めるか、手元も Node 24 を必須にするか
5. **Docker の前提**: 手元の Docker デーモンが停止中。Issue 4 以降の G2 は Docker Desktop の起動が前提
6. **transcript のサイズ上限**: Stop 時の集計対象の上限（1 秒予算内に収まる値を Issue 7 で実測してから決めるか、先に値を決めるか）
7. **単価表**: 推定コストに使うモデル単価。実装時に公式価格ページから取得した値をマスターが確認して確定する
8. **bootstrap-monitor の生成条件**: 叩き台は「常に生成」。しかしそれだとテンプレート自身のリポジトリでも SessionStart のたびに compose ファイルが生成される。案: 「`package.json` または compose ファイルが存在する場合のみ生成」。Node 以外の導入先でも必ず生成したいなら別の判定が必要
9. **既存 compose がある導入先**: 「既存は触らない」を守ると、既存 compose がある導入先では案内を出すだけで自動では監視は立たない（要件の「必ず」とずれる）。案内だけで良いか
10. **提案既定値の承認**: SSE 同時接続 16 / DOM 保持 500 件 / loop-state 読み取り上限 64KB / ポーリング 2 秒 / ボディ上限 64KB / 既定ポート 4319

## マスターの決定（2026-09-28 承認時）

- 分解: **9 本・逐次で承認**
- 1（Bash 送信範囲）: **先頭トークンのベース名のみ**
- 4（Node）: **Node 22.13 以上で動く範囲**。コンテナは 24、手元テストは 22 でも通す
- 9（既存 compose）: **案内のみ**。既存は触らない。compose ファイルが無い時だけ自動生成
- 2 / 3 / 5 / 6 / 7 / 8 / 10: Planner の既定案で進める。2（worktree）は限界として明記、3（保持）は 7 日 or 10 万行、6 は Issue 7 で実測してから決める、7 は実装時にマスター確認

## マスターの決定（2026-10-10・#20 からの持ち越し）

- 共有トークン認証: **見送り**。トークンファイルを読める同一ユーザーのプロセスは止められず、効くのはコンテナと別ユーザーだけ。送信側の argv 漏えい対策・ブラウザ側の認証（URL か Cookie）・置き場所（`.claude/memory` はコンテナに `:ro` で見える）の再設計が要り、扱う値は許可リストで絞ったメタデータに留まるため、コストに見合わない
- 再検討の条件: 監視サーバが何かを**実行する**機能（停止・承認など）を持つ / 表示にプロンプトや引数などの機微な値が加わる / 信頼できないコンテナと同じマシンで常時動かす運用になる

## マスターの決定（2026-10-10・#23 の単価表＝未確定事項 7）

- 出典: https://platform.claude.com/docs/en/about-claude/pricing（2026-10-10 取得・USD / MTok）
- 載せるモデル（入力 / 5 分キャッシュ書き込み / 1 時間キャッシュ書き込み / キャッシュ読み取り / 出力）:
  `claude-fable-5-1` 10 / 12.50 / 20 / 0.25 / 50、`claude-opus-5-5` 4 / 5 / 8 / 0.20 / 20、
  `claude-sonnet-5-5` 2 / 2.50 / 4 / 0.10 / 10、`claude-haiku-4-5-20251001` 1 / 1.25 / 2 / 0.10 / 5
- コスト「不明」にするもの: 表に無いモデル、`claude-haiku-5-5`（プロンプト長で単価が変わり、合計からは判定できない）、fast mode（`usage.speed` が fast）、US 限定推論（`inference_geo` が us・1.1 倍）

## 起票・進捗

| # | GitHub | 状態 |
| --- | --- | --- |
| 1 | #17 | [x] |
| 2 | #18 | [x] |
| 3 | #19 | [x] |
| 4 | #20 | [x] |
| 5 | #21 | [x] |
| 6 | #22 | [x] |
| 7 | #23 | [x] |
| 8 | #24 | [ ] |
| 9 | #25 | [ ] |

統合ブランチ: `epic/ai-monitor`
