# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

### Added

- A disposable-Git-history regression test for cleanup guards 2a and 2b,
  covering merge, squash, rebase, an unlanded merge-result commit, and a
  local branch advanced beyond the merged PR head. The fixture isolates Git
  configuration, signing, hooks, and `rebase.updateRefs`; snapshots, clears,
  and restores every ambient `GIT_*` variable with ordinal keys so case-variant
  names remain distinct on POSIX hosts; prevents repository or trace
  redirection; validates its OS-aware recursive-cleanup boundary and
  reparse-point rejection; and runs on PowerShell 7 and Windows PowerShell
  5.1 in CI.
- A disposable local bare-origin regression for remote branch cleanup,
  covering an exact merged-head deletion and a second actor advancing the
  remote ref. The drift case must reject deletion and preserve the actor's
  exact tip.
- Disposable local-branch cleanup cases for unsafe task slugs, a branch
  checked out in a linked worktree, checkout inserted immediately before
  native guard acquisition, ordinary worktree-add and switch rejection,
   successful config-free ref/reflog cleanup, config-bearing pre-CAS refusal,
   pre-CAS tip drift, targeted same-nonce config drift, standard config-writer
   blocking, a configless-to-config race, pre-existing/reparse/replaced/content-
   drift config locks, post-CAS same-name branch recreation, unexpected guard
   entries, ambient Git routing to another repository, active and stale cleanup
   locks, owner-nonce mismatch, observation-to-rename config drift, explicit
   pre-CAS owner-config recovery conflict, trailing-LF input rejection, and
   external guard/lock/config
    recovery, plus ambient alias and function-replacement refusal. The Windows
    PowerShell 7 and Windows PowerShell 5.1 fixture exposes 211 assertions.
    POSIX-only cases cover ancestor symlink aliases, a missing guard leaf with
    stale Git metadata, and false-success removal with a remaining final
    record; the local Linux fixture exposes 245 assertions.

### Changed

- Replaced guard 2b's unconditional local `branch -D` with the
  `scripts/remove-local-branch-cas.ps1` helper. Forced guard 2a fallback uses
  the same path. The helper validates the task slug before constructing a
  branch ref, acquires one nonblocking owner-nonce lock in Git's common
  directory, clears and exactly restores all ambient `GIT_*` for every helper
   child process, and acquires a nonce-derived Git-native guard worktree.
   Production use is limited to a fresh CLI process. Git is resolved as an
   application and retained by one existing absolute `git`/`git.exe` path;
   critical PowerShell built-ins are module-qualified. A closure retains
   reviewed helper-function identities, rejects same-name aliases, and
   rechecks identity after synchronous test hooks. A module-qualified resolver
   is created in each caller scope so an Actions temporary wrapper's child
   script scope remains visible to the closure. Dot-sourced/test-hook execution
   is trusted, and adversarial asynchronous same-runspace mutation is outside
   the cooperative threat model.
  Exact task-owned path, sole fully-qualified branch record, expected
  common-directory marker, and `.git`-only non-reparse state remain gated
   through expected-OID
   `update-ref -d <fully-qualified-ref> <headRefOid>` and final verification in
   that critical section. Automatic CAS is limited to config-free branches.
   Existing branch config is renamed to an owner-only temporary section and
   compared with exact snapshots after rename and immediately before CAS.
   After the last external hook, the helper also acquires Git's standard
   common-directory `config.lock` with a one-shot owner-nonce `CreateNew` and
   holds exact root/path/reparse/handle/path-nonce ownership from the final
   config query through CAS, post-CAS, and final checks. Ordinary config writers
   are excluded; pre-existing or uncertain config locks are never guessed away.
   A config-bearing CAS is then refused because Git config has no atomic
   expected-value section
   deletion. Automatic rename-back and temporary-section removal are both
   refused; drift preserves the temporary config, guard, lock, and ref.
   Active, stale/uncertain, and nonce-mismatched
  locks preserve the branch and are never guessed away.
  Guard cleanup tries normal removal first and permits one exact-path Git
  `--force` after a known CAS outcome, or after a pre-CAS refusal only when the
  branch still equals the expected OID, with complete owner-state
  revalidation. Unexpected entries or recovery failures preserve the guard
  and lock without a fallback branch deletion.
  On POSIX, acquisition resolves physical identity only while both paths
  exist, then stores Git's normalized lexical worktree-record path as the
  stable identity for all later checks. macOS `/var` and `/private/var`
  aliases therefore bind once, while a missing leaf or stale record remains
  fail closed during recovery and final release.
  Link targets that reintroduce an ancestor alias are re-walked from the root
  with visited-path cycle detection and a 64-rewrite limit.
- Replaced the open-world cleanup-helper AST deny/allow lists and mutation
  catalog with one LF-normalized, UTF-8-no-BOM SHA-256 closed-world
  fingerprint. Parse success, the ordered 30 top-level functions, destructive
  phase order, top-level execution skeleton, application-only Git path, and
  reviewed CLI entry remain as small semantic anchors. One-character drift is
  rejected while CRLF/LF checkout differences share the reviewed digest.
  Baseline changes must never be automated: review the helper diff and record
  the old/new digest together.
- Made readiness text-contract reads explicitly UTF-8 on both PowerShell 7 and
  Windows PowerShell 5.1. No-BOM Japanese Markdown is no longer interpreted
  through the legacy ANSI default before pattern validation.
- Fully qualified cleanup-guard inputs as `refs/heads/fix/<task>` and
  `refs/remotes/origin/<default>`. Same-name tags can otherwise win Git's
  ambiguous shorthand ref resolution, letting guard 2a or 2b inspect a
  misleading tag while the branch being deleted or fetched default branch
  does not satisfy the safety condition. Disposable fixtures reproduce both
  collisions and prove the qualified refs reject them.
- Replaced unconditional remote branch deletion with an exact expected-OID
  `--force-with-lease` for every merge mode, using the PR head retained
  immediately before merge. An already absent branch is skipped, while any
  post-merge remote drift is rejected atomically.
- Recorded a live GitHub exact-head cleanup from PR #14: the retained
  pre-merge OID matched the sole remote record, the explicit lease deleted
  that ref, and a second exact-ref query confirmed it absent. Live drift
  rejection remains bounded to the disposable bare-origin regression.
- Kept the Windows native-child poll cadence at 100 milliseconds while
  shrinking the final wait to the exact remaining operation budget. The
  readiness contract now binds the actual `Add-Type` source, direct Win32
  millisecond wrapper, pure poll helper, and unique native/managed wait calls;
  in-memory hostile mutations reject second rounding, oversize slices,
  comment/string decoys, extra waits, case-variant receiver aliases, and
  dynamic-member bypasses.
- Updated all three GitHub Actions checkout steps from the reviewed `v5`
  commit to the immutable `v7.0.1` commit
  `3d3c42e5aac5ba805825da76410c181273ba90b1`. The exact workflow validator
  requires the same revision and `persist-credentials: false` in every job;
  checkout continues to use the Node.js 24 action runtime.
- Made the rebase cleanup fixture fail directly when the landed commit does
  not differ from the original PR head, so guard 2b's rewritten-history
  premise cannot pass only through indirect topology assertions.
- Hardened private-marker scanning so every Git probe runs through a bounded,
  hermetic child-process boundary. Ambient and future `GIT_*` variables,
  home/config, hooks, attributes, excludes, templates, filters, prompts,
  replacement refs, lazy fetches, and trace settings can no longer redirect
  repository enumeration or create caller-selected artifacts.
- Replaced lexical absolute-path equality in the Git root probe with Git's
  exact inside-worktree record and empty root-relative prefix. Equivalent
  macOS path aliases no longer cause a false rejection, while subdirectories,
  `.git` directories, bare repositories, malformed records, NUL bytes, and
  Unicode format-character lookalikes remain fail closed.
- Closed the Windows start-before-Job-assignment race by creating each child
  suspended, inheriting only stdin/stdout/stderr, assigning its kill-on-close
  Job, and resuming afterward. POSIX starts each child in an atomic dedicated
  session/process group and uses errno-aware `kill(2)` cleanup.
- Changed Git-backed coverage to the union of regular stage-0 index blobs and
  tracked worktree files. One binary-safe `git cat-file --batch` reads unique
  staged blobs, while exact initial/final raw stage and index-debug snapshots
  reject staged-content and flags-only drift.
- Added fail-closed coverage for malformed/conflict/intent-to-add/gitlink
  entries, symlinks, reparse points, missing or changing worktree files,
  repository-subdirectory scope, leaf `.git` controls, and tracked local
  marker files. Sensitive text candidates now include dotenv, npm config,
  PEM/key, and extensionless names.
- Bounded the scan-wide deadline, process streams, entries, bytes, lines,
  regex matches, findings, and diagnostic fields. Diagnostics escape control,
  format, bidi, and Unicode separator characters without replaying hostile
  paths or matched values; the complete finding payload is capped at 64 KiB
  of actual UTF-8 bytes before emission. The deadline is rechecked after
  serialization and immediately before both failure and success output.
- Added distinct PowerShell 7, Windows PowerShell 5.1, and Ubuntu 24.04
  scanner self-tests. The first bounded-process call now proves exact binary
  `00/80/FF` transport across stdin, stdout, and stderr.
- Added a finite native macOS 15 validation job configured to run the
  readiness contract, cleanup guards, scanner self-test, repository scan, and
  committed-tree whitespace check under PowerShell 7. The Windows, Ubuntu,
  and native macOS jobs all passed in
  [PR #7 run 30216166105](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30216166105).
- Guarded every recursive cleanup of the scanner's per-run Git isolation
  root with an OS-aware direct-child check, an exact project prefix plus
  32-hex GUID name, a separate per-run owner marker, and regular non-reparse
  directory validation reacquired immediately before deletion. Synthetic
  valid, wrong-name, nested, regular-directory replacement, and
  junction/symlink interleaving fixtures keep the destructive boundary
  covered.
- Pinned the GitHub Actions checkout step to the reviewed `v5` commit and
  added finite job timeouts. Readiness validation now binds every runner,
  timeout, checkout revision, and step to its owning workflow job.
- Recorded live GitHub guard 2b cleanup evidence from
  [PR #2](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/2):
  `MERGED` state, landed `mergeCommit`, unchanged local and remote tips
  matching `headRefOid`, guarded local `-D`, and explicit remote-branch
  deletion after a squash merge. Rebase-merge evidence from
  [PR #5](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/5)
  additionally recorded a rewritten landed `mergeCommit`, the original head
  outside the default-branch ancestry, unchanged local and remote tips matching
  `headRefOid`, guarded local `-D`, explicit remote-branch deletion, and owned
  worktree cleanup while the main checkout stayed unchanged.

## 0.1.0 - 2026-07-16

### Added

- Initial isolated-worktree PR flow skill (`SKILL.md`): temporary worktree
  creation from origin's default branch, minimal-diff discipline,
  fresh-worktree dependency handling (`npm ci` / node_modules link /
  `PYTHONPATH`), bounded CI polling, merge-mode-aware cleanup guards
  (2a for merge commits, 2b for squash/rebase), pre-deletion safety
  conditions, and concurrent-session collision detection, yielding, and
  prevention.
- Japanese full version of the skill (`docs/SKILL.ja.md`).
- Synthetic examples: full flow walkthrough, cleanup guard cheatsheet by
  merge mode, and concurrent-session collision checklist.
- Private-marker scan for common secret prefixes, private-looking absolute
  paths, and non-allowlisted GitHub repository URLs, with a self-test and
  local marker support through `.private-markers.local` or the
  `ISOLATED_WORKTREE_PR_FLOW_PRIVATE_MARKERS` environment variable.
- OSS readiness validation script for required public project files and
  skill frontmatter.
- GitHub Actions workflow for validation, private-marker scanning, and
  whitespace checks.
- Issue and pull request templates with sanitized-report guidance.
- Contributor, security, code of conduct, editor, and Git attribute
  documentation.
