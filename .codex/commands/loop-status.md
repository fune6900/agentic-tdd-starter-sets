# loop status（ループ状態の点検）

ハードストップまでの余力と、詰まっている箇所を把握する。

## 手順

```bash
bash .claude/scripts/loop-state.sh show    # 状態・history
bash .claude/scripts/loop-state.sh check   # ハードストップ判定（exit 1 で到達）
git branch --show-current
git status --short
bash .claude/scripts/worktree.sh list
grep -c "^### " .claude/memory/lessons.md
```

状態ファイルが無い場合は「ループ外の作業中」と報告して終了する。

## 報告に含めるもの

- 対象 Issue / ブランチ / 状態（running / halted / completed）
- 余力: リトライ（現在/上限）、経過時間（現在/上限）、同一ゲート連続失敗
- ゲート状況と、失敗理由
- history（各リトライで何を変えたか）
- 次にやるべきこと

## Codex 注意点

- history を見て**同じ修正を繰り返していないか**確認する。繰り返しているなら、
  残りリトライがあってもユーザーに相談する。
- ハードストップ到達時に状態を勝手に `clear` して再開しない。ユーザーの許可が必要。
- このコマンドで `lessons.md` を書き換えない（書き込みは `loop retro`）。
