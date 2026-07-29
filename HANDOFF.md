# HANDOFF

更新日: 2026-07-29 (JST)

## Current state

- guard 2bとguard 2a forced fallbackのlocal branch削除を
  `scripts/remove-local-branch-cas.ps1`へ集約した。
  helperはtask slugをbranch生成前に検証し、Git common directoryのnonblocking
  owner-nonce cleanup lock、nonce由来のGit-native guard worktree、Git標準
  `config.lock` writer排他、owner config隔離、expected-OID CAS、最終確認を
  一つのcritical flowで扱う。
  各Git child processはambient `GIT_*`を全消去し、安全値だけを設定してから元の
  環境をexactに復元する。ordinal keyでPOSIXのcase-variant名も別entryに保つ。
  productionはfresh CLI processを保証境界とする。GitをApplicationとして解決し、
  PATH先頭のexisting absolute `git` / `git.exe` pathを保持する。critical built-inは
  module-qualifiedで呼ぶ。closureへreview済みfunction identityを保持し、同名aliasと
  同期hookによるfunction差替えを次のcritical call前に拒否する。各caller scopeで
  module-qualified resolverを生成してclosureへ渡すため、CI wrapperのchild script
  scopeでもfunction identityを解決できる。dot-source/test hookはtrusted harnessであり、
  敵対的な同一runspace非同期mutationは保証外とする。
- disposable local fixtureはPowerShell 7 / Windows PowerShell 5.1で各211
  assertionsを持つ。
  既存・interleaved checkout、通常add/switchのguard拒否、config観測→rename
  drift、config付きbranchのCAS拒否、同nonce config writer、CAS直前drift、
  CAS後の同名branch再作成、予期しないguard entry、ambient Git redirect、
  active/stale cleanup lock、nonce不一致、標準config writer排他、
  configless→config race、既存/reparse/path/content drift config lock、
  CAS前のowner config回復競合、ambient alias / function差替えを
  fail closedで固定した。
- 独立reviewは、worktree/config race、ambient Git routing、CAS直前の
  checkout race（P1）、validatorのcondition/body false-greenと二次回復失敗（P2）、
  case-sensitive環境snapshot（P2）、task slugのregex注入（P3）を検出した。
  最新reviewでは、全wrapper callを覆わないallowlistとmodule/path-qualified
  process名回避（P1）、queryと`--remove-section`の間に同nonce writerを消し得る
  non-atomic config cleanup（P2）を検出した。現在は自動config removeを廃止し、
  config付きbranchをCAS前で拒否する。
  その後のreviewで、configless観測後のconfig再作成race、alias/proxy回避、
  destructive identity/flag resetを検出した。現在はGit標準`config.lock`を
  最終config照会からpost/final checkまでowner nonce付きで保持する。
  open-world AST allow/denyとhostile mutation catalogは未知構文を閉じ切れず複雑化したため、
  helper全体のLF正規化SHA-256 closed-world fingerprintへ置換した。parse、ordered
  top-level 30 functions、phase順、top-level execution skeleton、Application Git path、
  CLI entryだけをsmall semantic anchorとして残す。baselineは自動更新せずhelper diffと
  old/new digestを同じreviewで確認する。
  直前freezeの独立reviewはclearした。PR #18の初回3 CIは、Actions temp wrapperが
  test scriptを通常callするchild scopeからclosureがfunctionを解決できず失敗した。
  同じscopeをlocalで再現し、caller-scope resolverで修正した。helper-only reviewはclearし、
  normalized baselineを`cd9238e...d8972`へ更新した。最終freeze reviewは未確認。
- resolver修正後のcleanup guardsはnested/directのPowerShell 7 / 5.1で各211
  assertions成功。正規logical slot内で両hostの
  private-marker self-testとrepository scanも成功した。Gitleaksはcustom global-hook
  configによるworktree/history scanが成功し、Semgrep固定ruleの対象source変更は0件。
  fresh child processのCLI smokeは、fixture/processを作る前にexecution policyで拒否された。
  同じ操作の再試行や迂回はせず、CLI smokeは未確認として残す。
  実GitHub local-CAS、実GitHub競合、production、credential、OAuth、real data、
  paid serviceは実施していない。
- [PR #16](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/16) で、
  cleanup guard 2a / 2bのnamed operandを`refs/heads/fix/<task>`と
  `refs/remotes/origin/<default>`へ完全修飾した。feature commitは
  `950c92dcfb44e7b1c819d29ff0771a1951b56615`、merge commitは
  `8f7ef9bc0e5e8922e0c03d7a710a13df1e0a2212`で、両treeは一致する。
- 同名tagが短縮ref解決を奪い、削除対象branchまたはfetch済みdefault branch以外を
  検証するfalse-passを、使い捨てmerge / squash fixtureで再現して拒否する。
  独立reviewはP0-P3なしでclear。
- PR CI [run 30422704494](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30422704494)
  はWindows、Ubuntu 24.04、native macOS 15の全job・全stepが成功した。
- merge後のremote cleanupでは、保持した`headRefOid`とexact remote 1 recordの
  一致を再確認し、expected-value leaseで削除成功、再照会exit 2を確認した。
- 同じmerge treeのlocal post-main再検証では、cleanup guardsがPowerShell 7 /
  Windows PowerShell 5.1で各28 assertions、readinessとrepository private-marker
  scanが両host、Gitleaks、whitespaceが成功した。merge前の同treeでは両hostの
  scanner self-testも成功し、Semgrep固定ruleの対象source変更は無い。
- [PR #14](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/14) で、
  merge後のremote branch削除を `headRefOid` のexact expected-value leaseへ
  変更した。feature commitは
  `6ace3004a4bc3c442ec95454ad42f30f27c77806`、merge commitは
  `42e1811f3a0ae0c9f872bcda73a17a29a004e4fe`で、両treeは一致する。
- PR #14のremote cleanupでは、merge前に保持したOIDとexact remote 1 recordの
  一致を再確認し、GitHubへexpected-value leaseを適用して削除成功、再照会exit 2を
  確認した。実GitHubで観測後に別actorをdriftさせる拒否経路は未確認。
- merge後の [post-main run 30398172444](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30398172444)
  はWindows、Ubuntu 24.04、native macOS 15の全job・全stepが成功した。
- 同じmerge treeのlocal post-main再検証では、cleanup guardsがPowerShell 7 /
  Windows PowerShell 5.1で各23 assertions、readinessが両host、private-markerと
  Gitleaksが成功した。Semgrep固定ruleの対象source変更は無い。
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

- task slugはbranch/ref/config queryを組み立てる前に`\A[a-z0-9-]+\z`へ限定し、
  末尾LFを含む入力も拒否する。
- repo-common lockは`CreateNew`を一度だけ試し、owner nonceを各破壊phaseと`finally`で
  再確認する。
  active/stale/所有不確実なlockを自動削除しない。
- 全ambient `GIT_*`をsnapshot/clearし、isolated configとprompt controlだけを
  exact Name/Value pairで設定する。ordinal dictionaryを型変換せず返し、各Git
  callの`finally`にあるforeach body直下で元の存在と値をexactに復元する。
- production利用はfresh CLI processに限定する。GitはApplicationとして解決し、
  PATH先頭のexisting absolute `git` / `git.exe` `.Path`だけを使う。criticalな
  PowerShell built-inはmodule-qualifiedで呼ぶ。review済みfunction ScriptBlock identityを
  closureへ固定し、同名aliasと同期hookによるfunction差替えを再検査する。
  dot-source/test hookはtrusted harnessであり、敵対的な同一runspace非同期mutationは
  協調protocolの保証外とする。
- lock内でnonce由来の`--no-checkout` guard worktreeを取得する。
  exact path、fully-qualified branchのsole porcelain record、expected
  common-directory marker、non-reparseかつ`.git`だけのrootを繰り返し確認する。
  通常のworktree add/switchはGit native occupancyが拒否する。
  Git標準common-dir `config.lock`をowner nonce付き`CreateNew`で単発取得し、
  exact root/path/reparse/handle/path nonceを最終config照会からCAS/post/final
  checkまで保持する。通常config writer、既存lock、所有不確実はfail closedにする。
  自動CASはconfigなしbranchだけを対象にする。元configがあれば
  `branch.codex-cleanup-<nonce>`へ隔離し、rename直後/CAS直前にexact snapshotを
  照合したうえでCASを拒否する。Git configにatomic expected-value section deleteが
  無いため、自動removeもrename-backも行わず、temporary config、ref、guard、lockを
  外部回復用に保持する。
- guard cleanupはnormal removeを先に試す。
  CAS outcome既知、またはCAS前拒否でbranchがexpected OIDのままであり、かつ全owner
  invariant再確認済みの場合だけ、Gitのexact-path `worktree remove --force`を
  一度許可する。
  予期しないentry・metadata・回復失敗はguardとlockを保持し、branchを再削除しない。
- readiness validatorはhelper全体をCRLF/裸CRだけLFへ正規化し、UTF-8 no-BOMの
  SHA-256 closed-world fingerprintで固定する。code、comment、空白のその他の変更を
  全て拒否する。parse、ordered top-level 30 functions、phase順、top-level execution
  skeleton、Application Git path、review済みCLI entryをsmall semantic anchorとして残す。
  self-testは1文字drift拒否とCRLF/LF同値だけを確認する。baseline変更は自動化せず、
  helper実diffとold/new digestを同じreview itemにする。
- remote branchのexact expected-OID leaseと、guard 2a / 2bの完全修飾ref契約は
  変更していない。

## Previous ref-qualification hardening (Class M)

- guard 2a / 2bは、local branchを`refs/heads/fix/<task>`、fetch済みdefault
  branchを`refs/remotes/origin/<default>`で参照する。`fix/<task>`と
  `origin/<default>`の短縮refは利用例から排除し、readiness validatorが再混入を
  fail closedで拒否する。
- synthetic fixtureは、merge済みheadにlocal / remote同名tagを置き、実branch
  またはremote-tracking refだけを異なるcommitへ進める。短縮refならtagを選んで
  false-passする前提と、完全修飾refなら対象の不一致を拒否する経路を固定する。
- remote削除のexact expected-OID lease、absent skip、second-actor drift拒否契約は
  変更していない。

## Previous remote-cleanup hardening (Class M)

- 両merge方式でmerge直前の `headRefOid` を保持し、remote refが既に無ければ
  削除をskipする。
  refが残る場合はexact OIDを観測したうえで
  `--force-with-lease=<ref>:<headRefOid>` とempty sourceを組み合わせ、別sessionの
  post-merge pushをserver側でatomicに削除拒否する。
- local bare originとsecond actorを使うfixtureを追加。expected Hの削除は成功し、
  H→Rへremoteだけを進めた場合は削除が失敗してRが残ることを確認する。
- 初回REDでは従来のplain deleteがdrift後のRを削除してexit 0となった。exact lease
  へ変更後、PowerShell 7 / Windows PowerShell 5.1のcleanup guardsは各23
  assertions、readinessは両hostで成功した。
- 実GitHub remoteのexact-head branch削除はPR #14で成功した。実GitHubのdrift
  競合、OAuth、credential、real data、paid service、deployは実施していない。

## Previous hardening (Class M)

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
- remote branch cleanupはmerge直前のPR headだけを削除でき、既存のabsent refはskip、
  post-merge driftはそのexact remote tipを保持したままfail closedする。
- local強制削除はmerge直前のPR headだけをCAS削除できる。
  checkout/ref/config/lockの競合時は、別actorのtip、reflog、configを保持して
  fail closedする。

## Key files

- `.github/workflows/validate.yml`: 3 runnerのCI契約。
- `scripts/remove-local-branch-cas.ps1`: repo-common lock内のlocal branch CAS helper。
- `scripts/validate-oss-readiness.ps1`: workflow/document/helper phaseのexact contract。
- `scripts/test-cleanup-guards.ps1`: merge topologyとlocal/remote削除CASのsynthetic regression。
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
- remote削除のexpected OIDはmerge直前の `headRefOid` を保持する。merge後にhead
  branchを読み直さず、explicit expected-value lease以外の削除を許可しない。
- local強制削除も同じ`headRefOid`を`update-ref -d`のexpected old OIDにする。
  自動CASはconfigなしbranchだけに限定する。branch configがあればCAS前にowner
  nonce付きsectionへrenameし、rename直後/CAS直前のexact snapshot照合後も
  atomic config delete不在のためCASを拒否する。自動rename-back/removeは行わない。
- repo cleanup lockは協調protocolであり、Git全体のmutexではない。
  direct Git plumbingでprotocolを迂回するactorは保証範囲外である。

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
- expected-OID local CASとdrift拒否はdisposable fixtureだけで検証した。
  実GitHub branchと実GitHub競合でのlocal CASは未確認。
- repo-common lockは協調session間のcleanupを直列化する。
  lockを使わない任意のGit操作を停止するものではない。
- deploy、release、credential、OAuth、real data、paid service操作は実施していない。

## Next step

resolver fix、fingerprint baseline、文書を再検証してfreezeし、同じreviewerへ
最終read-only reviewを依頼する。clear後は修正5ファイルだけをstageし、global
pre-commit guardを通して追加commit/pushする。PR #18のCI再実行、self-review、
merge、post-main確認と安全なbranch/worktree cleanupまで直列に完了する。
