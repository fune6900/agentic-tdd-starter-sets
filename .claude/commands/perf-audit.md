Chrome DevTools MCPを使用してWebページのパフォーマンス計測・改善提案を行う。以下の手順を厳守すること。

## 対象
- 引数 $ARGUMENTS に計測対象のURLが指定される。未指定の場合は `http://localhost:3000` を対象とする。

## 手順

1. 図案のメイド（Designer サブエージェント）を起動し、以下の計測を実行させる。

### Phase 1: Lighthouse監査
- `mcp__chrome-devtools__navigate_page` で対象URLへ遷移する。
- `mcp__chrome-devtools__lighthouse_audit` でLighthouse監査を実行する。
- Performance, Accessibility, Best Practices, SEO の各スコアを取得する。

### Phase 2: パフォーマンストレース
- `mcp__chrome-devtools__performance_start_trace` でトレースを開始する。
- `mcp__chrome-devtools__navigate_page` でページをリロードし、読み込みを計測する。
- `mcp__chrome-devtools__performance_stop_trace` でトレースを停止する。
- `mcp__chrome-devtools__performance_analyze_insight` でトレース結果を分析する。

### Phase 3: スクリーンショット取得
- `mcp__chrome-devtools__take_screenshot` で現在の画面をキャプチャする。
- レイアウト崩れや視覚的な問題がないか確認する。

### Phase 4: ネットワーク分析
- `mcp__chrome-devtools__list_network_requests` でネットワークリクエスト一覧を取得する。
- 大きなリソース、遅いリクエスト、不要なリクエストを特定する。

### Phase 5: コンソールエラー確認
- `mcp__chrome-devtools__list_console_messages` でコンソール出力を取得する。
- エラーや警告を抽出する。

2. 計測結果を以下の形式で報告する:

```
## パフォーマンス計測結果: <対象URL>

### Lighthouse スコア
| カテゴリ | スコア | 判定 |
|---------|--------|------|
| Performance | XX | OK / 要改善 |
| Accessibility | XX | OK / 要改善 |
| Best Practices | XX | OK / 要改善 |
| SEO | XX | OK / 要改善 |

### パフォーマンス指標
- **LCP (Largest Contentful Paint)**: XXs
- **FID (First Input Delay)**: XXms
- **CLS (Cumulative Layout Shift)**: XX
- **TTFB (Time to First Byte)**: XXms
- **FCP (First Contentful Paint)**: XXs

### 検出された問題
- [重要度: 高/中/低] 問題の説明

### ネットワーク概要
- リクエスト数: XX
- 総転送サイズ: XX KB
- 重いリソース上位3件

### コンソールエラー
- （あれば記載）

### 改善提案
1. [優先度: 高] 具体的な改善内容 — 期待される効果
2. [優先度: 中] 具体的な改善内容 — 期待される効果
3. [優先度: 低] 具体的な改善内容 — 期待される効果

### 改善の実装案
（コード変更が必要な場合、対象ファイルと修正方針を記載）
```

## 注意
- 開発サーバーが起動していない場合は、先に `npm run dev` の実行をマスターに促すこと。
- モバイル・デスクトップ両方の計測が求められた場合は `mcp__chrome-devtools__emulate` でデバイスを切り替えて2回計測する。
- 改善提案は具体的なコード変更レベルまで落とし込むこと。「画像を最適化しましょう」のような曖昧な提案は不可。
- 計測値が良好（Performance 90以上）な場合でも、改善余地があれば報告する。
