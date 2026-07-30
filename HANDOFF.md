# HANDOFF

更新日: 2026-07-30 (JST)

## Current goal

isolated worktree PRフローの破壊的cleanupを、競合時にfail closedとなる契約として保守する。
変更は、具体的な再現または既存契約とのずれを確認してから着手する。

## Success metrics

- localとremoteのbranch cleanupはmerge直前のPR headだけを削除し、競合時は別actorの状態を保持する。
- CIはWindows、Ubuntu 24.04、native macOS 15で有限時間内に検証し、公開文書はsynthetic dataと実測済みの主張だけを使う。

## Current state

- 作業開始時はGit status、branch、remote、fetch後のdefault branch、open issue／PR、最新CIをlive測定し、このHANDOFFのsnapshotを正本扱いしない。
- PR #18でlocal branch削除のexpected-OID CASを統合した。
  headは`403937d`、merge commitは`f9a244f`で、PR CI run `30464901354`とmain CI run `30465532658`はWindows、Ubuntu 24.04、native macOS 15の3 jobがsuccess。
- PR #19で統合後実績を同期した。
  headは`80858c7`、merge commitは`f204ef8`で、PR CI run `30467476274`とmain CI run `30468043881`は同じ3 jobがsuccess。
- PR #18のtask branchとworktreeはcleanup済み。
- fresh CLI processのsmokeはpolicyによりprocess開始前に拒否された。
  再試行や代替経路を使っていないため未確認。

## Recent decisions

- task slugはbranch、ref、config queryの組み立て前に`\A[a-z0-9-]+\z`へ限定する。
  repo-common lockは`CreateNew`を一度だけ試し、owner nonceを破壊phaseと`finally`で再確認する。
- Git child processはambient `GIT_*`を消去し、安全値だけを設定して元のName/Value pairを復元する。
  productionはfresh CLI processを保証境界とし、Git Application path、critical built-in、review済みfunction identityを固定する。
- nonce由来の`--no-checkout` guard worktreeでcheckoutを拒否させ、exact path、fully-qualified branchのsole record、common-directory marker、non-reparse rootを再確認する。
  Git標準`config.lock`は最終config照会からCAS後まで保持し、config付きbranchはatomic expected-value section deleteがないためCAS前に拒否する。
- local削除は`update-ref -d <ref> <headRefOid>`、remote削除は`--force-with-lease=<ref>:<headRefOid>`でexpected OIDを固定する。
  forced guard cleanupはCAS outcomeとowner invariantを再確認できる場合だけ一度許可する。
- readiness validatorはhelperのLF正規化済みUTF-8 no-BOM SHA-256 fingerprintとsmall semantic anchorを固定する。
  baselineは自動更新せず、helper diffとold/new digestを同じreviewで確認する。

## Commands run and evidence

- 標準検証コマンドの正本は`CONTRIBUTING.md`の「Validation」とする。
- 2026-07-30の監査baselineでは、`main`と`origin/main`が`f204ef8a411ec86298d93a51984178c7e8effbe5`で一致し、tracked treeはclean、open issueとopen PRは0件だった。
- local disposable fixtureはWindowsのPowerShell 7とWindows PowerShell 5.1で各211 assertions、local LinuxのPowerShell 7で245 assertionsが成功した。
- 同じ検証単位でreadiness、private-marker self-test、repository scan、Gitleaks worktree/historyが成功した。
- 最新helper、test-only recovery fixture、最終6-file freezeの独立reviewはP0からP3までclear。
- macOSの証拠はGitHub-hosted `macos-15` runner上のCIに限定され、owner一般実機は未確認。

## Key files

- `SKILL.md`: 英語版の正本。
- `docs/SKILL.ja.md`: 日本語版。
- `scripts/remove-local-branch-cas.ps1`: local branch CAS helper。
- `scripts/test-cleanup-guards.ps1`: localとremoteの削除CAS regression。
- `scripts/validate-oss-readiness.ps1`: workflow、文書、helper fingerprintのexact contract。
- `.github/workflows/validate.yml`: 3 runnerのCI契約。

## Known issues

- repo-common lockは協調session間のcleanupを直列化するが、lockを使わないGit操作は停止しない。
- dot-sourceとtest hookはtrusted harnessであり、敵対的な同一runspace非同期mutationは保証外。
- expected-OID local CASとdrift拒否はdisposable fixtureで確認済みだが、実GitHub branchでの競合は未確認。
- production、credential、OAuth、real data、paid service、deployは未実施。

## Do not re-read or retry

- 古い実装履歴と検証経緯は`CHANGELOG.md`、Git history、GitHub PR #1から#19を参照する。
- 新しい不整合がない限り古い経緯をHANDOFFへ再展開せず、policyに拒否されたCLI smokeを再試行しない。

## Next steps

安全に自走できる具体的なlocal backlogはない。
次の変更は、GitHub issue、PR feedback、CI failure、または再現できる契約不備が見つかった場合に着手する。
`SKILL.md`を変更する場合は、同じPRで`docs/SKILL.ja.md`を同期する。
