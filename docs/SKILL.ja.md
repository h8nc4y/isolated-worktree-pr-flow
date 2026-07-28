# Isolated Worktree PR Flow（隔離 worktree からの PR 作成手順）

これはリポジトリルートの [SKILL.md](../SKILL.md)（英語・正典）の日本語版です。内容が
食い違う場合は英語版を正とします。

main checkout が dirty（未コミット WIP あり）・behind・他エージェントと共有のいずれか
で、その checkout に触ってはいけないとき、`origin` の default branch から一時 git
worktree を切って PR として変更を出荷するための手順です。worktree の作成、fresh
worktree の依存欠如への対応、bounded CI ポーリング、merge 方式別の cleanup ガード
までを扱います。

## なぜ worktree 分離が必要か

複数のエージェントセッションが同じ作業ディレクトリに入ると（例: セッションの一括
起動）、git の HEAD・現在ブランチ・未コミット変更は全セッションの共有状態になり、
互いの足元を動かし合う事故になります。実測された事例では、一方のセッションが
`git switch -c` でブランチを作成した1分後に、同じ checkout 内の別セッションがその
ブランチから分岐してコミットし、default branch へマージしていました。

検知の型（数分で衝突を確定できる順序）:

1. 異変のサイン: 自分が書いていないファイルが出現する。または `git status` が
   セッション開始時に取ったスナップショットと食い違う。
2. タイムスタンプ精査: `ls --time-style=full-iso`（または各プラットフォームの
   同等コマンド）。複数ファイルが**同一ミリ秒**を共有していたら、それは git 操作
   （checkout / merge / stash）の書き込み痕跡であり、人手や LLM の逐次編集では
   ない。
3. `git reflog --date=iso` で時系列を確定する: 誰がいつ checkout / commit /
   merge したか。
4. エージェント環境にセッション一覧機能があれば、同一作業ディレクトリで動作中の
   別セッションをそれで特定する。

衝突を確認したあとの譲り方:

- **先にコミットした側が書き込み役**。後手は書き込みを止める — commit や branch
  切替を続けると相手セッションの HEAD を動かし、両方壊れる。
- 後手は検証役として価値を出す: 書き込み役の成果物への敵対的レビュー
  （ドキュメントの主張とコードの突合・テスト再実行・公開前チェック）と、
  ファイルに触れないチャット納品物。
- 自分が作った中間物（空ブランチ等）だけを自分で掃除する。相手セッションが触った
  ref には触れない。
- 追記型のログは、セクション見出しを分ければ両セッションが書いてよい。

予防: **1リポジトリ = 1書き込みセッション**。複数エージェントが同じリポジトリを
触る必要があるなら、それぞれを worktree で分離する — それがこの skill です。
最も安価な検知習慣は、作業開始直後に `git status` をセッション開始時スナップ
ショットと突合し直すことです。

## 可搬性

このフローは Windows（PowerShell + Git Bash）で鍛えられましたが、`git` / `gh`
コマンド自体はクロスプラットフォームです。シェルが異なる箇所は PowerShell と
POSIX の両方の例を併記しています。CI は Windows host に加え、Ubuntu 24.04 と
native macOS 15 で合成 cleanup guard と private-marker scanner を実行する
PowerShell 7 job を含みます。3 job は
[PR #7 run 30216166105](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30216166105)
で全て成功しました。Windows 固有の部分（ディレクトリ junction とその削除
セマンティクス）には POSIX の symlink 相当をインラインで注記しています。

## いつ使うか

- main checkout が dirty（未コミット WIP あり）・behind・他エージェントと共有の
  いずれかで、そこに直接ブランチを切ると WIP を壊しかねないとき。
- 小さな hygiene 修正でも、既存 checkout が大きく behind + dirty WIP の状態なら、
  分離 worktree の方が安全（実運用で確認済み）。
- branch-per-task 運用（default branch へ直接コミットしない）を前提とする。この
  skill は「そのブランチをどこに置くか＝dirty checkout の外の一時 worktree」という
  メカニクスだけを扱う。

## 手順

1. 状態確認（非破壊）。`git` は全て `-C <repo>` を付け、`gh` は全て
   `--repo <owner>/<name>` を付けて、カレントディレクトリ非依存にする —
   エージェント環境は呼び出しごとに作業ディレクトリがリセットされることがあり、
   repo 外の cwd では `--repo` 無しの `gh` が "not a git repository" で失敗する。

   ```powershell
   git -C <repo> status --short          # 作業前の WIP を記録（最後に不変を検証する）
   git -C <repo> branch --show-current
   git -C <repo> fetch origin
   gh repo view <owner>/<name> --json defaultBranchRef -q .defaultBranchRef.name   # 結果を以降 <default> として使う
   ```

   同じコマンドが POSIX シェルでもそのまま動く。

2. `origin` の default branch から一時 worktree を作成する（dirty checkout には
   触らない）。`<default>` は手順 1 で取得した値を代入する。`main` 固定にしない —
   default が `master` のリポジトリは今も普通に存在する。

   ```powershell
   git -C <repo> worktree add -b fix/<task> ..\_worktrees\<task> origin/<default>
   ```

   POSIX:

   ```bash
   git -C <repo> worktree add -b fix/<task> ../_worktrees/<task> origin/<default>
   ```

   置き場所は書き込み可能と確認済みの場所にする。システム共通の temp ディレクトリ
   は sandbox 化されたエージェント環境から書き込めないことがある（実測）。repo 隣の
   `_worktrees/` か環境指定の temp ディレクトリを使い、重い処理の前に probe
   ファイルを 1 個書いて消せることを確認する。

3. 最小 diff で変更する。変更対象のファイルだけを worktree 側で編集（または
   コピー）する。main checkout の未追跡 WIP を丸ごと持ち込まない — 上流や他
   エージェントが同名ファイルを追加し得るため、余計なファイルは merge 時の
   add/add 衝突や PR 差分汚れの原因になる。base 側の未コミット依存ファイルの写しを
   やむを得ず入れる場合は「merge 時どちらを優先するか」を PR 本文に明記する
   （実運用の教訓: 明記したことで誤った自動解決を回避できた）。

4. fresh worktree の依存欠如に対応する。新しい worktree は `node_modules` も
   virtualenv も持たない（実測）。

   - Node: worktree で `npm ci`（lockfile 前提）。軽い検証だけなら main checkout の
     `node_modules` への一時リンクでも可 — ただし cleanup 前に必ずリンクを外す
     （安全条件 5）。PowerShell junction:

     ```powershell
     New-Item -ItemType Junction -Path <worktree>\node_modules -Target <repo>\node_modules
     # 削除は「リンクだけ消えて実体は消えない」ことが確実な rmdir を使う
     cmd /c rmdir "<worktree>\node_modules"
     ```

     POSIX symlink:

     ```bash
     ln -s <repo>/node_modules <worktree>/node_modules
     # リンク自体の削除は素の rm（-r なし・末尾スラッシュなし）
     rm <worktree>/node_modules
     ```

   - Python: main リポジトリの virtualenv の python を使い、worktree のソースを
     import させて対象テストだけ実行する。PowerShell:

     ```powershell
     $env:PYTHONPATH = "<worktree>\src"
     & <repo>\.venv\Scripts\python.exe -m pytest <worktree>\tests\<target_test>.py
     ```

     POSIX:

     ```bash
     PYTHONPATH=<worktree>/src <repo>/.venv/bin/python -m pytest <worktree>/tests/<target_test>.py
     ```

5. 検証が通ったら commit・push・PR 作成。commit メッセージはファイルに書いて
   `git commit -F <msgfile>` で渡す — 複数行メッセージのインライン指定はシェルの
   quoting に弱く、特に Windows で壊れやすい。

   ```powershell
   git -C <worktree> add <対象ファイルのみ>
   git -C <worktree> commit -F <msgfile>
   git -C <worktree> push -u origin fix/<task>
   gh pr create --repo <owner>/<name> --head fix/<task> ...
   ```

6. branch protection の CI は bounded ポーリングで待つ。`gh pr checks --watch`
   は無制限待ちであり、エージェントハーネスや承認層に拒否される・ターンを塞ぐ
   ことがある（実測）。回数上限つきの one-shot で確認する:

   ```powershell
   gh pr checks <PR番号> --repo <owner>/<name> --watch=false
   gh pr view <PR番号> --repo <owner>/<name> --json state,statusCheckRollup
   ```

   bounded ループ（POSIX。foreground `sleep` がブロックされるハーネス — Claude
   Code など — では background タスクとして実行するか、他作業の合間に one-shot を
   挟む）:

   ```bash
   for i in $(seq 1 10); do gh pr checks <PR番号> --repo <owner>/<name> --watch=false && break; sleep 30; done
   ```

   bounded ループ（PowerShell）:

   ```powershell
   for ($i = 1; $i -le 10; $i++) {
     gh pr checks <PR番号> --repo <owner>/<name> --watch=false
     if ($LASTEXITCODE -eq 0) { break }
     Start-Sleep -Seconds 30
   }
   ```

   上限回数と間隔の最適値はリポジトリの CI 所要時間に依存する（一般解は未確認 —
   リポジトリごとに調整する）。

7. merge する。**merge 方式を先に決める** — 方式によって cleanup 前の未マージ
   検証（安全条件 2）が変わる:

   - `--merge`（merge commit）: branch の commit が default の ancestor になる
     ので、検証は `merge-base --is-ancestor` + `branch -d`（安全条件 2a。実測済み
     の方式）。
   - `--squash` / `--rebase`: branch の commit は default の ancestor に
     **ならない**ので、branch に対する `--is-ancestor` は merge 成功後も必ず
     exit 1 になる。「MERGED + headRefOid 一致」guard（安全条件 2b）を使う。

   ```powershell
   gh pr view <PR番号> --repo <owner>/<name> --json headRefOid -q .headRefOid   # merge前にこのexact OIDを保持
   gh pr merge <PR番号> --repo <owner>/<name> --merge      # squash 運用の repo は --squash（安全条件 2b を使う）
   gh pr view <PR番号> --repo <owner>/<name> --json state,mergedAt,mergeCommit
   ```

   `gh pr merge` まわりの既知挙動（実測）:

   - local の default branch が別 worktree で checkout 中だと、repo 内 cwd で
     実行した `gh pr merge --delete-branch` は remote merge 成功後のローカル
     後処理で失敗することがある。`--repo` 付きで repo 外 cwd から merge すれば
     ローカル後処理自体が走らず、この失敗クラスを最初から回避できる。
   - それでも失敗表示が出たら、まず `gh pr view --json state` を確認する —
     remote 側は merge 済みのことが多い。`MERGED` なら残りのローカル処理
     （branch 削除・worktree 削除）は下の安全条件チェック後に手動で完了する。
   - repo 内から実行した `gh pr merge` は作業中 worktree を default branch へ
     fast-forward することがあり、出力に過去 PR 分の大きな更新が見えても異常では
     ない。

## 安全条件

破壊操作（worktree 削除・branch 削除・prune）の前に、以下を**実行時点で全部**
チェックする — 検証は削除の**前**に行い、事後に回さない。削除前チェックを省略して
「後で検証する」はガードの意味を失う: 未マージの取りこぼしがあった場合、branch が
消えてから発覚することになる（実運用の教訓）。共有 checkout では承認時点と実行時点
で状態がドリフトし得るため、時間が空いたら直前に再実行する（実測）。

1. `gh pr view <PR番号> --repo <owner>/<name> --json state,mergedAt` が
   `MERGED` を返し、merge直前に記録した空でないexact `headRefOid` が保持されて
   いること。記録が無ければ、merge後に動いた可能性があるhead branchを読み直さず
   fail closedとする。両merge方式とも安全条件6までstable OIDが必要。
2. merge 方式に対応した未マージ取りこぼし検証。方式を混同しない — squash 後に
   2a を使うと正しく merge 済みでも永久に通らず、squash 後の `branch -d` は
   upstream（`origin/fix/...`）が残っていれば merged-to-upstream 判定で素通り
   （ancestor 保証にならない）、upstream が消えていれば "not fully merged" で
   永久拒否される。

   - **2a — `--merge`（merge commit）方式**:
     `git -C <repo> merge-base --is-ancestor fix/<task> origin/<default>`
     が exit 0（PowerShell は `$LASTEXITCODE`、POSIX シェルは `echo $?` で確認）。
     branch 削除は `-d` — 未マージの取りこぼしがあれば git 自身が拒否してくれる
     （実測）。注意: `-d` の merged 判定は「upstream があれば upstream、なければ
     HEAD」基準のため、remote branch 削除 + prune の後で、かつ checkout の HEAD が
     古い別ブランチに載っていると、正しく merge 済みでも `not fully merged` で
     拒否されることがある（実測）。この場合は、直前の `--is-ancestor` が exit 0
     だったことを確認済みであることを条件に `-D` で削除してよい — 2b と同じ
     「guard 確認後の `-D`」の型であり、guard 未実施の `-D` は引き続き不可。
   - **2b — `--squash` / `--rebase` 方式**:
     `gh pr view <PR番号> --repo <owner>/<name> --json state,mergeCommit` で
     `state` / `mergeCommit` を取得し、merge前に保持した `headRefOid` を使う。
     `mergeCommit` は
     JSON オブジェクトで、commit ハッシュはその `oid` フィールド
     （`-q .mergeCommit.oid` で抽出できる）。`headRefOid` は素の文字列。
     そのうえで次の両方を確認する:
     (i) `git -C <repo> merge-base --is-ancestor <mergeCommit-oid> origin/<default>`
     が exit 0、(ii) `git -C <repo> rev-parse fix/<task>` が
     `headRefOid` と一致。(ii) が squash 方式における「commit の取りこぼしなし」
     の代替検証で、merge された PR の head が local branch の先端そのものである
     ことを証明する。両方通ったときのみ、意図的な `git branch -D` で削除する
     （この guard が `-d` の代替）。
     guard 2b の履歴形状と拒否経路は `scripts/test-cleanup-guards.ps1` の
     使い捨て合成 Git 履歴で回帰検証する。このテストは system/global Git config、
     hook、署名、`rebase.updateRefs` を隔離し、ambient な `GIT_*` 環境変数を全て
     snapshot・消去・復元するため、repo や trace の path は fixture 外へ逃げない。
     再帰 cleanup は OS 別の path 比較で生成した temp 直下の GUID 子だけに制限し、
     reparse point を拒否する。GitHub の live squash 経路は 2026-07-23 に
     [PR #2](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/2) で実測し、
     `MERGED`、default branch に入った `mergeCommit`、local / remote の先端と
     `headRefOid` の一致、guard 後の local `-D` と明示的な remote 削除が全て通った。
     GitHub の live rebase 経路は 2026-07-26 に
     [PR #5](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/5) で実測し、
     `MERGED`、書き換えられて default branch に入った `mergeCommit`、元 head が
     default branch の ancestor ではないこと、local / remote の先端と
     `headRefOid` の一致、guard 後の local `-D`、明示的な remote 削除、owned
     worktree cleanup が全て通り、main checkout も不変だった。

3. 消す対象の worktree / branch が「このフローで自分が作った」ものであること —
   他エージェントや人間のものは消さない。
4. main checkout の WIP（`git status --short`）が手順 1 の記録から変わっていない
   こと。
5. `node_modules` のリンクが残っていないこと。PowerShell:
   `(Get-Item <worktree>\node_modules -ErrorAction SilentlyContinue).LinkType`
   が `Junction` を返したら、先に `cmd /c rmdir "<worktree>\node_modules"` で
   外す。POSIX: `test -L <worktree>/node_modules && rm <worktree>/node_modules`。
   `node_modules` は通常 git-ignored なので `git worktree remove` の clean 判定の
   対象外 — そして再帰削除がリンクを実体側へ辿った場合、main checkout の実体
   `node_modules` を巻き込み削除する恐れがある。再帰削除が junction / symlink を
   辿るかどうかはツールとバージョンに依存する（未検証）— それに頼らず、リンクは
   明示的に外す。
6. `origin` に `refs/heads/fix/<task>` が残っている場合、削除対象は安全条件1で
   保持を確認したexact `headRefOid` と一致するrefだけに限定する。
   `git -C <repo> ls-remote --exit-code --heads origin refs/heads/fix/<task>` の
   exit 2は既にremote branchが無いので削除をskip、exit 0は`<headRefOid>` の
   exact 1 recordだけを受理し、それ以外はfail closedとする。
   観測後にも別sessionがrefを前進できるため、削除は下記のexpected-value付きlease
   だけで実行する。remote-tracking refに依存する暗黙の`--force-with-lease`は
   background fetchで観測が動くため使わない。exact leaseならremote refがPR head
   から変わった時点でserverが削除をatomicに拒否する。
   exact-head削除とpost-merge drift拒否は、local bare remoteとsyntheticなsecond
   actorで回帰検証する。同じleaseの実GitHub remote経路は未確認。

チェックが全て通ってから実行する:

```powershell
git -C <repo> worktree remove ..\_worktrees\<task>
git -C <repo> worktree prune
git -C <repo> branch -d fix/<task>          # 2a（--merge）方式。not fully merged 拒否なら 2a の注意（is-ancestor 確認後の -D）。2b 方式は guard 確認済みの場合のみ -D
git -C <repo> push --force-with-lease=refs/heads/fix/<task>:<headRefOid> origin :refs/heads/fix/<task>   # exact remote refだけ。既に無ければskip
git -C <repo> remote prune origin
```

（POSIX: パスを `../_worktrees/<task>` にする以外は同一。）

削除まわりのトラブルシュート:

- cleanup の順序が重要: branch 削除の前に worktree を remove する。いずれかの
  worktree で checkout 中の branch は、`-d` / `-D` のどちらでも `used by
  worktree` で削除拒否される — これは git の防御が正しく機能している状態であり、
  `not fully merged` とは別種の拒否（実測）。
- `git worktree remove` が未追跡物ありで拒否されたら、安易に `--force` へ
  逃げない。実際に何が残っているか — 外し忘れのリンク・ビルド生成物・退避し
  忘れの成果物 — を確認し、個別に対処してから再実行する。
- Windows で worktree ディレクトリの削除が "permission denied" で失敗する場合、
  ディレクトリを掴んだままのプロセスハンドル（エディタ・シェル・エージェント
  プロセス）が典型的な原因。ハンドルが解放されるのを待ってから再試行する —
  実運用の経験則: 同じ削除が、force 無しで時間をおいたら成功した。

## やらないこと・停止条件

- main checkout への pull / reset / rebase / clean / checkout 切替はしない。
  dirty WIP は他エージェントの進行中作業かもしれない。残 WIP の確認は
  `git diff origin/<default>` などの読み取りだけで行う（実測）。
- 他エージェント・オーナーのブランチ・WIP のアーカイブ・移動・削除は承認なしに
  しない。
- stacked PR: base branch を `--delete-branch` で消すと後続 PR が closed になる
  （実測）。後続 stack がある間は remote branch 削除を遅らせる。
- stale `index.lock` は、対象パスが worktree metadata 内であること・排他 open が
  無いこと・作成時刻が十分古く進行中操作でないことを確認して stale と判断してから
  のみ削除する。読み取り確認のコマンドには `GIT_OPTIONAL_LOCKS=0` を付ける
  （実測）。
- 同種の失敗が 3 回改善しなければ停止して報告する。cost / secret / credential の
  stop 条件は常に優先する。

## 完了チェック

- `gh pr view <PR番号> --repo <owner>/<name> --json state,mergeCommit` で
  `MERGED` と merge commit を記録した。
- `git -C <repo> worktree list` に一時 worktree が残っていない。
- local / remote に作業 branch が残っていない（branch を残す方針のリポジトリは
  除く）。
- main checkout の `git status --short` が作業前の記録と完全一致（WIP 不変）。

## 報告

- 報告はタイムスタンプ（日付・時刻・タイムゾーン明記）で始める。
- 含める内容: worktree の作成場所、PR URL、merge 方式と merge commit、CI 結果
  （one-shot poll の回数と最終状態）、cleanup の実施内容、main checkout 不変の
  証跡（status 比較）、未確認事項。
- 実測していない値（CI 所要時間・poll 上限の最適値など）は断定せず「未確認」と
  書く。

## 出典・位置づけ

この skill は、共有された Windows 開発マシン上でのエージェント駆動開発の実運用から
蒸留したものです — 上記の各ルールは、実際に観測された失敗か検証済みのリカバリに
遡れます（推測由来のルールはありません）。「実測」「実運用の教訓」と書かれた項目は
実際に踏んで回避した挙動を指します。まだ実運用検証がない項目は明示的に
「未確認」と記しています — 現在の主な例は、再帰削除のリンク追従挙動の
プラットフォーム差です。guard 2b の GitHub 側 squash / rebase 操作は live
実測済みで、両方式の local Git 履歴形状と拒否経路にも合成回帰テストがあります。
