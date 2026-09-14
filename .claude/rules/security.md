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

`PreToolUse` フックが Bash の実行前にコマンドを走査し、破壊的な操作をブロックする。

**「クォートされていれば安全」ではない。** `psql -c "DROP TABLE x"` はシェルは実行しないが
データベースが実行する。危険の主体はシェルとは限らない。そのためパターンを2種類に分け、
それぞれ別の本文を走査する。

| 種別 | 例 | 走査する本文 |
| --- | --- | --- |
| **shell** | `rm -rf` / `git push --force` / `git reset --hard` / `chmod -R 777` / `mkfs` / `dd if=` / fork bomb | 実行されえない部分を取り除いた本文 |
| **args** | `DROP TABLE` / `DROP DATABASE` / `TRUNCATE` | クォートを残した本文。ただし DB クライアントが登場する場合のみ |

### 走査前に取り除くもの

**実行されえないことが構造的に保証された部分だけ**を取り除く。検知パターンは減らしていない。

- **終端したヒアドキュメントの本文**（消費側で扱いを変える）
  - `cat` / `tee` … 本文は実行されない → 常に取り除く
  - `sh` / `bash` / `zsh` / `ssh` … 本文はシェルとして実行される → **常に残す**
  - `python` / `node` / `psql` など … 別言語として実行される → shell 系の走査からは外し、args 系には残す
  - **終端していない本文は取り除かない。** 捨てた部分を隠し場所にさせないため
- **シングルクォート文字列** … 展開が一切起きない
- **`$` とバッククォートを含まないダブルクォート文字列** … 展開の余地が無い

### 既知の限界

- `python3 - <<PY` の本文が `os.system("rm -rf ...")` のようにシェルを呼ぶ場合、shell 系の走査からは外れる
- SQL は既知のクライアント名が登場する場合にのみ検査する。未知のクライアント経由は検出しない
- このガードは**事故を防ぐ速度制限**であり、悪意ある操作に対する境界ではない

回帰テストは `tests/scripts/pre-tool-guard.test.sh`。
**緩める変更を入れるときは、「ブロックされるべきケース」のテストを先に固めてから触ること。**
検知漏れは誤爆より遥かに高コストだ。

---

## `/review-pr` でのチェック項目

レビュー時に以下を必ず確認する:

- [ ] 外部入力に Zod バリデーションがあるか
- [ ] 生SQL使用時にパラメータバインドしているか
- [ ] `dangerouslySetInnerHTML` の使用箇所があれば DOMPurify を通しているか
- [ ] APIキーがコードに直書きされていないか
- [ ] `NEXT_PUBLIC_` 以外の環境変数がクライアントバンドルに含まれていないか
- [ ] `npm audit` で新たな脆弱性が発生していないか
