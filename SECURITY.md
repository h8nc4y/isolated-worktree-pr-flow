# Security Policy

This repository documents a git worktree / pull-request workflow. It should
never contain secrets, but its guidance drives agents through destructive
git operations (worktree removal, branch deletion), so unsafe guidance is
treated as a security problem too.

## Supported Versions

The `main` branch is the supported version. Tagged releases receive fixes
through new tags on `main`.

## Reporting A Vulnerability

Use GitHub private vulnerability reporting for:

- A real secret, credential, or private identifier accidentally committed to
  this repository.
- Guidance that could cause agents to destroy user work (for example a
  cleanup guard that passes when it must not), leak private data, or run
  destructive commands outside the flow's scope.
- A validation gap that allows unsafe public examples.

Do not open a public issue containing tokens, credentials, private keys,
OAuth material, customer data, raw secret-bearing logs, or private
repository names and internal paths.

## Public Issue Safety

Public issues may include:

- Symptom class, such as "cleanup guard false pass" or "worktree removal
  refused".
- Sanitized command classes, such as `merge-base --is-ancestor` exit codes
  or `gh pr view` state values, without private paths.
- Placeholder repository, branch, and file names.

Public issues must not include:

- Secret values or secret-display command output.
- Private repository names, internal absolute paths, hostnames, or customer
  data.
- Raw agent transcripts that contain any of the above.

## Scanner Coverage

The private-marker scanner (`scripts/scan-private-markers.ps1`) is a
best-effort safety net, not a guarantee. It scans regular stage-0 index blobs
and regular tracked worktree files as separate provenance sources for a
curated set of secret prefixes (GitHub, OpenAI, AWS, GCP, Slack, Stripe, PEM
key blocks, and similar), private-looking absolute Windows paths,
non-allowlisted GitHub repository URLs, and configured local markers. Matches
are always redacted. Text candidates include common source/document/config
extensions, extensionless files, dotenv names, `.npmrc`, `.pem`, and `.key`;
unlisted extensions are skipped without text decoding. It does not detect
every possible secret format and is no substitute for keeping real
credentials out of the repository. Treat a passing scan as "no known marker
found," not "definitely safe."

Git-backed enumeration runs in bounded child processes with a cloned,
sanitized environment and isolated configuration. Ambient and future
`GIT_*`, repository/index/object redirection, config injection, hooks,
attributes, excludes, templates, filters, prompts, tracing, replacement
objects, and lazy promisor fetches are not inherited. The scanner never
mutates its caller's environment. It requires Git's exact worktree root,
proved by an exact `true` worktree record and an empty root-relative prefix
instead of an absolute path spelling. It fails closed on malformed Git
output, repository subdirectories, `.git` directories, bare repositories,
conflicts,
intent-to-add entries, gitlinks, symlinks, reparse points, path escape,
missing or changing worktree files, and tracked `.private-markers.local`.
Non-Git fallback is allowed only when Git proves the path is not a repository
or Git is unavailable with no `.git` marker in the target ancestry; nested
and leaf `.git` controls are excluded.

Unique index blobs share one binary-safe `git cat-file --batch` exchange.
Immediately before reporting, raw `ls-files -z --stage` and
`ls-files -z --stage --debug` snapshots must match their initial bytes
exactly, including flags. A scan-wide deadline and independent
process-stream, entry, per-file byte, total byte, line, regex-match, per-file
finding, total finding, and diagnostic-width limits bound hostile input. The
complete finding table uses explicit LF, is encoded once, and must fit within
64 KiB of actual UTF-8 bytes before any row is emitted. After serialization,
the scan-wide deadline is checked again immediately before failure output;
the clean path performs the same check immediately before success output.

On Windows, each child is created suspended with a three-handle
stdin/stdout/stderr inheritance allowlist, assigned to a per-command
kill-on-close Job, and resumed only after assignment. This closes the
start-before-assignment descendant race. On POSIX, each child enters a
dedicated session/process group before its first instruction. Cleanup signals
the whole group with `kill(2)` and accepts only success or `ESRCH`; permission
and other signal failures remain fail closed.

The scanner removes its own Git isolation root only after revalidating an
OS-aware direct-child boundary, the exact project prefix plus 32-hex GUID
name, a separate per-run owner marker, and a regular non-reparse directory.
Root attributes and ownership are reacquired immediately before recursive
deletion. Missing, leaf, nested, different-directory, junction, or
symbolic-link replacements fail closed before recursive deletion.

Before output, control/format characters, bidi controls, zero-width
characters, and Unicode line/paragraph separators in diagnostic fields are
escaped. Missing or otherwise unresolvable user paths emit only a fixed code,
without the supplied path or raw PowerShell error framing. Process byte
limits count actual stdin/stdout/stderr bytes, including prefixes and the
platform newline.

## Response Expectations

Maintainers should acknowledge actionable security reports when available,
remove or redact unsafe public material, and prefer guidance that reduces
data-exposure and work-destruction risk. If real exposure is possible,
rotate the affected secret outside this public repository and document only
the remediation status.
