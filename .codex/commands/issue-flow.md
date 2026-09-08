# issue flow（インナーループ）

1つの Issue を「実装 → 検証 → 差し戻し」で合格まで持っていく。人間は途中で介在しない。

詳細な定義は `.claude/rules/loop-engineering.md` と `.claude/commands/issue-flow.md` を参照する。

## 前提

Issue に以下が揃っていること。欠けている場合は実装に入らず、分解のやり直しを提案する。

- 目的 / 意図 / 受け入れ条件（機械判定可能）/ 影響範囲 / セキュリティ確認の要否

## 手順

0. **前回までの記録を読む（★最初の行動・必須）**:
   ```bash
   bash .claude/scripts/loop-journal.sh context
   ```
   進行中のエピックがあれば内部ジャーナル、無ければ外部 Vault の直近エピックが出力される。
   別端末・別セッションの続きかもしれない。読まずに着手しない。
1. `.claude/memory/lessons.md` を読み、この Issue に関係する教訓を抽出する（必須）。
   経緯（ジャーナル）と教訓（lessons）は別物。両方読む。
2. 作業ブランチを用意する。分離が必要なら `bash .claude/scripts/worktree.sh create <branch>`。
3. ループ状態を初期化する（ハードストップの前提）:
   ```bash
   bash .claude/scripts/loop-state.sh init <issue番号> <branch> <epic-slug>
   ```
   エピック外の単独 Issue なら `loop-journal.sh start issue-<番号>` でジャーナルを開く。
   着手を記録する（節目1/4）:
   ```bash
   bash .claude/scripts/loop-journal.sh inner <issue番号> start "<一行ゴール>" <<'ENTRY'
   - **やったこと**: 着手
   - **なぜ**: <この Issue を今やる理由>
   - **方針**: <実装方針と、それを選んだ理由>
   ENTRY
   ```
4. 実装フェーズを順に進める。各フェーズには受け入れ条件と抽出した教訓を必ず添える。
   - QA: 失敗するテストを書き、失敗を確認する
   - Architect: 型・Zod スキーマ・DB スキーマを定義する
   - Coder: テストを通す最小限の実装を書く
   - Designer: UI 変更がある場合のみ

   実装完了を記録する（節目2/4）。**「なぜその設計にしたか」を必ず書く**:
   ```bash
   bash .claude/scripts/loop-journal.sh inner <issue番号> impl <<'ENTRY'
   - **やったこと**: <変更したファイルと責務>
   - **なぜ**: <設計判断の理由>
   - **捨てた選択肢**: <却下した案と理由>
   ENTRY
   ```
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
   ゲートを一巡したら記録する（節目3/4）。ゲート1つごとには書かない:
   ```bash
   bash .claude/scripts/loop-journal.sh inner <issue番号> gates <<'ENTRY'
   - **結果**: G1 ✅ / G2 ❌ / ...
   - **落ちた内容**: <何が落ちたか>
   - **差し戻し先**: <どこへ戻すか。その判断理由>
   ENTRY
   ```
6. FAIL の場合は差し戻し先を特定し、リトライを記録して G1 からやり直す:
   ```bash
   bash .claude/scripts/loop-state.sh retry "<今回何を変えるか>"
   ```
7. `loop-state.sh check` が exit 1 を返したら**ハードストップ**。コミットも PR 作成もせず、
   リトライ経緯・落ちたゲート・推定原因・選択肢をユーザーに報告して指示を仰ぐ。
8. 全ゲート PASS で `smart commit` → PR 作成 → `bash .claude/scripts/loop-state.sh complete`。
9. 完了を記録する（節目4/4）。ハードストップ時は `done` ではなく `halt` を使う:
   ```bash
   bash .claude/scripts/loop-journal.sh inner <issue番号> done <<'ENTRY'
   - **やったこと**: PR 作成。全ゲート PASS
   - **なぜ**: <最終的に効いた修正と理由>
   - **次**: <次の Issue への申し送り>
   ENTRY
   git add .claude/memory/journal && git commit -m "chore: record inner-loop journal for #<番号>"
   ```
   ジャーナルは**別端末への引き継ぎ資産**。コミットしなければ他の端末から続きを拾えない。
10. 差し戻しが1回でもあった場合は `loop retro` で教訓を記録する（必須）。
    ジャーナル（経緯）と lessons.md（教訓）は別物。両方書く。

## Codex 注意点

- ブラウザツールが使えない場合、G2 は CLI 実行・API 呼び出しで代替し、**未実施の視覚確認を明記する**。
  「UI が無いので確認不能」で終わらせない。
- サブエージェントを別プロセスとして持てない場合は、各ゲートを**独立した検証パスとして順に実行**する。
  役割を混ぜず、1パス1観点を守る。
- ゲートを通すためのテスト削除・`.skip` 化・`--no-verify` は禁止。発覚時点でハードストップ扱い。
- `loop-state.sh init` を飛ばすとハードストップが働かない。必ず実行する。
