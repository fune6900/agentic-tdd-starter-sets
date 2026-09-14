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
- 二段実行（ファイルに書いて次のターンで実行）は止められない
- このガードは**事故を防ぐ速度制限**であり、悪意ある操作に対する境界ではない。
  エージェントがガードを迂回しようとする前提では設計していない

**緩める変更を入れるときは、「ブロックされるべきケース」のテストを先に固めてから触ること。**

---

## `/review-pr` でのチェック項目

レビュー時に以下を必ず確認する:

- [ ] 外部入力に Zod バリデーションがあるか
- [ ] 生SQL使用時にパラメータバインドしているか
- [ ] `dangerouslySetInnerHTML` の使用箇所があれば DOMPurify を通しているか
- [ ] APIキーがコードに直書きされていないか
- [ ] `NEXT_PUBLIC_` 以外の環境変数がクライアントバンドルに含まれていないか
- [ ] `npm audit` で新たな脆弱性が発生していないか
