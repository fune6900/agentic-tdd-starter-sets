# performance audit

Web ページのパフォーマンスを計測し、改善案を出す。

## 手順

1. 対象 URL が未指定なら `http://localhost:3000` を既定にする。
2. Codex のブラウザ操作ツール、または利用可能な Lighthouse / Playwright / Chrome DevTools 相当の手段を確認する。
3. Performance、Accessibility、Best Practices、SEO 相当の観点で確認する。
4. LCP、CLS、FCP、TTFB など取得できる指標を集める。
5. コンソールエラー、重いリソース、遅いリクエストを確認する。
6. 改善案はコード変更レベルまで具体化する。

## Codex 注意点

- 取得できない指標は推測で埋めず、未取得と明示する。
- Chrome DevTools MCP 名は `.codex/mcp-map.md` の対応表に従って読み替える。
- Claude 版の詳細テンプレートが必要な場合は `.claude/commands/perf-audit.md` も参照する。
