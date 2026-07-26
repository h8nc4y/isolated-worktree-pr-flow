# HANDOFF

更新日: 2026-07-27 (JST)

## Current state

- 最新の機能変更は [PR #7](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/7) で `main` へ squash merge 済み。
- merge commit `3b2cd191bf8a4c7d1518370f8c9c3af34a1015ac` の
  [post-main run 30216691602](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30216691602)
  は Windows、Ubuntu 24.04、native macOS 15 の全 job・全 step が成功。
- open PR / 必須の既知修正: この handoff 作成時点ではなし。

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
