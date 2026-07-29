# Cleanup Guard Cheatsheet — Which Guard For Which Merge Mode

The pre-deletion verification depends on how the PR was merged. Decide the
merge mode BEFORE merging, so you know which guard applies at cleanup time.

| Merge mode | Branch commits become ancestors of default? | Guard | Branch delete flag |
| --- | --- | --- | --- |
| `--merge` (merge commit) | Yes | 2a: `merge-base --is-ancestor <branch>` | `-d` (git double-checks) |
| `--squash` | No — a new single commit is created | 2b: MERGED + `mergeCommit` is-ancestor + `headRefOid` match | `-D` (guard replaces `-d`) |
| `--rebase` | No — commits are recreated with new hashes | 2b (same as squash) | `-D` (guard replaces `-d`) |

All three modes use the same exact-OID lease for remote branch deletion.
Immediately before merging in any mode, retain the PR head:

```bash
gh pr view <pr-number> --repo <owner>/<name> --json headRefOid -q .headRefOid
```

## Guard 2a — after `gh pr merge --merge`

```bash
git -C <repo> fetch origin
git -C <repo> merge-base --is-ancestor refs/heads/fix/<task> refs/remotes/origin/<default>; echo $?
# require exit 0, then:
git -C <repo> branch -d fix/<task>
```

`-d` is intentional: if anything was left unmerged, git itself refuses.
(Field-tested.)

Caveat: `-d` judges "merged" against the branch's upstream if set, otherwise
against HEAD. After the remote branch is deleted and pruned, with HEAD on an
older unrelated branch, `-d` can refuse `not fully merged` even for a
correctly merged PR (field-tested). Delete with `-D` only immediately after
the `--is-ancestor` check above exited 0 — never without it.

## Guard 2b — after `gh pr merge --squash` or `--rebase`

```bash
gh pr view <pr-number> --repo <owner>/<name> --json state,mergeCommit
# require: state == MERGED

# (i) the squash/rebase result landed on the default branch
git -C <repo> fetch origin
git -C <repo> merge-base --is-ancestor <mergeCommit-oid> refs/remotes/origin/<default>; echo $?   # require 0

# (ii) the merged PR head is exactly your local branch tip (no commits left behind)
git -C <repo> rev-parse refs/heads/fix/<task>    # require: equals headRefOid

# both hold → delete with explicit -D (the guard substitutes for -d)
git -C <repo> branch -D fix/<task>
```

## Remote branch deletion — all merge modes

Use the `headRefOid` retained immediately before merge; do not re-read a head
branch that may have moved afterward. Check the exact remote ref first:
`git -C <repo> ls-remote --exit-code --heads origin
refs/heads/fix/<task>`. Exit 2 means it is already absent, so skip deletion.
Exit 0 must contain exactly one record at `headRefOid`; anything else fails
closed.

When it matches, delete with an explicit expected-value lease:

```bash
git -C <repo> push --force-with-lease=refs/heads/fix/<task>:<headRefOid> origin :refs/heads/fix/<task>
```

The local guard commands fully qualify both `refs/heads/fix/<task>` and
`refs/remotes/origin/<default>`. Same-name tags would make the shorthand
`fix/<task>` or `origin/<default>` ambiguous and could make Git inspect a tag
instead of the branch or fetched remote-tracking ref being proved.

The server checks the expected OID atomically. If another session advances
the remote ref after `ls-remote`, deletion is rejected and its commit remains.
Do not shorten this to implicit `--force-with-lease`: a background fetch can
move the remote-tracking ref on which that form relies.
The exact-head and drift paths are covered with a disposable local bare
remote. Live GitHub exact-head deletion was measured on 2026-07-29 with
[PR #14](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/14):
the retained pre-merge OID matched the sole remote record, the explicit lease
was accepted, and a second `ls-remote` returned exit 2. Live
post-observation drift rejection is not yet verified.

The local topology and rejection paths are regression-tested with disposable
synthetic Git histories isolated from machine/user Git configuration, hooks,
signing, and `rebase.updateRefs`. Every ambient `GIT_*` variable is
snapshotted, cleared, and restored so repository and trace paths cannot escape
the fixture. The live GitHub squash path was measured on 2026-07-23 with
[PR #2](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/2):
`MERGED`, landed `mergeCommit`, unchanged tips matching `headRefOid`, and
guarded local/remote cleanup all passed. The live GitHub rebase path was
measured on 2026-07-26 with
[PR #5](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/5):
`MERGED`, a rewritten landed `mergeCommit`, original head outside the
default-branch ancestry, unchanged local and remote tips matching
`headRefOid`, guarded local `-D`, explicit remote deletion, and owned worktree
cleanup all passed while the main checkout stayed unchanged.

## What goes wrong when you mix them

- **2a after a squash**: `merge-base --is-ancestor refs/heads/fix/<task>` exits 1
  forever, even for a perfectly merged PR — the squash commit is a different
  object. You end up "unable to confirm" a merge that actually happened.
- **`branch -d` after a squash, upstream still exists**: git's
  merged-to-upstream logic lets the deletion through because the branch
  matches `origin/fix/<task>` — that is NOT an ancestor guarantee and proves
  nothing about the default branch.
- **`branch -d` after a squash, upstream already deleted**: refused forever
  with `not fully merged`, which tempts a blind `-D`. The 2b guard exists so
  that `-D` is a verified decision instead of a guess.

## Universal pre-deletion rules (any mode)

- First, in any mode, confirm the PR itself is merged:
  `gh pr view <pr-number> --repo <owner>/<name> --json state,mergedAt` must
  report `MERGED`. The mode-specific guards above supplement this check,
  never replace it.
- Run every check at execution time, immediately before the deletion — not
  earlier, and never afterwards. A post-hoc check cannot un-delete a branch.
- Remove the worktree before deleting the branch: a branch checked out in
  any worktree is refused by both `-d` and `-D` with `used by worktree` — a
  different (and correct) refusal, unrelated to merge state.
- Confirm the worktree/branch you are deleting is one this flow created.
- Confirm the main checkout's `git status --short` still matches your
  pre-work record.
- Remove any `node_modules` junction/symlink from the worktree before
  `git worktree remove`.
