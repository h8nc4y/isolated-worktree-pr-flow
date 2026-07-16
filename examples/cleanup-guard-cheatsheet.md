# Cleanup Guard Cheatsheet — Which Guard For Which Merge Mode

The pre-deletion verification depends on how the PR was merged. Decide the
merge mode BEFORE merging, so you know which guard applies at cleanup time.

| Merge mode | Branch commits become ancestors of default? | Guard | Branch delete flag |
| --- | --- | --- | --- |
| `--merge` (merge commit) | Yes | 2a: `merge-base --is-ancestor <branch>` | `-d` (git double-checks) |
| `--squash` | No — a new single commit is created | 2b: MERGED + `mergeCommit` is-ancestor + `headRefOid` match | `-D` (guard replaces `-d`) |
| `--rebase` | No — commits are recreated with new hashes | 2b (same as squash) | `-D` (guard replaces `-d`) |

## Guard 2a — after `gh pr merge --merge`

```bash
git -C <repo> fetch origin
git -C <repo> merge-base --is-ancestor fix/<task> origin/<default>; echo $?
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
gh pr view <pr-number> --repo <owner>/<name> --json state,mergeCommit,headRefOid
# require: state == MERGED

# (i) the squash/rebase result landed on the default branch
git -C <repo> fetch origin
git -C <repo> merge-base --is-ancestor <mergeCommit-oid> origin/<default>; echo $?   # require 0

# (ii) the merged PR head is exactly your local branch tip (no commits left behind)
git -C <repo> rev-parse fix/<task>    # require: equals headRefOid

# both hold → delete with explicit -D (the guard substitutes for -d)
git -C <repo> branch -D fix/<task>
```

Honesty note: guard 2b is derived from git's squash/rebase semantics; it has
not yet been validated in live operation. Treat it as
designed-but-unverified.

## What goes wrong when you mix them

- **2a after a squash**: `merge-base --is-ancestor fix/<task>` exits 1
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
