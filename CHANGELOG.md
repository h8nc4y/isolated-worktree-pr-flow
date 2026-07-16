# Changelog

All notable changes to this project are documented in this file.

The format loosely follows Keep a Changelog conventions.

## Unreleased

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
