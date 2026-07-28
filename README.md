# isolated-worktree-pr-flow

[![Validate](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/workflows/validate.yml/badge.svg)](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/workflows/validate.yml)

An agent skill for Claude Code and Codex: create pull requests from a
temporary git worktree cut from `origin`'s default branch when the main
checkout is dirty, behind, or shared with other agents — without ever
touching that checkout. Includes fresh-worktree dependency handling, bounded
CI polling, and merge-mode-aware cleanup guards.

## What It Solves

Agents (and humans) frequently need to ship a small fix from a repository
whose working checkout must not be disturbed:

- The checkout carries **dirty uncommitted WIP** — possibly another agent's
  in-progress work.
- The checkout is **behind the remote**, so branching from it would base the
  fix on stale history.
- **Multiple agent sessions share one checkout**, where HEAD, branch, and
  uncommitted state are shared — one measured incident had a second session
  branch from a one-minute-old branch, commit, and merge it while the first
  session was still working.

The safe answer is a temporary `git worktree` cut directly from
`origin/<default>`, used for exactly one PR, then removed under guard. The
non-obvious parts — which this skill documents from field experience — are:

- Fresh worktrees have **no `node_modules` / no virtualenv**, and the fixes
  (`npm ci`, junction/symlink, `PYTHONPATH`) each have sharp edges.
- `gh pr checks --watch` is an **unbounded wait** that agent harnesses may
  reject or hang on; polling must be bounded.
- The **cleanup guard depends on the merge mode**: `merge-base --is-ancestor`
  plus `branch -d` works after a merge commit (2a), but after a squash or
  rebase merge the branch is never an ancestor — you need the
  "MERGED + headRefOid match" guard (2b) and an explicit `-D`.
- Deleting the wrong thing at cleanup time is the main hazard; the skill's
  safety conditions are all pre-deletion checks.

## Who It Is For

- Claude Code users whose agents work on repositories with long-lived dirty
  checkouts or multiple concurrent sessions.
- Codex users running delegated tasks against shared repositories.
- Anyone scripting `git worktree` + `gh pr` automation who wants the failure
  modes documented before hitting them.

## Install

Clone the repository:

```bash
git clone https://github.com/h8nc4y/isolated-worktree-pr-flow.git
cd isolated-worktree-pr-flow
```

### Claude Code

Claude Code auto-invokes the skill when a task matches the `description`
frontmatter. Install for your user account on shells with POSIX syntax:

```bash
dest="${HOME}/.claude/skills/isolated-worktree-pr-flow"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Install for your user account from PowerShell:

```powershell
$dest = Join-Path $HOME '.claude\skills\isolated-worktree-pr-flow'
if (Test-Path -LiteralPath $dest) {
  throw "Install target already exists: $dest"
}
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
```

Notes:

- If you set `CLAUDE_CONFIG_DIR`, replace `~/.claude` with that directory.
- To scope the skill to a single project instead, copy `SKILL.md` to
  `.claude/skills/isolated-worktree-pr-flow/SKILL.md` inside that project's
  repository.

The existence guard is intentional: do not overwrite an already-installed
skill without reviewing the local copy first.

### Codex (agent skills)

Manual Codex-style skill install on shells with POSIX syntax:

```bash
dest="${HOME}/.agents/skills/isolated-worktree-pr-flow"
if [ -e "$dest" ]; then
  echo "Install target already exists: $dest"
else
  mkdir -p "$dest"
  cp SKILL.md "$dest/SKILL.md"
fi
```

Manual Codex-style skill install from PowerShell:

```powershell
$dest = Join-Path $HOME '.agents\skills\isolated-worktree-pr-flow'
if (Test-Path -LiteralPath $dest) {
  throw "Install target already exists: $dest"
}
New-Item -ItemType Directory -Path $dest | Out-Null
Copy-Item -LiteralPath .\SKILL.md -Destination (Join-Path $dest 'SKILL.md')
```

To scope the skill to a single project instead, copy `SKILL.md` to
`.agents/skills/isolated-worktree-pr-flow/SKILL.md` inside that repository —
Codex scans `.agents/skills` from the working directory up to the repository
root (per the official skills documentation).

If your agent reads skills from a different directory, check its
documentation and copy `SKILL.md` into the matching
`skills/isolated-worktree-pr-flow/` folder.

## Manual Use

Reach for the skill when you see one of these symptoms:

- You need to ship a fix but the main checkout is dirty, behind, or someone
  else's session is active in it.
- `git worktree add` failed with `fatal: '<branch>' is already checked out`.
- A fresh worktree fails to build or test because `node_modules` or the
  virtualenv is missing.
- `gh pr merge --delete-branch` reported a failure after the remote merge
  succeeded.
- `git branch -d` refuses with `not fully merged` after a squash or rebase
  merge.
- Files you did not write appear in your checkout, or `git status` no longer
  matches your session-start snapshot (concurrent-session collision).

Follow the procedure in [SKILL.md](SKILL.md): record the checkout's state,
cut a worktree from `origin/<default>`, keep the diff minimal, handle the
dependency gap, create the PR, poll CI with a bounded loop, merge with the
mode decided up front, and clean up only after the merge-mode-matched guard
passes.

## Synthetic Examples

- [Full flow walkthrough](examples/full-flow-walkthrough.md) — every command
  from worktree creation to guarded cleanup, PowerShell and POSIX.
- [Cleanup guard cheatsheet](examples/cleanup-guard-cheatsheet.md) — which
  guard (2a / 2b) applies to which merge mode, and what goes wrong when they
  are mixed.
- [Concurrent-session collision checklist](examples/concurrent-session-collision-checklist.md)
  — detect and resolve two sessions sharing one checkout.

The examples use placeholders only. Do not replace them with secrets, real
repository paths you cannot publish, or customer data in public issues.

## 日本語概要 (Japanese Overview)

main checkout が dirty（未コミット WIP あり）・behind・他エージェントと共有の
とき、その checkout に一切触らず、`origin` の default branch から一時 git
worktree を切って PR を作るための手順です。

- fresh worktree の依存欠如への対応（`npm ci` / `node_modules` への一時
  junction・symlink / `PYTHONPATH`）
- `gh pr checks --watch`（無制限待ち）を避けた bounded CI ポーリング
- merge 方式別の cleanup ガード: merge commit 方式は `merge-base
  --is-ancestor` + `branch -d`（2a）、squash / rebase 方式は「MERGED +
  headRefOid 一致」ガード + 明示的 `-D`（2b）
- 破壊操作の前に全チェックを実行時点で通す安全条件と、並行セッション衝突の
  検知・譲り方・予防

日本語の完全版は [docs/SKILL.ja.md](docs/SKILL.ja.md) にあります。インストールは
上記の手順どおり、`SKILL.md` を Claude Code なら
`~/.claude/skills/isolated-worktree-pr-flow/` へ、Codex なら
`~/.agents/skills/isolated-worktree-pr-flow/` へコピーしてください。

## Safety Notes

- Never pull, reset, rebase, clean, or switch branches in the main checkout;
  its dirty WIP may be someone else's in-progress work.
- All destructive cleanup steps (worktree removal, branch deletion, prune)
  run only after every safety condition passes at execution time, with the
  guard matched to the merge mode actually used.
- Never paste tokens, credentials, private logs, or customer data into PR
  bodies, commit messages, or public issues.

## Limitations

- The squash/rebase cleanup guard (2b) has disposable synthetic-Git coverage
  for its topology and rejection paths. Its live GitHub squash path was
  measured on 2026-07-23 with
  [PR #2](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/2):
  `MERGED`, landed `mergeCommit`, unchanged tips matching `headRefOid`, and
  guarded local/remote cleanup all passed. Its live GitHub rebase path was
  measured on 2026-07-26 with
  [PR #5](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/5):
  `MERGED`, a rewritten landed `mergeCommit`, original head outside the
  default-branch ancestry, unchanged local and remote tips matching
  `headRefOid`, guarded local `-D`, explicit remote deletion, and owned
  worktree cleanup all passed while the main checkout stayed unchanged.
- Whether recursive deletion follows directory junctions or symlinks varies
  by platform, tool, and version (unverified); the skill's rule is to remove
  links explicitly instead of relying on that behavior.
- The flow assumes `git` and the GitHub CLI (`gh`); other forges need
  equivalent commands for PR state and merge-commit queries.

## Non-Goals

- No automation scripts that run the flow for you. This repository is a
  written discipline with copy-adaptable commands, not a tool.
- No general git worktree tutorial; the focus is the dirty-checkout /
  shared-checkout PR case and its cleanup hazards.

## Validation

Run the full local validation from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\validate-oss-readiness.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-cleanup-guards.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-scan-private-markers.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\scan-private-markers.ps1
```

If `pwsh` is available, the same checks can be run with:

```powershell
pwsh -NoProfile -File .\scripts\validate-oss-readiness.ps1
pwsh -NoProfile -File .\scripts\test-cleanup-guards.ps1
pwsh -NoProfile -File .\scripts\test-scan-private-markers.ps1
pwsh -NoProfile -File .\scripts\scan-private-markers.ps1
```

On macOS, Linux, or any POSIX shell with PowerShell 7 (`pwsh`) installed:

```bash
pwsh -NoProfile -File ./scripts/validate-oss-readiness.ps1
pwsh -NoProfile -File ./scripts/test-cleanup-guards.ps1
pwsh -NoProfile -File ./scripts/test-scan-private-markers.ps1
pwsh -NoProfile -File ./scripts/scan-private-markers.ps1
```

The cleanup-guard regression test builds disposable local Git histories for
merge, squash, and rebase topology. It verifies the positive 2a/2b decisions
and the two 2b rejection paths without using GitHub, credentials, or a real
repository. Each Git invocation ignores system/global configuration, signing,
hooks, and `rebase.updateRefs`; it snapshots and clears every ambient `GIT_*`
variable before setting only its isolated config and non-interactive prompt
policy. This prevents repository/index/object redirection and trace output to
caller-selected paths, including future Git variables not yet known to the
test. Recursive cleanup requires an OS-aware, direct GUID-named child of the
temporary directory and rejects reparse points. CI executes the test with
both PowerShell 7 and Windows PowerShell 5.1.

The private-marker self-test also retains the PowerShell host that starts it,
so the `powershell` and `pwsh` commands above are distinct compatibility
measurements. GitHub Actions runs that full scanner suite under both Windows
hosts and under PowerShell 7 on Ubuntu 24.04 and native macOS 15. All three
jobs passed in [PR #7 run 30216166105](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30216166105).
The first bounded-process invocation passes the exact binary
byte sequence `00/80/FF` through stdin and requires the same sequence
independently on stdout and stderr.

The scanner's own per-run Git isolation root is recursively removed only
when it is still a regular, non-reparse directory whose exact prefix and
32-hex GUID name identify it as a direct child of the OS temporary directory.
A separate per-run owner marker is checked both after the first inspection
and immediately before recursive deletion. A missing, renamed, nested, leaf,
regular-directory replacement, junction, or symbolic-link replacement fails
closed instead of widening recursive cleanup. The self-test exercises the
valid, wrong-name, nested, owner-replacement, and reparse-point paths with
synthetic temporary fixtures and verifies that an external target remains
intact.

Git-backed marker scanning requires the exact repository root. Git proves
that boundary semantically with `--is-inside-work-tree` plus an empty
`--show-prefix`; it does not compare absolute path spellings, which may alias
the same physical directory on macOS. Each Git child receives a cloned,
sanitized environment with ambient and unknown `GIT_*`,
user/system configuration, hooks, attributes, excludes, templates, filters,
prompts, replacement objects, lazy fetches, and trace destinations disabled.
The caller's environment is never mutated. On Windows, the executable is
created suspended with only its three standard streams inheritable, assigned
to a kill-on-close Job, and resumed only after assignment. On POSIX, it starts
in a dedicated session/process group before its first instruction; cleanup
signals that entire group with direct `kill(2)` and treats only success or
`ESRCH` as a successful stop.

The scan covers both regular stage-0 index blobs and their regular worktree
files as separate provenance sources. One binary-safe `git cat-file --batch`
reads unique staged blobs, and byte-identical final raw `ls-files -z --stage`
and `ls-files -z --stage --debug` snapshots are required immediately before
reporting. Conflicts, intent-to-add (present or missing), gitlinks, symlinks,
reparse points, path escape, missing or concurrently changing files,
repository subdirectories, malformed Git output, and tracked
`.private-markers.local` fail closed. Non-Git fallback includes hidden text
but excludes both nested `.git` directories and leaf `.git` control files.

Text candidates include common source/document/config extensions,
extensionless files, `.env`, `.env.*`, `*.env`, `.npmrc`, `.pem`, and `.key`;
unlisted extensions remain binary-safe skips. A scan-wide deadline plus
independent process-stream, entry, file-byte, total-byte, line, match,
per-file finding, total finding, and diagnostic-width limits bound hostile
input. The same deadline is rechecked after finding serialization and
immediately before either failure or success output. Diagnostics escape
control/format, bidi, zero-width, and Unicode
line/paragraph separator characters. An unresolvable user path produces only
a fixed failure code and never replays the path or PowerShell exception
framing. The complete failure prefix, TSV header, rows, and explicit LF
separators are serialized once and capped at 64 KiB of actual UTF-8 bytes;
over-limit output collapses to a fixed diagnostic without a partial table.
Passing remains a best-effort marker result, not proof that content is
secret-free.

Also run Git whitespace checks on your working changes before publishing:

```bash
git diff --check
```

The GitHub Actions workflow is configured to run the readiness validator,
cleanup guards, scanner self-test, repository scan, and committed-tree
whitespace check on pull requests and pushes to `main`. Windows covers
PowerShell 7 and Windows PowerShell 5.1; Ubuntu 24.04 and native macOS 15 are
covered by PowerShell 7. Every job pins `actions/checkout` to the reviewed
`v7.0.1` commit `3d3c42e5aac5ba805825da76410c181273ba90b1`, and the readiness
validator requires `persist-credentials: false` in the same checkout step.
A missing, extra, misnested, or different checkout revision or credential
policy fails validation in any job. The first full native macOS job passed
its readiness, cleanup, scanner self-test, repository scan, and whitespace steps in
[PR #7 run 30216166105](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30216166105).

For the latest verified maintenance state, decisions, boundaries, and next
step, read [HANDOFF.md](HANDOFF.md).

## Contributing

Contributions are welcome when they make the flow safer, clearer, or easier
to verify. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull
request.

Keep all examples synthetic. Do not include tokens, credentials, private
repository names, internal absolute paths, or customer data.

For local-only private markers, create an untracked `.private-markers.local`
file with one literal marker per line, or set
`ISOLATED_WORKTREE_PR_FLOW_PRIVATE_MARKERS` with newline-separated markers.
The scanner reads these values but does not print the matched marker, and it
fails closed if `.private-markers.local` appears in the Git index.

## Security

If you find unsafe guidance or accidental private-data exposure, follow
[SECURITY.md](SECURITY.md) and use private reporting for sensitive details.

## License

MIT. See [LICENSE](LICENSE).
