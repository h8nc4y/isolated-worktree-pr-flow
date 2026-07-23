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

- Recorded live GitHub squash-merge cleanup evidence from
  [PR #2](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/2):
  `MERGED` state, landed `mergeCommit`, unchanged local and remote tips
  matching `headRefOid`, guarded local `-D`, and explicit remote-branch
  deletion. Live GitHub rebase-merge cleanup remains unverified.

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
