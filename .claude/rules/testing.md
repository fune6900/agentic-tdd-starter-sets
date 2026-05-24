# テスト方針

## 基本原則

- **No Test, No Code**: テストのないコードはレビュー対象外。`/review-pr` で弾く
- **TDD 必須**: 実装より先にテストを書く。Red → Green → Refactor の順を崩さない
- **テストは仕様書**: テスト名を読めば何をするコードか分かるように書く
- **モックは最小限**: DBのモックは禁止。外部API・時刻・乱数のみモック許可

---

## TDD サイクル

### Red（失敗するテストを書く）
担当: **検閲のメイド（QA）**

1. 実装コードに触れる前にテストを書く
2. `npm test -- --run` でテストが失敗することを確認する
3. テストが失敗しない場合、テストが機能していない証拠。書き直す

### Green（最小限のコードで通す）
担当: **構築のメイド（Coder）**

1. テストをパスする最小限のコードを書く
2. 綺麗さは後回し。まず動かす
3. `npm test -- --run` が全件グリーンになるまで続ける

### Refactor（品質を上げる）
担当: **メイド長（Benz）** 監督

1. テストがグリーンのまま、重複排除・命名改善・構造整理を行う
2. リファクタリング後も `npm test -- --run` がグリーンであることを確認

---

## テスト種別

| 種別 | ツール | 対象 | コマンド | 担当エージェント |
|------|--------|------|---------|----------------|
| ユニットテスト | Vitest + RTL | 関数・hooks・コンポーネント | `npm test` | QA |
| E2Eテスト | Playwright | ユーザーフロー全体 | `npm run e2e` | QA |
| 視覚的テスト | `/visual-regression` | レイアウト・スタイル崩れ | `/visual-regression` | Designer |

---

## テストファイルの場所と命名

```
tests/
  unit/
    components/
      ArticleCard.test.tsx
      DashboardSummary.test.tsx
    hooks/
      useArticleSearch.test.ts
    services/
      article-service.test.ts
  e2e/
    articles.spec.ts
    auth.spec.ts
    dashboard.spec.ts
```

---

## テストの書き方

```ts
// ユニットテスト（Vitest + RTL）
describe("ArticleCard", () => {
  it("should display title and status", () => {
    const article = { id: "1", title: "Hello", status: "published" as const };
    render(<ArticleCard article={article} onSelect={vi.fn()} />);
    expect(screen.getByText("Hello")).toBeInTheDocument();
    expect(screen.getByText("published")).toBeInTheDocument();
  });

  it("should call onSelect with id when clicked", async () => {
    const onSelect = vi.fn();
    render(<ArticleCard article={{ id: "1", title: "Hello", status: "draft" }} onSelect={onSelect} />);
    await userEvent.click(screen.getByRole("button"));
    expect(onSelect).toHaveBeenCalledWith("1");
  });
});
```

```ts
// E2Eテスト（Playwright）
test("記事検索フロー", async ({ page }) => {
  await page.goto("/");
  await page.getByRole("searchbox").fill("hello world");
  await page.getByRole("button", { name: "検索" }).click();
  await expect(page.getByTestId("search-results")).toBeVisible();
});
```

---

## モック方針

```ts
// OK: 外部APIのモック
vi.mock("@/services/external-api", () => ({
  fetchExternalData: vi.fn().mockResolvedValue({ ok: true }),
}));

// OK: 時刻のモック
vi.setSystemTime(new Date("2026-01-01"));

// NG: DBのモック（実際のDBを使う）
vi.mock("@/lib/prisma", () => ({ prisma: { article: { findMany: vi.fn() } } }));
```

---

## CI でのテスト実行

GitHub Actions では以下の順で実行する（将来的な追加対象）:

```yaml
- run: npm test -- --run    # ユニットテスト
- run: npm run e2e          # E2Eテスト（devサーバー起動後）
```

---

## `/review-pr` でのチェック項目

- [ ] 新規機能に対応するユニットテストが存在するか
- [ ] バグ修正に対応する回帰テストが追加されているか
- [ ] テスト名が「何をすべきか」を表しているか
- [ ] DBモックを使っていないか
- [ ] `npm test -- --run` が全件グリーンか
