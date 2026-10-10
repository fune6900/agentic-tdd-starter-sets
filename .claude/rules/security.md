# セキュリティルール

コードレビュー（`/review-pr`）では必ずこのルールを照合すること。
違反が1件でもあれば重要度「高」として差し戻す。

---

## 入力バリデーション

- **全ての外部入力を Zod でバリデーションする**（フォーム・クエリパラメータ・APIレスポンス）
- Server Actions の引数は必ず Zod スキーマで検証する
- クライアントサイドのバリデーションは UX のため。セキュリティはサーバーサイドで担保する

```ts
// OK: Server Action での入力検証
const InputSchema = z.object({
  query: z.string().min(1).max(200),
});

export async function searchArticles(input: unknown) {
  const parsed = InputSchema.safeParse(input);
  if (!parsed.success) throw new Error("Invalid input");
  // ...
}

// NG: 検証なしで使用
export async function searchArticles(query: string) {
  const result = await db.article.findMany({ where: { title: query } });
}
```

---

## SQLインジェクション対策

- **生SQLは原則禁止**。Prisma の型安全クエリを使う
- どうしても生SQLが必要な場合は Prisma の `$queryRaw` + パラメータバインドを使う

```ts
// OK
await prisma.article.findMany({ where: { title: input.title } });

// OK: 生SQLが必要な場合
await prisma.$queryRaw`SELECT * FROM article WHERE title = ${input.title}`;

// NG: 文字列結合は絶対禁止
await prisma.$queryRawUnsafe(`SELECT * FROM article WHERE title = '${title}'`);
```

---

## XSS対策

- `dangerouslySetInnerHTML` の使用は原則禁止
- 使用する場合は DOMPurify でサニタイズしてからセットする
- ユーザー入力を React の JSX に直接展開する場合、React が自動エスケープするため通常は安全
- `eval()` / `new Function()` は絶対禁止

---

## 認証・認可

- 認証状態のチェックは Server Component / Server Action で行う。クライアントのみの認証チェックは信頼しない
- セッショントークン・JWTは `httpOnly` Cookieで管理する
- ロールベースのアクセス制御（RBAC）はサーバーサイドで実施する

---

## 機密情報管理

- **APIキー・シークレットは環境変数のみ**。コードに直書き禁止
- クライアントに公開していい環境変数のみ `NEXT_PUBLIC_` プレフィックスを付ける
- `.env` 系ファイルは `.gitignore` に含める（コミット禁止）
- `.env.example` にキー名のみ記載し、値は書かない

```bash
# .env.example（値なし）
DATABASE_URL=
SUPABASE_URL=
SUPABASE_KEY=
NEXT_PUBLIC_APP_URL=
```

---

## 依存関係

- `npm audit` で critical / high の脆弱性があれば即座に修正する
- 依存パッケージは定期的に更新する（CI に `npm audit` を組み込む）
- 信頼できないパッケージは使用しない（ダウンロード数・メンテナ・ライセンスを確認）

---

## HTTPセキュリティヘッダー

`next.config.ts` で以下のヘッダーを設定すること（本番環境前に必須）:

```ts
const securityHeaders = [
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "X-XSS-Protection", value: "1; mode=block" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  {
    key: "Content-Security-Policy",
    value: "default-src 'self'; img-src 'self' data: blob:; script-src 'self'",
  },
];
```

---

## 危険コマンドの実行ガード（`pre-tool-guard.sh`）

`PreToolUse` フックが Bash の実行前に**コマンド文字列全体**を走査し、破壊的な操作をブロックする。

```
rm -rf / rm -r /  |  git push --force / -f  |  git reset --hard  |  git clean -fd
chmod -R 777      |  > /dev/sda / mkfs / dd if=  |  fork bomb
DROP TABLE / DROP DATABASE / TRUNCATE
（Codex 版はさらに sudo と --no-verify）
```

### `.env` 系ファイルを名前で触る Bash コマンドを止める

`settings.json` の `Edit(.env)` / `Read(.env)` の deny は**ファイル操作ツールにしか効かない**。
allow 済みの `cat` / `echo` / `cp` / `mv` を通せば素通りになるので、ガードで止める。
**止まるのはファイル名がコマンドに現れる場合だけだ。** Bash 経由の経路を全部塞いだわけではない（下の「限界」）。

- 対象は語として現れる `.env` / `.env.*` / `.env-*`（大文字小文字を区別しない）
- `.env.example` だけは通す。キー名だけのテンプレートで、値を持たないため
- 語は `/` やクォート・リダイレクトなど名前に使えない文字で区切って判定する。
  `process.env` や `$NODE_ENV`、`.envrc` は止まらない
- 入力は**書き換えない**。区切るだけで、どの部分も走査から外さない（下記の教訓）

### 文章の中の言及でも止まる。これは仕様

`git commit -m "docs: rm -rf は禁止"` も `cat <<'EOF'` の本文に書いた `rm -rf` も止まる。
**誤爆に見えるが、直さない。** 一度「実行されえない部分を取り除いてから走査する」方式を
実装し、独立レビュー（G5）で2回連続 FAIL した。経緯は Issue #9 と `lessons.md`。

取り除きは**シェルのパーサと同じ判断**を要求する。コメント・クォート・ヒアドキュメント・
パス修飾・エスケープが絡む文法を正規表現と手書きの状態機械で近似すると、
近似の誤差がそのまま**検知漏れ**になる。実際に、塞ぐたびに別経路が開いた:

| 塞いだ穴 | 次に開いた穴 |
| --- | --- |
| `sh -c "rm -rf /"` を検査する | `/bin/sh -c` がパス修飾で語境界をすり抜ける |
| 区切り文字の貪欲マッチを止める | `echo "<<EOF"` の偽ヒアドキュメントで後続行が消える |
| 消費側を語で判定する | コメント内の `don't` がクォートを開いて後続行が消える |
| 処理時間の二乗オーダーを消す | `<<` を含む行数に比例して 22KB / 41秒 → タイムアウトで素通り |

**検知漏れは誤爆より遥かに高コストだ。** 誤爆は書き方を変えれば済むが、
検知漏れは気付いた時には消えている。

### 回避策：文章はシェルに渡さない

ドキュメント・コミットメッセージ・PR 本文に危険コマンドを書く必要があるなら、
ヒアドキュメントではなく **Write / Edit ツールでファイルに書き、`--file` 系の
オプションで渡す**。

```bash
# NG: 本文がコマンド文字列に載るのでガードに掛かる
cat > docs/rules.md <<'EOF'
rm -rf は禁止
EOF

# OK: Write ツールでファイルを作る → シェルを経由しない
# OK: コミットメッセージもファイル経由で渡す
git commit -F .git/COMMIT_MSG
gh pr create --body-file /tmp/body.md
```

### 限界

- 検知は固定文字列。`rm\ -rf` や `r''m -rf` のような難読化は検出しない
- `.env` 系も同じ。`.en?` のようなグロブや `.e''nv` のような分割は検出しない
- `prod.env` のように末尾が `.env` の命名は対象外。先頭ドットの `.env*` だけを見る
- **ファイル名を書かない操作は検出しない。** `grep -rn API_KEY .` / `cp -r` / `tar` のような
  ディレクトリ走査や、`.env` を既定で読み込むツールは通る。名前で検知する方式の本質的な限界
- `.env.example` の例外は名前だけで判定する。シンボリックリンクとしてコミットされていても実体は確かめない
- 二段実行（ファイルに書いて次のターンで実行）は止められない
- このガードは**事故を防ぐ速度制限**であり、悪意ある操作に対する境界ではない。
  エージェントがガードを迂回しようとする前提では設計していない

**緩める変更を入れるときは、「ブロックされるべきケース」のテストを先に固めてから触ること。**

---

## 監視の限界（送信側）

`.claude/hooks/monitor-emit.sh` は全セッションで自動実行され、フックの stdin から allowlist 抽出した JSON だけを
`http://127.0.0.1:<port>/api/events` へ送る。仕様は `.claude/monitor/docs/event-schema.md` が唯一の正。
ここは**止まる範囲**と**止まらない範囲**の記録。

### 送る項目

- `event` / `session_id` / `tool_name` / `tool_use_id` / `agent_id` / `agent_type`（各々許可文字・最大バイト長を検証済みのもののみ）
- `bash_command`（Bash コマンドの先頭トークンのベース名（`/` を含むパスはベース名のみ）。`[A-Za-z0-9._-]` 以外を含めば `?`。32 バイトを超えれば切り詰めずに `?`）
- `file_path`（ベース名のみ。C0 / DEL / C1 / 双方向制御文字を除去し最大 128 バイト）
- `subagent_type` / `duration_ms` / `source` / `reason` / `trigger` / `stop_hook_active`（列挙・範囲検証済みのもののみ）
- `UsageSnapshot`（Stop / SubagentStop を受けた時にフックが合成する別イベント。`schema_version` 2）: `session_id` / `agent_id`（検証済み）、`usage_status` / `unknown_reason`（列挙）、
  モデル別の `model`（`[A-Za-z0-9._-]` の全体一致・最大 64 バイト。外れたら `unknown`）・件数・トークン数（非負整数。件数は 10^6 以下、トークン数は 10^12 以下）・真偽値のフラグだけ

### 送らない項目

- `tool_input` / `tool_response` / `prompt` の中身、`cwd` / `transcript_path`、コマンドの2語目以降・引数・環境変数代入
- 検証に落ちた値（省略する。必須キーが落ちたイベントは送らない）と、スキーマにないキー全て
- transcript の本文・プロンプト・パス・`message.id`・`thinking_tokens` 等（`UsageSnapshot` は集計した数値だけ。パスは `unknown` の理由にも載せない）

### 止める仕組み

- 抽出は jq の allowlist。ペイロードは stdin でだけ渡し、jq / curl の argv・一時ファイルには載せない
- 宛先は `127.0.0.1` 固定で、ホスト系の環境変数では変えられない。`--noproxy '*'` でプロキシ変数も無視する
- `LOOP_MONITOR=0` で送信しない。`LOOP_MONITOR_PORT` は 1〜65535 の10進以外なら 4319 に倒す
- 送信は背景化し、curl の fd1 / fd2 を `/dev/null` へ切り離す。`--max-time` で有限時間で終わる
- jq・curl の設定ファイル（`.curlrc` / `.jq`）を読ませない（curl は `-q`、jq は HOME を差し替えて起動）
- 常に stdout 0 バイト・stderr 空・exit 0
- **transcript を読む経路（`UsageSnapshot`）**: 読むのは Stop の `transcript_path` / SubagentStop の `agent_transcript_path` だけ（もう片方は読まない）。
  パスは外部由来なので、絶対パス・制御文字なし・4096 バイト以下の文字列だけを受け付け、それ以外は読まずに `no_path`。
  パスは perl の `sysopen` で **1 回だけ**開く（`O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_NOCTTY`）。名前で `-L` / `-e` / `-f` を判定してから開き直すことはしない（判定と読み取りの間の差し替え競合を作らない）。
  最終要素が symlink（ダングリング含む）なら open が ELOOP で失敗して `symlink`、不在・権限なしなどその他の失敗は `read_failed`。
  種別は**開いた fd 上**（`stat`）で判定し、通常ファイル以外（FIFO・ディレクトリ・デバイス）は 1 バイトも読まずに `not_regular_file`。`O_NONBLOCK` で FIFO の open も待たない。
  ただし**開くことはする**（名前で先に判定しないため）。デバイスは open だけが起き、読まずに閉じる。open 自体に副作用があるデバイスでは、その副作用は止まらない（`O_NOCTTY` で端末を制御端末にすることは無い）
- **サイズ上限は 16 MiB（16777216 バイト）**: サイズは開いた fd 上の `stat` で確認し、超えれば読まずに `too_large`。さらに `sysread` を上限 + 1 バイトで打ち切り、超過分が読めたら `too_large`。
  `LOOP_MONITOR_MAX_TRANSCRIPT_BYTES` は上限を**下げる向きにだけ**効く（10 進の正の整数のみ。不正値は無視して既定値）。
  実測（M3 / macOS 26 / jq 1.8.1）: 単独の背景処理は 20MB で 1.6 秒・50MB で 5.2 秒。10 本同時だと 16MB で 4.2 秒・20MB で 5.2 秒（ピークの jq 合計約 120MB / 145MB）。
  いずれも実セッション相当の transcript（読み取りを perl 方式に変える前の版で計測）での値。5 秒以内に収まる単独の最大が約 48MB なので、約 1/3 の 16 MiB にした（同時実行を見込んだ余裕。実セッションのメイン transcript は約 6MB）
- パス・transcript の本文は jq / curl / perl の argv に載せない（パスは環境変数 `TPATH` で perl に渡し、本文は perl の stdout から jq の stdin へ直接流す）。perl の設定・探索パスを変える `PERL5LIB` / `PERL5OPT` / `PERLLIB` / `PERL5DB` と、入出力層を変える `PERL_UNICODE` / `PERLIO` は外して起動し、さらに開いた fd を `binmode` にして `:utf8` 層を外す（二重化）。読み取りが途中で失敗したら理由だけを返し、部分的な本文は渡さない。perl または Fcntl が無い環境では読まずに `read_failed`。一時ファイルを作らない。集計は jq の静的プログラムで行い、
  送信ボディに載るのは数値・真偽値・列挙値・許可文字を満たしたモデル ID だけ
- 前景（フック本体）は transcript に触れない。判定・読み取り・集計・送信は元のイベントとは**別の背景グループ**で行う（片方の失敗・遅延が他方に波及しない）。前景は 50MB の transcript でも 0.05 秒（10 本同時でも 0.4 秒以下）

### 既知の限界

- **Bash コマンドの先頭トークン自体が秘密で、許可文字（`[A-Za-z0-9._-]`）のみで、ベース名化後 32 バイト以内なら、そのまま `bash_command` として送られる。**
  先頭トークン方式から必然的に通る経路で、値の意味解析はしない。`FOO=xxx cmd` や `export K=xxx` の値は `?` / `export` に落ちて止まる。
  テスト `known_limit_first_token_secret` がこの挙動を固定している
- 先頭トークンが 32 バイトを超える場合は `?` になり、切り詰めた先頭部分も送られない
- PATH 上の `jq` / `curl` / `perl` 自体のすり替えは止めない（既存フックと同じ。設定ファイルを読ませない対策の範囲外）
- 止まるのは「送信ボディに載る値」だけ。ローカルの監視サーバ側での保存・表示・転送は範囲外
- 送信は背景化しているため、ネットワーク失敗・タイムアウト・セッション終了間際のイベントは黙って捨てられる（fail open）
- `127.0.0.1` 固定は別ホストへの送信を止めるが、同一マシン上でそのポートを先に握った別プロセスには届く
- worktree で実行しても `LOOP_MONITOR_PORT` が同じなら同じ監視サーバへ送る。worktree の区別はしない（限界として明記）
- **`UsageSnapshot` はローカルファイルを読む新しい経路**（`.gitignore` も権限設定も届かない外部由来のパス）。止まるのは symlink（最終要素）・通常ファイル以外・上限超過・不正なパスだけ。止まらないもの:
  - **親ディレクトリがリンクの場合は辿る。** 最終要素だけを見る（OS 標準の `/var` → `/private/var` 等を拒否しないため）。テスト `親ディレクトリが symlink でも拒否しない` が固定している
  - **名前の差し替え競合は、最終要素については止まる。** 開くのは 1 回だけで、種別・サイズは開いた fd に対して判定するので、判定後に名前が別のものへ差し替わっても読むのは開いた実体だけ（FIFO で永久に待たない・`/dev/zero` への symlink を辿らない。テスト `[US5]` が固定）
  - **親ディレクトリの差し替えは止まらない。** `O_NOFOLLOW` は最終要素にしか効かない。祖先ディレクトリがリンクなら辿り、パス解決の途中で差し替えられた先の通常ファイルは開く。読む量は上限 + 1 バイトで守る
  - **perl が無い環境では読めない。** `read_failed`（使用量不明）になる。perl が無いことを理由に名前での読み取りへ戻ることはしない
  - **同じユーザーが書ける任意の通常ファイルを `transcript_path` に仕込めば読まれる。** ただし送られるのは数値・真偽値・列挙値・許可文字のモデル ID だけで、行の本文・パスは出ない
  - NUL バイトを含むファイル: 本文はコマンド置換を通らず perl から jq へ直接流れるので、NUL は落ちず、長さの検査も甘くならない（上限はバイト数で厳密）。NUL を含む行は JSON として読めず `parse_failed` になる（実測）
- **セッション終了間際の集計は黙って捨てられることがある。** 集計・送信は背景処理なので、セッションの終了やネットワーク失敗で消える（fail open）。最後のターンの `UsageSnapshot` が欠け、直前のものが表示される。自前の再送や完了待ちはしない
- **並走する jq の数に上限が無い。** 同時に完了したサブエージェントの数だけ背景の jq が走る。10 本同時で 20MB の transcript を読むと約 5 秒・jq 合計約 145MB（実測）。それ以上は測っていない。流量制限や多重起動の抑止は入れていない
- **背景の集計時間は上限以下のサイズでも有界ではない。** 上記の実測は実セッション相当の transcript での値。`message.id` がすべて異なる行で 16MB を埋めた病的な transcript では、jq の集計が単独で約 128 秒かかった（#23 retry 2 の実測。読み取り方式を変える前の版でも約 53 秒）。読む量は上限 + 1 バイトで守るが、集計の時間に打ち切りは無い。前景は transcript に触れないのでフックの応答には影響しない
- サイズ上限（16 MiB）を超える transcript は `too_large` になり、使用量が不明（`unknown`）として表示される。長いセッションでは起こりうる。上限を上げる手段は無い（環境変数は下げる向きだけ）。値を変えるには `monitor-emit.sh` の `MAX_TRANSCRIPT_BYTES` を再測定の上で書き換える

## 監視の限界（受信側）

`.claude/monitor/server/server.mjs` は `POST /api/events` で送信側のイベントを受け、SQLite に保存し、`/api/state` と
`/api/stream`（SSE）で返す。入力仕様は `.claude/monitor/docs/event-schema.md` が唯一の正。
倒す向きは**送信側と逆**。フックは fail open（捨てて黙る）、サーバは **fail closed**（判定不能・仕様外は拒否する）。
ここは**止まる範囲**と**止まらない範囲**の記録。

### 受け付ける入力

- `Content-Type: application/json` の POST のみ。ボディは 64KB（65536 バイト）まで
- `event` は10種の列挙。キーは「共通 + そのイベントの必須 + 任意」だけ。識別子は許可文字の全体一致と最大バイト長（文字数ではない）
- `bash_command` は `tool_name` が Bash の時だけ、`subagent_type` は Agent の時だけ。数値は値が整数で範囲内のもののみ
- 受理したら `received_at`（サーバの時計）と `seq`（連番）を付けて保存する。順序は `seq` だけで決まり、送信側の値は使わない

### 止める仕組み

- **fail closed**: 未知のキー・型違い・範囲外・列挙外・複数行は全て 400。切り詰めも値の補正もしない。拒否理由は固定文言で入力値を載せない
- **Host**: `127.0.0.1:<実ポート>` と `localhost:<実ポート>` の完全一致のみ。欠落・空・ポート違い・大文字は 403（DNS リバインディング対策）
- **Origin**: ヘッダがあれば `http://` + Host の値と完全一致のみ。`null`・空・別オリジンは 403。Host → Origin の検査はルート判定より先
- **Sec-Fetch-Site**: ヘッダがあり、値が `same-origin` / `none` の完全一致でなければ全メソッド・全パスで 403（`same-site`・空・複数値・重複ヘッダも拒否）。Origin を付けない no-cors の `<img>` GET（SSE 枠の占有・`/api/state` の連打）を止める。403 は SSE の枠を消費しない
- **`/api/state` のキャッシュ**: 導出は最大 seq が進んだ時だけやり直す（確認は `MAX(seq)` の1行問い合わせ）。連打しても全行の導出を繰り返さない
- **シンボリックリンクの拒否（`lstat`）**: DB 本体・`-wal`・`-shm`・`-journal`・データディレクトリ・その直接の親が、リンク（ダングリング含む）なら起動を拒否する。`realpath` が親の実体 + 名前に一致しない場合も拒否。mkdir / open より前に検査し、拒否時は listen 前に落ちる（CLI は非0終了・stderr は固定文言のみ）。`MONITOR_DB` の明示指定にも同じ検査をかける
- **パーミッション**: データディレクトリは作成時 `0700`（再帰作成した親も `chmod` で確定）、DB ファイルは `0600`（`-wal` / `-shm` / `-journal` は DB の権限を引き継ぐ）。DB の新規作成は `O_EXCL`
- **Content-Type**: `application/json` 以外は 415（フォーム・`text/plain` のブラウザ送信を通さない）
- **64KB**: 超過は 413。`Content-Length` の宣言だけで拒否し、chunked は上限到達で読み取りを打ち切って接続を閉じる
- **Access-Control-Allow-Origin** を含む `Access-Control-*` は一切付けない。OPTIONS は 405 で、プリフライトに応えない
- **127.0.0.1** 固定で listen する。変えられるのは `MONITOR_BIND` だけ（`HOST` 等は見ない）。`0.0.0.0` 等にした場合の保護は Host / Origin 検査のみ
- SQL は全て**プレースホルダ**付きのプリペアドステートメント。値を SQL 文字列へ連結しない（`static.test.mjs` が検査）
- SSE は同時 16 接続まで。超過は 503。切断で枠を解放する
- **静的配信（ビュー）は固定 3 パスのみ**: `GET /` / `GET /app.js` / `GET /style.css` だけを `public/` の固定 3 ファイルから返す。起動時に読み、URL からファイルパスを組み立てない（デコード・正規化・join をしない）。それ以外のパス（`/index.html`・`/../`・`%2e%2e`・大文字違い・末尾スラッシュ等）は 404、3 パスへの GET 以外（HEAD 含む）は 405。`public/` が読めなければ起動に失敗する
- **静的 GET にも Host → Origin → Sec-Fetch-Site の検査が掛かる**: ルート判定より前なので、`cross-site` の `<img>` 風 GET で `/` を取れない（403）。Host 欠落の HTTP/1.1 要求は Node の 400 に任せず（`requireHostHeader: false`）自前の検査で 403 にする
- **セキュリティヘッダを全応答に付ける**: `Content-Security-Policy: default-src 'self'` / `X-Content-Type-Options: nosniff` / `X-Frame-Options: DENY` を、ハンドラに届いた JSON・エラー（400〜503）・静的・SSE（200 / 503）の全応答に同じ定数 1 つから付ける（重複送信しない）。`Access-Control-*` は付けない
- **ビューのソース検査**: `public/*.js` に `innerHTML` 等の DOM シンクが無いこと、`index.html` にインライン script・`on*=`・`style=`・外部 URL が無いことを `view-source.test.mjs` が検査する。描画は `createElement` + `textContent` のみで、外部由来の値は class 名・属性に入れない
- エラー本文は固定文言。5xx に例外・スタック・パス・SQL・入力値を載せない。**ログ**にイベント本文・ヘッダ値・DB パスを出さない
- 保存は 7 日・100000 行まで。起動時・1時間ごと・1000件追記ごとに古い行を削除する

### 既知の限界

- **認証が無い。** 同一端末の任意のプロセスは、Host / Origin / Content-Type を自分で正しく付ければ**書き込み**（偽のイベントの注入）も
  **読み出し**（`/api/state` と SSE）もできる。止まるのはブラウザ経由の攻撃（クロスオリジン・DNS リバインディング）だけ。
  監視は**セキュリティ境界ではない**。テスト `known_limit_local_process_can_write`（`server-security.test.mjs`）がこの挙動を固定している
- `MONITOR_BIND` を `127.0.0.1` 以外にすると、別ホストから Host を正しく付けて到達できる。Host 検査はポート込みの固定値なので別名では通らないが、認証が無い限界は同じ
- 検証を通る値は保存・表示される。`file_path` のベース名や `bash_command` の先頭トークンが秘密でも、許可文字・長さに収まれば保存される（送信側の限界と同じ。値の意味解析はしない）
- 同一端末上でそのポートを先に握った別プロセスがあれば、`listen` は失敗する（起動時に落ちる）。落ちる前に握られたポートへのイベントは届かない
- 検査（`lstat` / `realpath`）と作成（mkdir / open）の間は原子的でない。同じ権限の別プロセスがその隙間でリンクへ差し替えれば辿る。止まるのは「検査の前から置いてあった**シンボリック**リンク」（コミットされたリンク・事前に仕込まれたリンク）だけ。DB の新規作成を `O_EXCL` にして既存リンクの上に作らないことで狭めているが、競合は消せない。権限の確定（`chmod`）もパス指定でリンクを辿るため、この隙間で差し替えられればリンク先の権限が変わる。既存の DB・ディレクトリの権限は `0600` に直すのみで、祖先ディレクトリのリンクは直接の親までしか見ない
- **ハードリンクは検査しない。** 事前に DB の位置へ別ファイルのハードリンクを置かれると、そのファイルに書き込み、権限を `0600` に変える。git はハードリンクを保存しないので clone では持ち込まれず、置けるのはそのファイルを既に書ける同一ユーザーのプロセスだけ
- `Sec-Fetch-Site` を送らない古いブラウザ・非ブラウザのクライアントは止めない（ヘッダ無しは通す仕様）。同一端末のプロセスが自分でヘッダを付けない限り、この検査はブラウザ経由の攻撃にしか効かない
- 削除は時間と件数で行う。DB のパーミッションは `0600`・ディレクトリは `0700` に確定するが、同一ユーザーのプロセスと root は読める
- 受信は同期の SQLite 書き込み。大量送信への流量制限は無い（64KB・SSE 16 の上限のみ）
- **CSP は `default-src 'self'` のみ。** 同一オリジンのスクリプトは止めない。認証が無いので、監視サーバ自身が返す `app.js` は誰でも取得でき、同一端末のプロセスは Host / Origin を正しく付ければ静的ファイルも `/api/state` も読める（監視はセキュリティ境界ではない）。`frame-ancestors`・`form-action`・`base-uri` 等は指定していない（`X-Frame-Options: DENY` が埋め込みを止めるのみ）
- ビューの CSP / ヘッダの実効（ブラウザが実際にスクリプトを拒否するか）はテストでは確かめていない。テストが固定しているのはヘッダの値と、全応答に 1 回ずつ付くこと
- 静的ファイルは起動時に読み込んだ内容を返す。`public/` を書き換えても、サーバを再起動するまで反映されない
- **Node の HTTP パーサがハンドラより前に返す応答にはセキュリティヘッダが付かない（実測）**: 不正なリクエスト行（`%2F` を含むパス・小文字や不正なメソッド）は本文の無い素の 400 になり、巨大なヘッダは接続リセットになる。ブラウザはこの形を送れず本文も空なので、止まる範囲は「ハンドラに届いた応答」まで
- **Host ヘッダの重複は先頭だけを見る（実測）**: Node が 2 本目以降の Host を捨てるため、先頭が正しい Host なら後続に別の値があっても通る（逆順なら 403）。ブラウザは Host を重複させて送れないので DNS リバインディングには使えず、生ソケットを扱える同一端末のプロセスは元々正しい Host で到達できる（認証が無い限界の範囲内）

### ループ状態の読み取り（ビューのパネル）

サーバは `loop-state.json` を読み、`/api/state` の `loop` に載せる（`.claude/monitor/server/loop-state.mjs`）。
ホストのファイルを UI へ出す入力経路なので、**読めない状態を正常に見せない**ことを優先する。

- **読む先は固定**: `MONITOR_LOOP_STATE`（イメージ既定は `/memory/loop-state.json`、コンテナ外の既定はリポジトリの `.claude/memory/loop-state.json`）。URL やイベントからは変えられない
- **リンクは辿らない**: 状態ファイル自体と直接の親ディレクトリを `lstat` で検査し、シンボリックリンク（リンク先が妥当な JSON でも・ダングリングでも）なら読まずに `unknown`（`symlink`）。開く時も `O_NOFOLLOW` で、開いた後に `fstat` で通常ファイルであることを確かめる
- **読めなければ `unknown` に倒す**: 不在・通常ファイル以外・64KB（65536 バイト）超・0 バイト・不正 JSON・必須フィールドの欠落や型違い・`status` の列挙外は、すべて `{status: "unknown", reason}` を返す。`running` / `completed` として返さない。`reason` は固定の列挙で、ファイルの中身を載せない
- **許可リストだけを返す**: `issue` / `branch` / `epic` / `status` / `retry` / `limits.*` / `gates.G1..G5.result` / `halt_reason` / `started_at`。`gates.*.reason`・`history`・`awake_start`・`boot_id` などは返さない。文字列は C0 / DEL / C1 / 双方向制御文字を除去してから長さを制限する（`halt_reason` 200 文字ほか）
- **ポーリング**: 2 秒ごとに読み直す（`fs.watch` は使わない。正しさを通知の到達性に依存させない）。変化した時だけ SSE に名前付きイベント `loop` を送る。データは空で、状態の値は SSE に載せない（ビューが `/api/state` を取り直す）
- ビューは `createElement` + `textContent` だけで描き、class は固定の許可リスト（`loop-running` / `loop-halted` / `loop-completed` / `loop-unknown`）からだけ付ける

#### 既知の限界

- **worktree の状態は見えない**: `/issue-flow` を worktree で回すと、状態は worktree 側の `.claude/memory` に書かれうる。サーバが読むのは `MONITOR_LOOP_STATE` の 1 ファイル（コンテナではメインのチェックアウトのマウント）だけなので、worktree 側のループは「不明」か別のループの状態として表示される。対象外とする（エピック承認時の決定）
- **経過時間は壁時計**: ハードストップの判定は起きていた時間で数える（#32）が、サーバ（コンテナ）はホストの起きていた時間を測れない。パネルは `started_at` からの壁時計の経過を「壁時計」と明示して出すので、スリープを挟むと判定より長く見える
- **読めた内容が正しいとは限らない**: 許可リストと型の検査を通れば表示する。同じユーザーのプロセスが `loop-state.json` を書き換えれば、その内容がそのまま表示される（監視はセキュリティ境界ではない）
- `lstat` と open の間は原子的でない。ファイル自体の差し替えは `O_NOFOLLOW` と `fstat` で止まった（実測: 約 48 万回でリンク先の値 0 回）が、**直接の親ディレクトリをその隙間でリンクへ差し替えると通る**（実測: 約 27 万回中 2 回、リンク先の値が表示された）。直接の親より上の祖先ディレクトリのリンクは検査しない（DB と同じ限界）。どちらも、差し替えられる同じユーザーのプロセスは元々 `loop-state.json` を直接書き換えられるので、得られる権限は無い
- **ハードリンクは検査しない**: 状態ファイルの位置に置かれた別ファイルのハードリンクは通常ファイルとして読み、許可リストに合う値だけを表示する
- **除去しない不可視文字がある**: 除去するのは C0 / DEL / C1 / 双方向制御文字（`event-schema.md` の範囲）だけ。ゼロ幅文字（U+200B〜U+200D）・U+2028 / U+2029・U+00AD・U+FEFF・U+061C は `issue` や `halt_reason` に残り、改行に似た見た目で文字を並べられる。状態のバッジ（文言・class・記号）は `status` の列挙からだけ決まるので偽装できない。U+061C は Issue #35 で扱う
- 最大 2 秒（ポーリング周期）＋ビューの再取得の間引き（1 秒）だけ表示が遅れる

### コンテナ側

`.claude/monitor/Dockerfile` と `.claude/monitor/compose.monitor.yml`（原本）でサーバをコンテナで動かす場合の記録。
止まる範囲だけを書く。

- **公開範囲の設定は2箇所**: compose の `ports`（`127.0.0.1:` bind）とコンテナ内の `MONITOR_BIND=0.0.0.0`。
  `127.0.0.1` bind が絞るのはホストのネットワーク側だけ。この2つでローカル限定を担保したとは言えない（次の項）
- **同じ Docker ネットワークのコンテナは到達できる（実測）**: 同じ Docker ネットワークに入ったコンテナは、
  Host を偽って `127.0.0.1:<port>` にすれば、監視サーバを読み書きできる。Host / Origin 検査は認証ではない
  （止まるのはブラウザ経由の攻撃だけ）
- **compose は monitor を専用ネットワークに置く**: `networks: [monitor-net]` で導入先のアプリと同居させない。
  ただし `docker network connect` で他のコンテナを繋げば同居する。専用ネットワークは同居を避ける配置であって遮断ではない。
  `internal: true` は published ports をホストから届かなくする（実測）ので使わない
- **`host.docker.internal` 経由では別ネットワークのコンテナも到達できる（Docker Desktop で実測）**: 専用ネットワーク `monitor-net` で止まるのは
  コンテナ間の直接通信だけ。別ネットワークのコンテナも `host.docker.internal:<port>` から Host を偽れば、Docker Desktop では到達できる（実測）。
  Host を偽らなければ 403（実測）。Linux の Docker Engine は未実測（`host.docker.internal` は既定では解決されず、
  `--add-host host.docker.internal:host-gateway` が要る）。受信に認証が無いこと自体はマスター決定（エピック承認時）で、
  根本対策の共有トークン認証は**見送りを決定済み**（2026-10-10。理由と再検討の条件は `.claude/memory/epics/ai-monitor.md`「マスターの決定」）
- Linux の Docker Engine 28.0 より前では、127.0.0.1 に publish したポートへ同じ L2 セグメントのホストから届く既知の経路がある
  （エンジンのバージョンに依存する。手元では再現していない）
- コンテナから読めるもの: `/memory`（`.claude/memory` の `:ro` マウント）に journal のポインタ・lessons・epics・loop-state が含まれる
  （現状サーバは読まない）
- `docker run` で起動する場合（実測）: `MONITOR_DB` はイメージ既定で `/data/monitor.db`（node 所有）なので指定なしで起動する。
  `MONITOR_BIND` を渡さない素の `docker run -p` も起動して healthy になるが、コンテナ内は `127.0.0.1` で listen するため、
  ホストからは到達できない。到達させるには `MONITOR_BIND=0.0.0.0` と `-p 127.0.0.1:` の両方を付ける:

```sh
docker run -d -e MONITOR_BIND=0.0.0.0 -e LOOP_MONITOR_PORT=<port> \
  -p 127.0.0.1:<port>:<port> <image>
```

- `-p` から `127.0.0.1:` を外すと、Docker の仕様どおり全インターフェースに公開される（この形は実際には試していない）。
  止まるのは `-p` の `127.0.0.1:` bind を付けた場合だけ
- Host 検査がポート込みなので、`docker run` では内外のポートをそろえる（`-p 4319:4319` の形）。ずれると 403（実測: 外 47321 → 内 4319 で 403）
- 認証は無い（受信側の限界と同じ）。同一端末の任意のプロセスは到達できる
- 非 root（`USER node`）・`read_only: true`・`cap_drop: [ALL]`・`no-new-privileges:true`。止まるのはコンテナ内プロセスの
  権限昇格とルートファイルシステムへの書き込みまで。書き込めるのは DB 用の名前付きボリュームだけ
- `.claude/memory` は `:ro` の bind（ディレクトリ単位）。コンテナからは読むだけで書き換えられない
- ベースイメージは digest 固定。脆弱性修正の取り込みは**手動**（digest を取り直して更新する）。自動では追従しない
- `curl` / `wget` を**追加していない**。ヘルスチェックは `node` 自身が行う。ただし `/usr/bin/wget` は base の alpine に busybox へのリンクとして最初から存在する（`curl` は無い）。
  止まるのは追加分だけで、busybox の `wget` など base image 由来の fetch 手段は残る。削除はしていない

---

## `/review-pr` でのチェック項目

レビュー時に以下を必ず確認する:

- [ ] 外部入力に Zod バリデーションがあるか
- [ ] 生SQL使用時にパラメータバインドしているか
- [ ] `dangerouslySetInnerHTML` の使用箇所があれば DOMPurify を通しているか
- [ ] APIキーがコードに直書きされていないか
- [ ] `NEXT_PUBLIC_` 以外の環境変数がクライアントバンドルに含まれていないか
- [ ] `npm audit` で新たな脆弱性が発生していないか
