---
name: isolated-worktree-pr-flow
description: >-
  Create a pull request from a temporary git worktree cut from origin's default
  branch when the main checkout is dirty, behind, or shared with other agents —
  without touching that checkout. Use on symptoms like "dirty main checkout I
  must not break", "behind N commits plus dirty WIP", "fresh worktree has no
  node_modules or .venv", "npm ci needed in a worktree", "gh pr merge
  --delete-branch failed its local post-processing", "fatal: ... is already
  checked out", "git worktree add -b", "merge-base --is-ancestor", "git branch
  -d refused: not fully merged", or two agent sessions colliding in one
  checkout. Covers merge-mode-aware cleanup guards (--merge vs
  --squash/--rebase), bounded CI polling, and concurrent-session collision
  detection and prevention.
---

# Isolated Worktree PR Flow

Procedure for shipping a change as a pull request from a temporary git
worktree cut from `origin`'s default branch, when the main checkout must not
be touched — because it is dirty (uncommitted WIP), behind the remote, or
shared with other agents. The flow covers worktree creation, fresh-worktree
dependency gaps, bounded CI polling, and merge-mode-aware cleanup guards.

## Why Worktree Isolation

When multiple agent sessions enter the same working directory (for example
through batch session launching), git's HEAD, current branch, and uncommitted
changes are shared state — each session moves the ground under the other. In
one measured incident, within a minute of one session creating a branch with
`git switch -c`, a second session in the same checkout branched from it,
committed, and merged to the default branch.

Detection pattern (confirms a collision in minutes):

1. Signs: files you did not write appear, or `git status` no longer matches
   the snapshot you took when your session started.
2. Timestamp scrutiny: `ls --time-style=full-iso` (or your platform's
   equivalent). Several files sharing the same millisecond means a git
   operation (checkout / merge / stash) wrote them, not manual or
   LLM-sequential edits.
3. `git reflog --date=iso` settles the timeline: who checked out, committed,
   or merged, and when.
4. If your agent environment provides a session-listing feature, use it to
   find other running sessions with the same working directory.

Yielding rules once a collision is confirmed:

- The side that committed first stays the writer. The latecomer stops
  writing: continuing to commit or switch branches moves the other session's
  HEAD and breaks both.
- The latecomer adds value as a verifier instead: adversarial review of the
  writer's output (doc claims vs code, re-running tests, pre-publish checks)
  and chat-only deliverables that touch no files.
- Clean up only intermediate refs you created yourself (for example an empty
  branch); never touch refs the other session has used.
- Append-only logs are safe for both sessions to write, under separate
  section headings.

Prevention: one repository = one writing session. When multiple agents must
work on the same repository, isolate each in its own worktree — which is what
this skill does. The cheapest detection habit is to re-compare `git status`
against your session-start snapshot right after you begin work.

## Portability

This flow was hardened on Windows (PowerShell plus Git Bash), but the `git`
and `gh` commands themselves are cross-platform. Where the shells differ,
both PowerShell and POSIX examples are given. CI includes PowerShell 7 jobs
for the synthetic cleanup guards and private-marker scanner on Ubuntu 24.04
and native macOS 15 in addition to the Windows hosts. All three jobs passed in
[PR #7 run 30216166105](https://github.com/h8nc4y/isolated-worktree-pr-flow/actions/runs/30216166105).
The Windows-specific pieces — directory junctions and their removal
semantics — have POSIX symlink equivalents noted inline.

## When To Use

- The main checkout is dirty (uncommitted WIP), behind the remote, or shared
  with other agents, and cutting a branch directly in it could break that
  WIP.
- Even for a small hygiene fix: if the existing checkout is behind by many
  commits and carries dirty WIP, an isolated worktree is the safer route
  (field-tested).
- A branch-per-task workflow is assumed (never commit directly to the
  default branch). This skill covers only the mechanics of where that branch
  lives: a temporary worktree outside the dirty checkout.

## Procedure

1. Check state, non-destructively. Run every `git` command with `-C <repo>`
   and every `gh` command with `--repo <owner>/<name>`, so nothing depends on
   the current directory — agent environments may reset the working directory
   between calls, and without `--repo`, `gh` fails with "not a git
   repository" when invoked outside the repo.

   ```powershell
   git -C <repo> status --short          # record pre-work WIP (verified unchanged at the end)
   git -C <repo> branch --show-current
   git -C <repo> fetch origin
   gh repo view <owner>/<name> --json defaultBranchRef -q .defaultBranchRef.name   # use the result as <default> below
   ```

   The same commands work unchanged in POSIX shells.

2. Create a temporary worktree from `origin`'s default branch, without
   touching the dirty checkout. Substitute `<default>` from step 1 — do not
   hardcode `main`; repositories whose default is `master` are still common.

   ```powershell
   git -C <repo> worktree add -b fix/<task> ..\_worktrees\<task> origin/<default>
   ```

   POSIX:

   ```bash
   git -C <repo> worktree add -b fix/<task> ../_worktrees/<task> origin/<default>
   ```

   Put the worktree somewhere confirmed writable. System-wide temp
   directories are sometimes not writable from sandboxed agent environments
   (field-tested). Prefer a `_worktrees/` directory next to the repository or
   your environment's designated temp directory, and before running anything
   heavy, write one probe file and delete it to confirm write access.

3. Keep the diff minimal. Edit (or copy in) only the files the task needs,
   inside the worktree. Do not carry the main checkout's untracked WIP over
   wholesale — upstream or other agents may add files with the same names,
   and extra files cause add/add conflicts at merge time or pollute the PR
   diff. If you must include a copy of an uncommitted dependency file from
   the base checkout, state in the PR body which side wins at merge time
   (field lesson: doing this explicitly avoided a bad auto-resolution).

4. Handle fresh-worktree dependency gaps. A new worktree has no
   `node_modules` and no virtualenv (field-tested).

   - Node: run `npm ci` in the worktree (requires a lockfile). For light
     verification only, a temporary link to the main checkout's
     `node_modules` also works — but remove the link before cleanup (safety
     condition 5). PowerShell junction:

     ```powershell
     New-Item -ItemType Junction -Path <worktree>\node_modules -Target <repo>\node_modules
     # Removal must delete only the link, never the target: use rmdir.
     cmd /c rmdir "<worktree>\node_modules"
     ```

     POSIX symlink:

     ```bash
     ln -s <repo>/node_modules <worktree>/node_modules
     # Remove the link itself with plain rm (no -r, no trailing slash).
     rm <worktree>/node_modules
     ```

   - Python: reuse the main repository's virtualenv interpreter and point it
     at the worktree's sources, running only the target tests. PowerShell:

     ```powershell
     $env:PYTHONPATH = "<worktree>\src"
     & <repo>\.venv\Scripts\python.exe -m pytest <worktree>\tests\<target_test>.py
     ```

     POSIX:

     ```bash
     PYTHONPATH=<worktree>/src <repo>/.venv/bin/python -m pytest <worktree>/tests/<target_test>.py
     ```

5. When verification passes: commit, push, and create the PR. Write the
   commit message to a file and pass it with `git commit -F <msgfile>` —
   inline multi-line messages are fragile under shell quoting, especially on
   Windows.

   ```powershell
   git -C <worktree> add <target files only>
   git -C <worktree> commit -F <msgfile>
   git -C <worktree> push -u origin fix/<task>
   gh pr create --repo <owner>/<name> --head fix/<task> ...
   ```

6. Wait for branch-protection CI with bounded polling. `gh pr checks
   --watch` is an unbounded wait — agent harnesses and approval layers may
   reject or hang on it (field-tested). Use one-shot checks with an attempt
   cap:

   ```powershell
   gh pr checks <pr-number> --repo <owner>/<name> --watch=false
   gh pr view <pr-number> --repo <owner>/<name> --json state,statusCheckRollup
   ```

   Bounded loop, POSIX. Where the harness blocks foreground `sleep` (Claude
   Code does), run the loop as a background task, or skip the loop and
   interleave one-shot checks between other pieces of work:

   ```bash
   for i in $(seq 1 10); do gh pr checks <pr-number> --repo <owner>/<name> --watch=false && break; sleep 30; done
   ```

   Bounded loop, PowerShell:

   ```powershell
   for ($i = 1; $i -le 10; $i++) {
     gh pr checks <pr-number> --repo <owner>/<name> --watch=false
     if ($LASTEXITCODE -eq 0) { break }
     Start-Sleep -Seconds 30
   }
   ```

   The right cap and interval depend on the repository's CI duration
   (unverified in general — tune per repository).

7. Merge — and decide the merge mode first, because it determines the
   pre-cleanup unmerged-work verification (safety condition 2):

   - `--merge` (merge commit): the branch commits become ancestors of the
     default branch, so verify with `merge-base --is-ancestor` and delete
     with `branch -d` (safety condition 2a; field-tested).
   - `--squash` / `--rebase`: the branch commits never become ancestors of
     the default branch, so `--is-ancestor` on the branch exits 1 forever,
     even after a fully successful merge. Use the "MERGED + headRefOid match"
     guard instead (safety condition 2b).

   ```powershell
   gh pr merge <pr-number> --repo <owner>/<name> --merge      # squash-policy repos: --squash, then use guard 2b
   gh pr view <pr-number> --repo <owner>/<name> --json state,mergedAt,mergeCommit
   ```

   Known behaviors around `gh pr merge` (field-tested):

   - If the local default branch is checked out in another worktree, `gh pr
     merge --delete-branch` run from inside the repo can fail during its
     local post-processing even though the remote merge succeeded. Running
     the merge with `--repo` from outside the repo skips local
     post-processing entirely, avoiding the failure class up front.
   - If a failure is reported anyway, check `gh pr view --json state` first —
     the remote side is often already `MERGED`. If so, finish the remaining
     local steps (branch deletion, worktree removal) manually after the
     safety conditions below.
   - `gh pr merge` run from inside the repo may fast-forward the current
     worktree to the default branch; seeing large updates from earlier PRs in
     its output is not an anomaly.

## Safety Conditions

Before any destructive step (worktree removal, branch deletion, prune), check
all of the following at execution time — run the verification BEFORE the
deletion, never after it. Skipping a pre-deletion check and "verifying
afterwards" defeats the guard: an unmerged-work mistake would surface only
once the branch is already gone (field lesson). In shared checkouts, state
can drift between when a step was approved and when it runs; if time has
passed, re-run the checks immediately before executing (field-tested).

1. `gh pr view <pr-number> --repo <owner>/<name> --json state,mergedAt`
   reports `MERGED`.
2. Merge-mode-matched unmerged-work verification. Do not mix the modes: after
   a squash, guard 2a never passes even for a correctly merged PR; and
   `branch -d` after a squash either slips through on merged-to-upstream
   logic (if `origin/fix/...` still exists — which is no ancestor guarantee)
   or is refused forever as "not fully merged" (if the upstream is gone).

   - **2a — `--merge` (merge commit) mode**:
     `git -C <repo> merge-base --is-ancestor fix/<task> origin/<default>`
     exits 0 (check `$LASTEXITCODE` in PowerShell, `echo $?` in POSIX
     shells). Delete the branch with `-d`, so git itself still refuses if
     anything was left unmerged (field-tested). Caveat: `-d` judges "merged"
     against the branch's upstream if one is set, otherwise against HEAD —
     so after the remote branch is deleted and pruned, and with the
     checkout's HEAD sitting on an older, unrelated branch, `-d` can refuse
     with `not fully merged` even though the PR merged correctly
     (field-tested). In that case deleting with `-D` is acceptable only
     immediately after the `--is-ancestor` check exited 0 — the same
     guard-then-`-D` shape as 2b; a `-D` without the guard stays forbidden.
   - **2b — `--squash` / `--rebase` mode**: fetch `state`, `mergeCommit`, and
     `headRefOid` via
     `gh pr view <pr-number> --repo <owner>/<name> --json state,mergeCommit,headRefOid`.
     Note that `mergeCommit` is a JSON object — the commit hash is its `oid`
     field (`-q .mergeCommit.oid` extracts it); `headRefOid` is a plain
     string. Then confirm both: (i)
     `git -C <repo> merge-base --is-ancestor <mergeCommit-oid> origin/<default>`
     exits 0, and (ii) `git -C <repo> rev-parse fix/<task>` equals
     `headRefOid`. Check (ii) is the squash-mode replacement for "no commits
     left behind": it proves the merged PR head is exactly your local branch
     tip. Only when both hold, delete with an explicit `git branch -D` (this
     guard substitutes for `-d`).
     Guard 2b's topology and rejection paths are covered by disposable
     synthetic Git histories in `scripts/test-cleanup-guards.ps1`. The test
     isolates system/global Git configuration, hooks, signing, and
     `rebase.updateRefs`; snapshots, clears, and restores every ambient
     `GIT_*` variable so repository/trace paths cannot escape the fixture; and
     constrains recursive cleanup to its generated direct temp child with
     OS-aware path comparison and reparse-point rejection. The live GitHub
     squash path was measured on 2026-07-23 with
     [PR #2](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/2):
     `MERGED`, landed `mergeCommit`, unchanged local and remote tips matching
     `headRefOid`, guarded local `-D`, and explicit remote deletion all passed.
     The live GitHub rebase path was measured on 2026-07-26 with
     [PR #5](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/5):
     `MERGED`, a rewritten landed `mergeCommit`, the original head outside the
     default-branch ancestry, unchanged local and remote tips matching
     `headRefOid`, guarded local `-D`, explicit remote deletion, and owned
     worktree cleanup all passed while the main checkout stayed unchanged.

3. The worktree and branch being deleted are ones this flow created — never
   another agent's or a human's.
4. The main checkout's WIP (`git status --short`) is unchanged from the
   record taken in step 1.
5. No `node_modules` link remains. PowerShell:
   `(Get-Item <worktree>\node_modules -ErrorAction SilentlyContinue).LinkType`
   returning `Junction` means remove it first with
   `cmd /c rmdir "<worktree>\node_modules"`. POSIX: `test -L
   <worktree>/node_modules && rm <worktree>/node_modules`. `node_modules` is
   normally git-ignored, so `git worktree remove` does not consider it in its
   clean check — and if a recursive delete follows the link into the target,
   it can destroy the main checkout's real `node_modules`. Whether a given
   platform's recursive deletion follows junctions or symlinks varies by
   tool and version (unverified) — remove the link explicitly instead of
   relying on it.

Only after all checks pass:

```powershell
git -C <repo> worktree remove ..\_worktrees\<task>
git -C <repo> worktree prune
git -C <repo> branch -d fix/<task>          # 2a (--merge) mode; on a not-fully-merged refusal apply the 2a caveat (verified is-ancestor, then -D); 2b mode uses -D only after its guard
git -C <repo> push origin --delete fix/<task>   # if the remote branch remains
git -C <repo> remote prune origin
```

(POSIX: same commands with `../_worktrees/<task>`.)

Troubleshooting removal:

- The cleanup order matters: remove the worktree before deleting the branch.
  A branch still checked out in any worktree is refused deletion by both
  `-d` and `-D` with `used by worktree` — that is git's protection working,
  and it is a different refusal than `not fully merged` (field-tested).
- If `git worktree remove` refuses because of untracked content, do not
  reach for `--force`. Identify what is actually there — a leftover link, a
  build artifact, a deliverable you forgot to move out — and handle each
  item, then retry.
- On Windows, if deleting the worktree directory fails with "permission
  denied", a lingering process handle (an editor, shell, or agent process
  still holding the directory) is a common cause. Wait for the handles to
  clear and retry — field experience: the same deletion succeeded later
  without any forcing.

## Do Not / Stop Conditions

- Never pull, reset, rebase, clean, or switch branches in the main checkout.
  Its dirty WIP may be another agent's in-progress work. Inspect remaining
  WIP read-only, for example with `git diff origin/<default>` (field-tested).
- Never archive, relocate, or delete other agents' or the owner's branches
  and WIP without approval.
- Stacked PRs: deleting a base branch with `--delete-branch` closes the
  descendant PRs (field-tested). Delay remote branch deletion while a stack
  is still open.
- A stale `index.lock` may be deleted only after confirming the path belongs
  to worktree metadata, nothing holds an exclusive open on it, and its
  creation time is old enough to rule out an active operation. Use
  `GIT_OPTIONAL_LOCKS=0` for the read-only confirmation commands
  (field-tested).
- If the same failure class does not improve after three attempts, stop and
  report. Cost, secret, and credential stop conditions always take
  precedence.

## Completion Checklist

- `gh pr view <pr-number> --repo <owner>/<name> --json state,mergeCommit`
  recorded `MERGED` and the merge commit.
- `git -C <repo> worktree list` shows no leftover temporary worktree.
- The work branch is gone locally and remotely (unless the repository's
  policy is to keep branches).
- The main checkout's `git status --short` matches the pre-work record
  exactly (WIP untouched).

## Reporting

- Start reports with a timestamp (date and time, in a stated timezone).
- Include: where the worktree was created, the PR URL, the merge mode and
  merge commit, the CI result (one-shot poll count and final state), what
  cleanup was performed, evidence that the main checkout is unchanged
  (status comparison), and open unknowns.
- Do not assert values you did not measure (CI durations, optimal poll caps)
  — write "unverified" instead.

## Provenance

This skill is distilled from repeated real-world agent operations on shared
Windows development machines — every rule above traces back to an observed
failure or a verified recovery, not to speculation. Wording like
"field-tested" marks behavior that was actually hit and worked around in
practice. Items that are not yet validated in live operation are explicitly
marked as unverified — notably platform-specific link-following behavior
during recursive deletion. Guard 2b's GitHub-side squash and rebase operations
are live-verified, and both local topologies and rejection paths have
synthetic regression coverage.
