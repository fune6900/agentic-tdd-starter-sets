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

### 送らない項目

- `tool_input` / `tool_response` / `prompt` の中身、`cwd` / `transcript_path`、コマンドの2語目以降・引数・環境変数代入
- 検証に落ちた値（省略する。必須キーが落ちたイベントは送らない）と、スキーマにないキー全て

### 止める仕組み

- 抽出は jq の allowlist。ペイロードは stdin でだけ渡し、jq / curl の argv・一時ファイルには載せない
- 宛先は `127.0.0.1` 固定で、ホスト系の環境変数では変えられない。`--noproxy '*'` でプロキシ変数も無視する
- `LOOP_MONITOR=0` で送信しない。`LOOP_MONITOR_PORT` は 1〜65535 の10進以外なら 4319 に倒す
- 送信は背景化し、curl の fd1 / fd2 を `/dev/null` へ切り離す。`--max-time` で有限時間で終わる
- jq・curl の設定ファイル（`.curlrc` / `.jq`）を読ませない（curl は `-q`、jq は HOME を差し替えて起動）
- 常に stdout 0 バイト・stderr 空・exit 0

### 既知の限界

- **Bash コマンドの先頭トークン自体が秘密で、許可文字（`[A-Za-z0-9._-]`）のみで、ベース名化後 32 バイト以内なら、そのまま `bash_command` として送られる。**
  先頭トークン方式から必然的に通る経路で、値の意味解析はしない。`FOO=xxx cmd` や `export K=xxx` の値は `?` / `export` に落ちて止まる。
  テスト `known_limit_first_token_secret` がこの挙動を固定している
- 先頭トークンが 32 バイトを超える場合は `?` になり、切り詰めた先頭部分も送られない
- PATH 上の `jq` / `curl` 自体のすり替えは止めない（既存フックと同じ。設定ファイルを読ませない対策の範囲外）
- 止まるのは「送信ボディに載る値」だけ。ローカルの監視サーバ側での保存・表示・転送は範囲外
- 送信は背景化しているため、ネットワーク失敗・タイムアウト・セッション終了間際のイベントは黙って捨てられる（fail open）
- `127.0.0.1` 固定は別ホストへの送信を止めるが、同一マシン上でそのポートを先に握った別プロセスには届く
- worktree で実行しても `LOOP_MONITOR_PORT` が同じなら同じ監視サーバへ送る。worktree の区別はしない（限界として明記）

---

## `/review-pr` でのチェック項目

レビュー時に以下を必ず確認する:

- [ ] 外部入力に Zod バリデーションがあるか
- [ ] 生SQL使用時にパラメータバインドしているか
- [ ] `dangerouslySetInnerHTML` の使用箇所があれば DOMPurify を通しているか
- [ ] APIキーがコードに直書きされていないか
- [ ] `NEXT_PUBLIC_` 以外の環境変数がクライアントバンドルに含まれていないか
- [ ] `npm audit` で新たな脆弱性が発生していないか
