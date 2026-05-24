# API設計ルール

Next.js App Router の Route Handlers と Server Actions を対象とする。

---

## Server Actions（推奨）

フォーム送信・データ変更は Server Actions を使う。REST APIではなく Server Actions が第一選択。

```ts
// app/actions/article.ts
"use server";

import { z } from "zod";
import { revalidatePath } from "next/cache";

const SearchInputSchema = z.object({
  query: z.string().min(1).max(200),
  page: z.number().int().positive().default(1),
});

export async function searchArticles(input: unknown) {
  // 1. バリデーション（必須）
  const parsed = SearchInputSchema.safeParse(input);
  if (!parsed.success) {
    return { error: "Invalid input", details: parsed.error.flatten() };
  }

  // 2. 認証チェック（必要な場合）
  // const session = await getSession();
  // if (!session) return { error: "Unauthorized" };

  // 3. ビジネスロジック
  const results = await articleService.search(parsed.data);

  // 4. キャッシュ無効化（書き込み系のみ）
  revalidatePath("/articles");

  return { data: results };
}
```

---

## Route Handlers（外部向けAPI・Webhook）

外部サービスのWebhook受信、またはモバイルアプリ等の外部クライアントが必要な場合のみ使う。

```
app/
  api/
    articles/
      route.ts        # GET /api/articles
      [id]/
        route.ts      # GET /api/articles/:id
    webhooks/
      stripe/
        route.ts      # POST /api/webhooks/stripe
```

### レスポンス形式

成功・エラーともに統一したレスポンス形式を使う。

```ts
// 成功
return NextResponse.json(
  { data: result, error: null },
  { status: 200 }
);

// エラー
return NextResponse.json(
  { data: null, error: { message: "Not found", code: "NOT_FOUND" } },
  { status: 404 }
);
```

### HTTPメソッドとステータスコード

| 操作 | メソッド | 成功時ステータス |
|------|---------|----------------|
| 一覧取得 | GET | 200 |
| 詳細取得 | GET | 200 |
| 作成 | POST | 201 |
| 更新（全体） | PUT | 200 |
| 更新（部分） | PATCH | 200 |
| 削除 | DELETE | 204 |

---

## エンドポイント命名

- リソース名は複数形・名詞（動詞は使わない）
- パスはケバブケース

```
/api/articles              ✅
/api/article-categories    ✅
/api/user-preferences      ✅

/api/getArticles           ❌ 動詞を使っている
/api/article_categories    ❌ スネークケース
```

---

## バリデーション

全てのエンドポイントで入力バリデーションを行う。`security.md` のルールと合わせて遵守する。

```ts
// Route Handler でのバリデーション例
export async function GET(request: Request) {
  const { searchParams } = new URL(request.url);
  const QuerySchema = z.object({
    q: z.string().min(1),
    limit: z.coerce.number().int().positive().max(100).default(20),
  });

  const parsed = QuerySchema.safeParse({
    q: searchParams.get("q"),
    limit: searchParams.get("limit"),
  });

  if (!parsed.success) {
    return NextResponse.json(
      { data: null, error: { message: "Invalid query", code: "VALIDATION_ERROR" } },
      { status: 400 }
    );
  }
  // ...
}
```

---

## エラーハンドリング

- エラーは `error` フィールドで返す。例外を握りつぶさない
- エラーメッセージにスタックトレースやDBの詳細を含めない（情報漏洩防止）
- 本番では `error.message` に内部エラーを含めず、汎用メッセージを返す

```ts
try {
  const result = await someOperation();
  return NextResponse.json({ data: result, error: null });
} catch (error) {
  // ログにだけ詳細を出す
  console.error("[API Error]", error);
  // レスポンスは汎用メッセージ
  return NextResponse.json(
    { data: null, error: { message: "Internal server error", code: "INTERNAL_ERROR" } },
    { status: 500 }
  );
}
```

---

## `/review-pr` でのチェック項目

- [ ] Server Actions / Route Handlers で Zod バリデーションをしているか
- [ ] エラーレスポンスに内部情報（スタックトレース等）を含めていないか
- [ ] HTTPメソッドとステータスコードが規約に従っているか
- [ ] 認証が必要なエンドポイントに認証チェックがあるか
- [ ] エンドポイントのテスト（ユニット or E2E）が存在するか
