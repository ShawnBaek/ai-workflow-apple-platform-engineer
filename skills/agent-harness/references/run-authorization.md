# One-shot run authorization

Use `templates/run-authorization.json` when the user wants an approved task to
continue through PR delivery, or an explicitly selected TestFlight target,
without routine prompts at every green-path step.

The authorization is a finite capability envelope, not a general “yes.” Bind
it to the exact repository fingerprint, canonical path, redacted remote, base
SHA, approved branch, acceptance IDs, allowed paths, Spec Kit snapshot (when
used), attempt/time bounds, GitHub objects, delivery target, and single-use
action grants with a visible structured operation descriptor, its canonical
SHA-256 constraint, canonical resource key, delivery phase, idempotency key, and
expiry. Static writes use literal descriptors. Outputs known only after
implementation use a versioned deterministic policy bound to reviewed patch,
commit, and evidence inputs; they are not represented as a pre-known body or
artifact hash. The checker also validates each descriptor's semantics: a push
must set `force: false`, Issue/Project transitions name the exact state,
commit paths match the live reviewed stage, PR creation binds a safe base and
the approved head with `draft: false`, waits equal the approved time/retry
bounds, and distribution/read-back names only the authorized internal group.

## Three delivery targets

| Target | Terminal evidence |
| --- | --- |
| `pr_ready` | remote SHA, PR, published evidence, required checks, Issue/Project reconciliation or recorded partial failure |
| `testflight_uploaded` | `pr_ready` plus verified archive hash, accepted upload, bounded processing terminal state, exact build read-back |
| `testflight_distributed` | uploaded target plus distribution to only the named internal group IDs and membership/build read-back |

TestFlight continues through `contracts/testflight-workflow.json`; it does not
change the PR workflow's terminal. App Review, external beta review answers,
production release, and merge are not delivery targets here.

## One prompt without weaker guards

Where project policy permits, one explicit user response may approve all exact
records represented by the envelope. Record derived plan, branch, repository,
and external-write approvals against the same immutable authorization hash
instead of prompting again for the same unchanged fact.

An upstream/global policy may require a later confirmation after the branch or
artifact exists. This adapter cannot weaken that rule; satisfy it and link the
new record. Never label a stricter two-gate repository as one-shot by silently
skipping its second gate.

Before each action, run `scripts/check_authorization.py` with the current exact
request. It recomputes live repository and Spec Kit state, verifies the private
checkpoint remains append-only, matches the operation descriptor/digest and
canonical lease, checks a fresh guarded ASC observation for Apple actions, and
atomically appends a single-use reservation before returning authority. The
external writer must use that exact descriptor while the same unexpired lease
remains active and then append the result against the reservation.

The envelope may bind the approved feature-branch name before that branch is
created, but no granted external action runs until the writer lease has prepared
the branch from the bound base and a live read-only observation proves the exact
root, sanitized remote, base ancestry, and checked-out branch.

Stop as `blocked` when repository/base/branch, staged or outgoing paths, Spec Kit
snapshot/checkpoint, account/team/app/bundle/platform/live build, group, target,
operation descriptor, grant, idempotency key, expiry, lease, or consumed state
differs. Reapproval creates a new envelope; do not edit the old one. A later
repository confirmation required by global policy remains a separate exact
ledger approval for the first commit/push; one-shot authorization cannot erase
that gate.

## Permanently excluded authority

- force push, merge, and auto-merge;
- ruleset, branch-protection, or credential-scope changes;
- App Review submission or production release;
- signing certificate, profile, capability, or bundle-ID mutation;
- destructive cleanup, runtime deletion, or service termination;
- invented compliance, encryption, privacy, agreement, or review answers.

An exact pre-authorized internal TestFlight distribution is not an arbitrary
auto-confirm. It is permitted only when the action grant and named group match;
otherwise it blocks without switching accounts or expanding credentials.
