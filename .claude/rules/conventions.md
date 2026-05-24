# コーディング規約

## TypeScript

- `any` 使用禁止。`unknown` で受けて型ガードする
- `as` キャストは最終手段。使う場合はコメントで理由を明記する
- 型は `types/` に集約する。インライン型定義は小規模な場合のみ許可
- Zod スキーマと TypeScript 型を必ずペアで定義する

```ts
// OK
export const ArticleSchema = z.object({
  id: z.string().uuid(),
  title: z.string().min(1),
  status: z.enum(["draft", "published", "archived"]),
});
export type Article = z.infer<typeof ArticleSchema>;

// NG
const data: any = fetchData();
```

---

## 命名規則

| 対象 | 規則 | 例 |
|------|------|----|
| コンポーネント | PascalCase | `ArticleCard.tsx` |
| 関数・変数 | camelCase | `fetchArticle()` |
| 定数 | UPPER_SNAKE_CASE | `MAX_RETRY_COUNT` |
| 型・インターフェース | PascalCase | `ArticleItem` |
| Zodスキーマ | PascalCase + Schema suffix | `ArticleSchema` |
| ファイル（コンポーネント以外） | kebab-case | `article-service.ts` |
| テストファイル | `<対象>.test.ts(x)` | `ArticleCard.test.tsx` |

---

## ファイル・ディレクトリ構造

<!-- プロジェクト固有の features 名は各自書き換えること -->

```
app/
  (auth)/           # 認証が必要なルートグループ
  (public)/         # 認証不要なルートグループ
  api/              # Route Handlers
components/
  ui/               # 汎用UIコンポーネント（Button, Input, Card等）
  features/
    <feature-a>/    # 機能Aのコンポーネント
    <feature-b>/    # 機能Bのコンポーネント
hooks/              # カスタムフック（use*.ts）
lib/                # ユーティリティ・設定・定数
services/           # 外部API・DBアクセスロジック
types/              # 型定義・Zodスキーマ
tests/
  unit/             # Vitestユニットテスト
  e2e/              # Playwright E2Eテスト
```

---

## コンポーネント設計

- Server Component を原則とし、インタラクティブな部分のみ `"use client"` を付与する
- `props` の型は必ずインターフェースで定義する（インライン型は禁止）
- コンポーネントは単一責任。1コンポーネント = 1つの関心事
- `children` を多用しない。意図が明確な named props を優先する

```tsx
// OK
interface ArticleCardProps {
  article: Article;
  onSelect: (id: string) => void;
}
export function ArticleCard({ article, onSelect }: ArticleCardProps) { ... }

// NG
export function ArticleCard(props: any) { ... }
```

---

## 禁止事項

- `console.log` をプロダクションコードに残す（デバッグ後は必ず削除）
- `TODO` コメントをコミットに含める（ISSUEに起票してから削除する）
- `.env` 系ファイルをコミットする
- `any` の使用
- テストなしの機能実装（`/review-pr` で弾く）
- デフォルトエクスポート（`export default`）を components 以外で使う
