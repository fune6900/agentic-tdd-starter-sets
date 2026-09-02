# issue flow（インナーループ）

1つの Issue を「実装 → 検証 → 差し戻し」で合格まで持っていく。人間は途中で介在しない。

詳細な定義は `.claude/rules/loop-engineering.md` と `.claude/commands/issue-flow.md` を参照する。

## 前提

Issue に以下が揃っていること。欠けている場合は実装に入らず、分解のやり直しを提案する。

- 目的 / 意図 / 受け入れ条件（機械判定可能）/ 影響範囲 / セキュリティ確認の要否

## 手順

1. `.claude/memory/lessons.md` を読み、この Issue に関係する教訓を抽出する（必須）。
2. 作業ブランチを用意する。分離が必要なら `bash .claude/scripts/worktree.sh create <branch>`。
3. ループ状態を初期化する（ハードストップの前提）:
   ```bash
   bash .claude/scripts/loop-state.sh init <issue番号> <branch>
   ```
4. 実装フェーズを順に進める。各フェーズには受け入れ条件と抽出した教訓を必ず添える。
   - QA: 失敗するテストを書き、失敗を確認する
   - Architect: 型・Zod スキーマ・DB スキーマを定義する
   - Coder: テストを通す最小限の実装を書く
   - Designer: UI 変更がある場合のみ
5. ゲートを順に通す。前のゲートが FAIL なら後続は実行しない。
   | 順 | ゲート | 内容 | 起動条件 |
   | --- | --- | --- | --- |
   | G1 | 機械 | `npm test -- --run` / `typecheck` / `lint` / `build` | 常時 |
   | G2 | 実証 | 受け入れ条件を実画面・実挙動で確認 | 常時 |
   | G3 | 仕様 | 目的・意図の充足、影響範囲の逸脱 | 常時 |
   | G4 | コード | 可読性・重複・命名・規約 | 常時 |
   | G5 | セキュリティ | `security.md` の全項目 | Issue に「必須」がある場合のみ |

   結果は都度記録する:
   ```bash
   bash .claude/scripts/loop-state.sh gate G1 pass
   bash .claude/scripts/loop-state.sh gate G2 fail "受け入れ条件 #2 が未達"
   ```
6. FAIL の場合は差し戻し先を特定し、リトライを記録して G1 からやり直す:
   ```bash
   bash .claude/scripts/loop-state.sh retry "<今回何を変えるか>"
   ```
7. `loop-state.sh check` が exit 1 を返したら**ハードストップ**。コミットも PR 作成もせず、
   リトライ経緯・落ちたゲート・推定原因・選択肢をユーザーに報告して指示を仰ぐ。
8. 全ゲート PASS で `smart commit` → PR 作成 → `bash .claude/scripts/loop-state.sh complete`。
9. 差し戻しが1回でもあった場合は `loop retro` で教訓を記録する（必須）。

## Codex 注意点

- ブラウザツールが使えない場合、G2 は CLI 実行・API 呼び出しで代替し、**未実施の視覚確認を明記する**。
  「UI が無いので確認不能」で終わらせない。
- サブエージェントを別プロセスとして持てない場合は、各ゲートを**独立した検証パスとして順に実行**する。
  役割を混ぜず、1パス1観点を守る。
- ゲートを通すためのテスト削除・`.skip` 化・`--no-verify` は禁止。発覚時点でハードストップ扱い。
- `loop-state.sh init` を飛ばすとハードストップが働かない。必ず実行する。
