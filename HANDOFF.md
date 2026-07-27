# HANDOFF

更新日: 2026-07-27 (JST)

## Current state

- 最新の機能変更は [PR #7](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/7) で `main` へ squash merge 済み。
- merge commit `3b2cd191bf8a4c7d1518370f8c9c3af34a1015ac` の
  [post-main run 30216691602](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30216691602)
  は Windows、Ubuntu 24.04、native macOS 15 の全 job・全 step が成功。
- open PR / 必須の既知修正: この handoff 作成時点ではなし。

## Current goal (Class M)

- 目的: private-marker scanner が所有する Git isolation root の再帰削除を、
  OS temp 直下の exact-prefix + GUID 名を持つ通常directoryだけに限定する。
- 影響: hostile Git childなどがcleanup前にrootを別path・leaf・reparse pointへ
  置換した場合は、run固有owner markerと削除直前の再取得により、再帰削除せず
  固定診断でfail closedする。
- 検証: synthetic temp fixtureでvalid / wrong-name / nested / regular
  directory差替え / reparse差替えを確認。初回review P1のcheck/use race修正後、
  PowerShell 7 / 5.1のscanner self-test、両hostのcleanup guards（各16
  assertions）、readiness、Gitleaks、Semgrep、whitespaceはlocalで成功。
  再review、GitHub CI / merge後mainは未確認。

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

## Verification commands

- `pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1`
- `pwsh -NoProfile -File ./scripts/test-cleanup-guards.ps1`
- `pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1`
- `pwsh -NoProfile -File ./scripts/scan-private-markers.ps1`
- `git diff --check`

## Known boundaries

- macOSの証拠はGitHub-hosted `macos-15` runner上のCI契約に限定される。owner一般実機は未確認。
- deploy、release、credential、OAuth、real data、paid service操作は実施していない。

## Next step

新しいissue、PR feedback、CI failureがなければ、公開安全性とcross-platform
fail-closed契約を維持したまま、次の最高価値の小さな改善を選ぶ。
