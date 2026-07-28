# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

### Added

- A disposable-Git-history regression test for cleanup guards 2a and 2b,
  covering merge, squash, rebase, an unlanded merge-result commit, and a
  local branch advanced beyond the merged PR head. The fixture isolates Git
  configuration, signing, hooks, and `rebase.updateRefs`; snapshots, clears,
  and restores every ambient `GIT_*` variable to prevent repository or trace
  redirection; validates its OS-aware recursive-cleanup boundary and
  reparse-point rejection; and runs on PowerShell 7 and Windows PowerShell
  5.1 in CI.

### Changed

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
