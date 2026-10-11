---
epic: issue-41
title: "issue-41"
started: 2026-10-11
status: active
---

# インナーループ記録: issue-41

> **このファイルはアウターループ完了時に Vault へ書き写され、削除される。**
> 恒久的な教訓は `.claude/memory/lessons.md` に書く。ここは「何をやって、なぜそうしたか」の経緯。
> 別端末・別作業者が続きを引き継ぐための記録なので、必ずコミットする。

<!-- LOOP-JOURNAL:ENTRIES -->

## 2026-10-11T03:30Z / #41 / start — ツールを使わないサブの使用量が 0 になる原因を実測で特定する

- **やること**: #41。ツールを使わないサブエージェントの使用量が 0 / $0 と表示される原因を実測で特定し、正しいノードに付けるか、付けられなければ「不明」と表示する
- **なぜ**: 0 円表示は実際より安く見せ、ループ設計の判断を誤らせる。不明より悪い
- **方針**: 推測で直さない（#17 / lessons #6）。まず hook-events.md の手順で隔離サンドボックスを作り、ツールを使わないサブとツールを使うサブの両方で SubagentStart / SubagentStop の stdin と agent_transcript_path の中身（読んだ時点の行数・usage の有無）を採取する。候補は Issue の 2 つに加えて、(3) SubagentStop の時点で transcript がまだ書かれておらず、行が無いまま usage_status=ok・models=[] になって 0 と表示される、を疑う（derive.mjs の toUsage は models が空でも ok として 0 を出す）
- **参照した教訓**: #17 実測値の匿名化 / #23 外部由来のパスは 1 回だけ開いて fd で判定、hook は scratchpad で編集してユーザーが差し替える / #24 実装の形を名指しする / #22 1 項目だけ壊すテスト

## 2026-10-11T06:28Z / #41 / impl — SubagentStop で未完の transcript を読み直し、空の集計を不明にする

- **原因（実測。Claude Code 2.1.296・haiku・隔離サンドボックスで A 6 回 / B 2 回）**: 仮説 3（読み取りの競合）。ツールを使わないサブの最後の assistant 行（end_turn）は SubagentStop と同時〜100ms 後に書かれ、フックは約 20ms 後に読むので assistant 0 行から ok + models:[] を送り、derive が 0 円表示した（5 回中 5 回）。仮説 1（usage が無い）・2（紐付けのずれ）は否定。Issue の「agent=unknown の行」は formatEventRow が agent_type の無い UsageSnapshot を unknown と書いたタイムライン行。ツールで終わるサブは tool_use 行が実行前に書かれるので競合しない
- **やったこと**: monitor-emit.sh の tally が「isMeta を除いた最後の非空行が assistant か」を持ち、SubagentStop で偽なら incomplete（最優先）。背景で 0 / 0.2 / 0.3 / 0.5 / 1.0 秒待って読み直す（毎回 PERL_READ の 1 回 open、sysopen は 1 箇所のまま）。最後まで未完なら unknown / incomplete を 1 通。schema に incomplete、derive は ok + 空 models を unknown / incomplete に。event-schema.md・security.md を更新。fixture 4 点、テスト（emit [US6] 15 件・fixtures・intake・derive・view）
- **なぜ**: AC2（サブのノードに出る）には送信側で書き終わりを待つ以外にない。判定を「最後の行が assistant」にしたのは、ツールで終わるサブ（最後が tool_use の assistant）も同じ条件で完了と判定でき、待ちが不要だから。isMeta を除くのは、書き終わった transcript の最後に isMeta の user 行が付くため（QA が実測 fixture で発見。除かないと永久に未完）。受信側の防御は古いフックからの ok+[] にも効かせるため
- **捨てた選択肢**: PostToolUse(Agent) の tool_response.usage（背景起動の Agent では null。実測）／受信側だけで 0 を不明にする（AC2 を満たさない）／Stop にも待ちを入れる（Stop では競合が観測されず、最後が system 行の場合に不要な待ちと unknown を招く）
- **別件（後続 Issue）**: tool_use で終わるメッセージの行は stop_reason:null のまま output_tokens が途中の値で確定値に更新されない（B1: transcript 24 / tool_response 213）
- **作業場所**: #23 の教訓に従い scratchpad の git worktree で作業。本体の .claude/hooks は未変更
- **次**: G1 へ

## 2026-10-11T07:16Z / #41 / gates — G1〜G5 一巡で全 PASS（retry 0）

- **結果**: G1 ✅（13 スイート・node 552・監視イメージ 68・bash 5.2 非 root で monitor-emit 543）/ G2 ✅ / G3 ✅ / G4 ✅（高0・中1・低4）/ G5 ✅（中以上 0・低 2）
- **G2 の実機所見**: 実サーバ + W のフックで claude -p を 3 回。0 円表示は 0 件。1 回目の SubagentStop では未完を実際に捕捉して incomplete を送り、この版の handback 強制で来る 2 回目の SubagentStop で ok（output 423）に置き換わった。ツールを使うサブは待たずに値が届いた
- **G3 の判断**: AC4 の「紐付けを外す変異」は、実際の原因が読み取りの時機だったので、読み直し・判定・isMeta・Stop の待ち・上限・ok+[] の不明化の変異で充足とした。タイムラインの unknown 表記と output_tokens の過少計上は範囲外で別 Issue が妥当
- **G4 の変異**: 読み直しを 1 回にすると [US6] 5 件 FAIL、derive の空 models 処理を外すと 3 件 FAIL
- **Refactor**: event-schema.md の旧記述（ok + 空 = 0 トークン）を新仕様に合わせた（G3・G4 中）。security.md に「未完の間は集計も最大 5 回、累計 2 秒は待ちだけ」（G5 低）。ループ変数 wait → delay、未使用変数・依頼文の見出し・不要な exec を整理。単体実行で [US6]「5.5 秒以内」が 6 回中 3 回揺れた（5.6〜7.4 秒。ポーリングと jq 起動の負荷）ので上限を 10 秒に緩めた。上限はハング検出のためで、下限 1.5 秒（読み直しをしていること）は変えていない。再 G1 で全 PASS
- **次**: PR

## 2026-10-11T07:16Z / #41 / done — PR 作成・全ゲート PASS

- **やったこと**: G1〜G5 PASS、retry 0。scratchpad の worktree で実装し、本体の .claude/hooks は触っていない（マージ後の pull で反映）
- **なぜ**: 推測で直さず、隔離サンドボックスで SubagentStop 時点の transcript を時刻付きで採取したのが決め手。Issue の 2 仮説はどちらも外れで、原因は読み取りの時機だった
- **残課題**: (1) tool_use で終わるメッセージの行は output_tokens が途中の値のまま（後続 Issue）(2) タイムラインで UsageSnapshot の行が agent=unknown と出る（後続 Issue）(3) handback 強制のある版では 1 回目の SubagentStop は incomplete になり、2 回目で値に置き換わる（0 円にはならない）
- **次**: マージ判断（ユーザー）。マージ後に issue-41 のジャーナルを flush
