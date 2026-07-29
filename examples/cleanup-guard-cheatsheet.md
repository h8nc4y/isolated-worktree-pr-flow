# Cleanup Guard Cheatsheet — Which Guard For Which Merge Mode

The pre-deletion verification depends on how the PR was merged. Decide the
merge mode BEFORE merging, so you know which guard applies at cleanup time.

| Merge mode | Branch commits become ancestors of default? | Guard | Local deletion |
| --- | --- | --- | --- |
| `--merge` (merge commit) | Yes | 2a: `merge-base --is-ancestor <branch>` | `-d` (git double-checks) |
| `--squash` | No — a new single commit is created | 2b: MERGED + `mergeCommit` is-ancestor + `headRefOid` match | `remove-local-branch-cas.ps1` |
| `--rebase` | No — commits are recreated with new hashes | 2b (same as squash) | `remove-local-branch-cas.ps1` |

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
correctly merged PR (field-tested). After the `--is-ancestor` check above
exited 0, use the expected-OID CAS below instead of a blind `-D`.

## Guard 2b — after `gh pr merge --squash` or `--rebase`

```bash
gh pr view <pr-number> --repo <owner>/<name> --json state,mergeCommit
# require: state == MERGED

# (i) the squash/rebase result landed on the default branch
git -C <repo> fetch origin
git -C <repo> merge-base --is-ancestor <mergeCommit-oid> refs/remotes/origin/<default>; echo $?   # require 0

# (ii) the merged PR head is exactly your local branch tip (no commits left behind)
git -C <repo> rev-parse refs/heads/fix/<task>    # require: equals headRefOid
```

## Expected-OID local deletion — guard 2b and forced guard 2a fallback

Before constructing a branch name, require `<task>` to match
`\A[a-z0-9-]+\z`. Remove this flow's worktree first, then invoke the repository's
checked-in helper with the exact pre-merge PR head:

```powershell
pwsh -NoProfile -File ./scripts/remove-local-branch-cas.ps1 `
  -Repository <repo> `
  -TaskSlug <task> `
  -ExpectedHeadOid <headRefOid>
```

The helper creates `codex-isolated-worktree-cleanup.lock` in Git's common
directory with one nonblocking `CreateNew` attempt. Linked worktrees therefore
share the lock. The lock carries a random owner nonce; ownership is checked
before destructive phases and again in `finally`. Active, stale/uncertain, and
nonce-mismatched locks preserve both the lock and branch.

Every helper Git process clears all ambient `GIT_*`, applies only isolated
global/system-config and non-interactive prompt controls, and restores the
caller's exact environment in `finally`. Git routing variables therefore
cannot redirect the requested repository.
Production use is limited to a fresh CLI process. The helper resolves `git` as
an application, retains one existing absolute `git`/`git.exe` path, and
module-qualifies critical PowerShell built-ins. A closure captures reviewed
helper-function identities, rejects same-name aliases, and rechecks identity
after synchronous test hooks. Dot-source/test hooks are trusted harnesses;
adversarial asynchronous same-runspace mutation is outside this cooperative
protocol.

Inside the critical section, the helper creates a nonce-derived
`--no-checkout` guard worktree using short `fix/<task>` only to acquire Git's
native branch occupancy. It then requires one porcelain record binding the
exact task-owned path to fully qualified `refs/heads/fix/<task>`, no competing
record, a non-reparse root containing only a regular `.git` marker, and that
marker's exact common-directory metadata target. Ordinary `worktree add` and
`switch` calls are blocked while the guard is held.

The helper rechecks the fully qualified ref against `headRefOid`. Existing
`branch.fix/<task>` config is renamed to the owner-only
`branch.codex-cleanup-<nonce>` section and compared exactly, but then the
helper refuses CAS. Git config has no atomic expected-value section deletion,
so query followed by removal could delete a same-nonce writer's newer payload.
After the last pre-CAS hook, the helper acquires Git's standard common-directory
`config.lock` with one owner-nonce `CreateNew` attempt. It holds exact
root/path/reparse/handle/path-nonce ownership across the final config query,
CAS, post-CAS checks, and final checks. Ordinary Git config writers are blocked;
pre-existing or uncertain locks are preserved. Only a config-free branch
proceeds to the internal
`update-ref -d refs/heads/fix/<task> <headRefOid>` compare-and-delete.

If a second actor moves the local ref from H to R before the CAS, deletion is
rejected and R and its reflog remain. On config-free success, the helper
requires `reflog exists refs/heads/fix/<task>` to report absence. A same-name
branch created after CAS is not treated as owner state and remains intact;
ordinary config recreation is excluded while `config.lock` is held.

Guard cleanup tries normal `git worktree remove` first. An exact-path
`--force` retry is allowed after the CAS outcome is known, or after a pre-CAS
refusal only while the branch still equals `headRefOid`. Every owner, record,
marker, path, and `.git`-only invariant must be revalidated.
Unexpected entries or metadata drift preserve the guard and cleanup lock; the
helper does not try another branch deletion. Owner config is compared exactly
after rename and immediately before the mandatory config-bearing CAS refusal.
Automatic rename-back and temporary-section removal are both forbidden.
The attributable temporary config, guard, and lock remain for explicit
recovery. If another actor recreates the original branch config or writes a
new payload to the same nonce section, no payload is automatically deleted.

The owner lock is cooperative rather than a Git-wide mutex; the guard adds
Git-native protection for ordinary checkouts, while the standard `config.lock`
excludes ordinary config writers during the final decision. Direct plumbing can
still bypass the cooperative cleanup protocol. Disposable fixtures expose 211
assertions on PowerShell 7 and Windows
PowerShell 5.1, covering existing/interleaved checkout rejection, ordinary
add/switch blocking, ref drift, post-CAS recreation, unexpected guard entries,
ambient Git redirection, lock contention/staleness, owner mismatch,
config-bearing CAS refusal, targeted same-nonce config drift,
standard config-writer blocking, configless-to-config races,
pre-existing/reparse/replaced/content-drift config locks, ambient
alias/function replacement refusal, observation-to-rename config drift, and
pre-CAS owner-config recovery conflict. Live GitHub local-CAS use is not yet
verified.

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
the fixture; ordinal snapshot keys preserve case-variant names on Linux and
macOS. The live GitHub squash path was measured on 2026-07-23 with
[PR #2](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/2):
`MERGED`, landed `mergeCommit`, unchanged tips matching `headRefOid`, and
guarded local/remote cleanup all passed. The live GitHub rebase path was
measured on 2026-07-26 with
[PR #5](https://github.com/h8nc4y/isolated-worktree-pr-flow/pull/5):
`MERGED`, a rewritten landed `mergeCommit`, original head outside the
default-branch ancestry, unchanged local and remote tips matching
`headRefOid`, the then-current guarded local deletion, explicit remote
deletion, and owned worktree cleanup all passed while the main checkout stayed
unchanged.

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
  that an expected-OID CAS is a verified compare-and-delete instead of a
  guess. A later local commit must survive.

## Universal pre-deletion rules (any mode)

- First, in any mode, confirm the PR itself is merged:
  `gh pr view <pr-number> --repo <owner>/<name> --json state,mergedAt` must
  report `MERGED`. The mode-specific guards above supplement this check,
  never replace it.
- Run every check at execution time, immediately before the deletion — not
  earlier, and never afterwards. A post-hoc check cannot un-delete a branch.
- Remove this flow's worktree before deleting the branch. Porcelain `branch -d`
  refuses a checked-out branch with `used by worktree`; the helper then holds
  its own exact, nonce-derived guard worktree across config isolation, CAS,
  recreation checks, and owner cleanup.
- Confirm the worktree/branch you are deleting is one this flow created.
- Confirm the main checkout's `git status --short` still matches your
  pre-work record.
- Remove any `node_modules` junction/symlink from the worktree before
  `git worktree remove`.
