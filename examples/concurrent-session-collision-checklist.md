# Concurrent-Session Collision Checklist (Synthetic)

Use this when you suspect another agent session (or a human) is working in
the same checkout as you. Goal: confirm or rule out the collision in
minutes, then yield safely instead of fighting over HEAD.

## 1. Notice the signs

- [ ] A file appeared that you did not write.
- [ ] `git status` no longer matches the snapshot you took when your session
      started.
- [ ] Your branch, HEAD, or staged set changed without your action.

Any one of these → continue below. None → resume work (and keep taking a
`git status --short` snapshot at session start; re-checking it right after
starting work is the fastest detection habit).

## 2. Confirm via timestamps

```bash
ls --time-style=full-iso -la <suspicious-directory>
```

- [ ] Several files share the **same millisecond** → a git operation
      (checkout / merge / stash) wrote them. Manual edits and LLM-sequential
      writes do not produce identical-millisecond clusters.

## 3. Settle the timeline

```bash
git -C <repo> reflog --date=iso | head -20
```

- [ ] Identify which checkouts / commits / merges happened, and when,
      relative to your own actions.

## 4. Identify the other session

- [ ] If your agent environment provides a session-listing feature, list
      running sessions and look for another one with the same working
      directory.
- [ ] Otherwise infer from reflog actor/time plus whatever session records
      your environment keeps.

## 5. Yield by the first-committer rule

- [ ] Whoever committed first is the **writer**. If that is not you, STOP
      writing: no more commits, no branch switches — each one moves the
      other session's HEAD.
- [ ] Add value as the **verifier** instead:
  - Adversarial review of the writer's output (doc claims vs code, re-run
    tests, pre-publish checks).
  - Chat-only deliverables (review reports, handoff prompts) that touch no
    files.
- [ ] Clean up only intermediate refs **you** created (for example an empty
      branch you abandoned). Never touch refs the other session has used.
- [ ] Append-only logs may be written by both sessions, under separate
      section headings.

## 6. Prevent the next one

- [ ] One repository = one writing session. Avoid batch-launching several
      sessions into the same project directory.
- [ ] If multiple agents genuinely must work on one repository, give each an
      isolated worktree — the procedure in [SKILL.md](../SKILL.md).
- [ ] Keep the session-start `git status --short` snapshot habit.
