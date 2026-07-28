# HANDOFF

更新日: 2026-07-29 (JST)

## Current state

- [PR #12](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/12) で
  bounded processの最後のpoll waitを残予算内へ制限した。merge commitは
  `5a38ea72f8378510fddf0f8701d74b73f6ee2965`、merge treeとfeature treeは
  `f2b56345ebb8d6cd18c405a2076b2dfcf9445bb5`で一致する。
- merge後の [post-main run 30385701480](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30385701480)
  は Windows、Ubuntu 24.04、native macOS 15 の全job・全stepが成功した。
- このhandoffと同じtreeでは、Windows、Ubuntu 24.04、native macOS 15の
  3 jobすべてが`actions/checkout` v7.0.1のimmutable commit
  `3d3c42e5aac5ba805825da76410c181273ba90b1`を使用する。
- exact workflow validatorも同じrevisionを要求し、job単位の欠落・重複・
  別revisionに加え、`persist-credentials: false`の欠落・misnest・
  余分なcheckout設定をfail closedで拒否する。

## Current hardening (Class M)

- Windows native childの100ms監視sliceを維持し、operation deadlineの残りが100ms未満なら
  最後のwaitを残予算まで縮める。0ms以下ではnative / managed waitを呼ばずtimeout判定へ
  進む。scannerの走査対象、既定timeout、stream監視、tree cleanup、diagnostic label、
  Windows / Ubuntu / macOSのCI構成は変更していない。
- `PrivateMarker.ContainedProcess`をコンパイルする実`Add-Type -TypeDefinition` sourceを
  ASTで1件に限定し、その中の`WaitForExit(int milliseconds)`が受け取った値を
  `WaitForSingleObject`へ直接渡すことを検証する。
- `Invoke-PrivateMarkerProcess`内の全member invocationを列挙し、`WaitForExit`を
  `OrdinalIgnoreCase`で照合する。dynamic memberはfail closed、receiverは
  `$containedProcess`、`$process`の順で、いずれも直前に算出した`$remaining`を
  1引数に取るexact contractとした。
- hostile mutationはcaller / helper / C# wrapperの秒丸め、100ms超過、comment /
  string / 実`Add-Type`外のdecoy、追加wait、receiver alias、大小文字違い、
  dynamic memberを拒否する。pure helperの境界5件は残り37ms→37、100ms→100、
  101ms→100、0ms以下→0を固定した。
- TDDの初回RED後、独立reviewでreceiver aliasを見落とすP2、大小文字違いと
  dynamic memberを見落とすP2を検出し、それぞれhostile mutationを追加してREDを
  再現してから修正した。最終独立reviewはP0-P3なし。
- PowerShell 7 / Windows PowerShell 5.1のreadiness、pure helper境界各5件、
  cleanup guards各16 assertions、scanner full regression、repository
  private-marker scan、strict UTF-8 / AST / whitespace、Gitleaksはlocalで成功し、
  Semgrepの対象sourceはなかった。

## Latest maintenance change (Class M)

- 目的: 3 OSのCI checkout pinを公式latest v7.0.1へ更新し、不要なcredential
  永続化とvalidatorとのrevision driftを防ぐ。
- 影響: workflow trigger、permissions、runner、timeout、validation stepは
  変更せず、checkout actionをv5からv7.0.1へ更新して
  `persist-credentials: false`を固定する。両versionともaction runtimeは
  Node.js 24。
- 検証: workflowだけを先に更新したREDでは旧v5 revisionを要求するvalidatorが
  3 jobすべてを拒否。credential policy追加時の第二REDでは未許可のnested keyを
  3 jobすべてで拒否。`true`、misnested `with`、余分なcheckout inputのmutationも
  各対象jobで拒否した。exact block同期後、PowerShell 7 / 5.1のreadiness、
  cleanup guards各16 assertions、repository private-marker scan、Gitleaks、
  Semgrep、whitespaceがlocalで成功。

## Previous delivered work (Class M)

- 目的: private-marker scanner が所有する Git isolation root の再帰削除を、
  OS temp 直下の exact-prefix + GUID 名を持つ通常directoryだけに限定する。
- 影響: hostile Git childなどがcleanup前にrootを別path・leaf・reparse pointへ
  置換した場合は、run固有owner markerと削除直前の再取得により、再帰削除せず
  固定診断でfail closedする。
- 検証: synthetic temp fixtureでvalid / wrong-name / nested / regular
  directory差替え / reparse差替えを確認。初回review P1のcheck/use race修正後、
  PowerShell 7 / 5.1のscanner self-test、両hostのcleanup guards（各16
  assertions）、readiness、Gitleaks、Semgrep、whitespaceはlocalで成功。
  独立再reviewはP0-P3なしでclearance、PR CIとmerge後main CIも全job成功。

## Success metrics

- workflow は Windows、Ubuntu 24.04、native macOS 15 の3 jobを有限時間で実行する。
- readiness、cleanup guards、scanner self-test、repository scan、committed-tree
  whitespace checkが各runnerで成功する。
- private-marker scannerはindex/worktree両方を検査し、process・byte・record・deadline
  境界でfail closedする。

## Key files

- `.github/workflows/validate.yml`: 3 runnerのCI契約。
- `scripts/validate-oss-readiness.ps1`: workflow/documentのexact contract。
- `scripts/private-marker-process.ps1`: bounded child-process境界。
- `scripts/scan-private-markers.ps1`: public-safe marker scan。
- `scripts/test-scan-private-markers.ps1`: hostile fixtureを含むfull regression。

## Recent decisions

- Git root identityはabsolute path文字列で比較しない。1回のbounded
  `git rev-parse --is-inside-work-tree --show-prefix`で、Ordinal `true` と空prefix
  だけを受理する。
- root probe stdoutはBOMを除去せずstrict UTF-8として扱う。malformed record、
  NUL、invalid UTF-8、先頭BOM、Unicode format文字、非空prefixは拒否する。
- 同一host上のscanner self-testは直列実行する。並列runは互いのtemp isolation
  rootを検知して意図どおりfail closedする。
- checkout tag名をworkflowへ直接指定せず、公式release tagが指すreviewed
  commit SHAとcredential非永続化をvalidatorと3 jobで共有する。
- scanner所有のisolation rootは、OS temp直下のexact-prefix + GUID名に加え、
  run固有owner markerを持つ通常directoryだけを削除対象にする。初回検証後も
  削除直前にrootとowner markerを再取得し、差替えを検知したらfail closedする。

## Verification commands

- `pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1`
- `pwsh -NoProfile -File ./scripts/test-cleanup-guards.ps1`
- `pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1`
- `pwsh -NoProfile -File ./scripts/scan-private-markers.ps1`
- `git diff --check`

## Known boundaries

- macOSの証拠はGitHub-hosted `macos-15` runner上のCI契約に限定される。owner一般実機は未確認。
- v7.0.1の実行互換性はGitHub-hosted PR / main CIで確認する。local readinessは
  YAMLと文書契約を検証するが、action自体はlocal実行しない。
- deploy、release、credential、OAuth、real data、paid service操作は実施していない。

## Next step

新しいissue、PR feedback、CI failureがなければ、公開安全性とcross-platform
fail-closed契約を維持したまま、次の最高価値の小さな改善を選ぶ。
