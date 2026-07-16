# Full Flow Walkthrough (Synthetic)

Every command of one complete pass: state check → worktree → change → PR →
bounded CI poll → merge → guarded cleanup. All names are placeholders
(`<repo>` is the absolute path of the existing checkout, `<owner>/<name>` is
the GitHub repository, `<task>` is a short slug for this piece of work).

This walkthrough uses the `--merge` (merge commit) mode, so cleanup uses
guard 2a. See the [cleanup guard cheatsheet](cleanup-guard-cheatsheet.md) for
the squash/rebase variant (guard 2b).

## 0. Record the starting state (non-destructive)

```bash
git -C <repo> status --short            # save this output; compared again at the end
git -C <repo> branch --show-current
git -C <repo> fetch origin
gh repo view <owner>/<name> --json defaultBranchRef -q .defaultBranchRef.name
# → suppose it prints: main   (used as <default> below; never hardcode)
```

## 1. Cut the worktree from origin's default branch

POSIX:

```bash
git -C <repo> worktree add -b fix/<task> ../_worktrees/<task> origin/main
```

PowerShell:

```powershell
git -C <repo> worktree add -b fix/<task> ..\_worktrees\<task> origin/main
```

Confirm the location is writable before doing anything heavy:

```bash
touch ../_worktrees/<task>/.write-probe && rm ../_worktrees/<task>/.write-probe
```

## 2. Make the minimal change

Edit only the files the task needs, inside `../_worktrees/<task>`. Do not
copy the main checkout's untracked WIP into the worktree.

If the project needs dependencies to verify:

```bash
# Node (lockfile present):
(cd ../_worktrees/<task> && npm ci && npm test)

# Python (reuse the main checkout's virtualenv):
PYTHONPATH=../_worktrees/<task>/src <repo>/.venv/bin/python -m pytest ../_worktrees/<task>/tests/test_<task>.py
```

## 3. Commit, push, open the PR

```bash
printf 'fix: <one-line summary>\n\n<why this change is safe and minimal>\n' > /tmp/msg-<task>.txt
git -C ../_worktrees/<task> add <target-files-only>
git -C ../_worktrees/<task> commit -F /tmp/msg-<task>.txt
git -C ../_worktrees/<task> push -u origin fix/<task>
gh pr create --repo <owner>/<name> --head fix/<task> \
  --title 'fix: <one-line summary>' \
  --body 'What / why / how verified. State merge-priority explicitly if any copied WIP file is included.'
# → suppose it prints PR number 42
```

## 4. Poll CI with a bounded loop (never --watch)

```bash
for i in $(seq 1 10); do
  gh pr checks 42 --repo <owner>/<name> --watch=false && break
  sleep 30
done
gh pr view 42 --repo <owner>/<name> --json state,statusCheckRollup
```

## 5. Merge (mode decided up front: merge commit)

```bash
gh pr merge 42 --repo <owner>/<name> --merge
gh pr view 42 --repo <owner>/<name> --json state,mergedAt,mergeCommit
# → require: "state": "MERGED"
```

## 6. Guarded cleanup (guard 2a for merge-commit mode)

Every check runs BEFORE any deletion:

```bash
# (1) PR is merged
gh pr view 42 --repo <owner>/<name> --json state,mergedAt

# (2a) branch is an ancestor of the updated default branch
git -C <repo> fetch origin
git -C <repo> merge-base --is-ancestor fix/<task> origin/main; echo $?   # require 0

# (4) main checkout WIP unchanged vs step 0 record
git -C <repo> status --short

# (5) no leftover node_modules link in the worktree
test -L ../_worktrees/<task>/node_modules && rm ../_worktrees/<task>/node_modules
```

Only after all checks pass:

```bash
git -C <repo> worktree remove ../_worktrees/<task>
git -C <repo> worktree prune
git -C <repo> branch -d fix/<task>
git -C <repo> push origin --delete fix/<task>
git -C <repo> remote prune origin
```

## 7. Final assertion

```bash
git -C <repo> worktree list          # no temporary worktree left
git -C <repo> status --short         # identical to the step-0 record
```

Report: worktree location, PR URL, merge mode + merge commit, CI poll count
and final state, cleanup performed, and the status comparison evidence.
