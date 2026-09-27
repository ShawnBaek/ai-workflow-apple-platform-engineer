# One-shot run authorization

Use `templates/run-authorization.json` when the user wants an approved task to
continue through PR delivery, or an explicitly selected TestFlight target,
without routine prompts at every green-path step.

The authorization is a finite capability envelope, not a general “yes.” Bind
it to the exact repository fingerprint, canonical path, redacted remote, base
SHA, selected task branch, acceptance IDs, allowed paths, Spec Kit snapshot (when
used), attempt/time bounds, GitHub objects, delivery target, and single-use
action grants with a visible structured operation descriptor, its canonical
SHA-256 constraint, canonical resource key, delivery phase, idempotency key, and
expiry. Static writes use literal descriptors. Outputs known only after
implementation use a versioned deterministic policy bound to reviewed patch,
commit, and evidence inputs; they are not represented as a pre-known body or
artifact hash. The checker also validates each descriptor's semantics: a push
must set `force: false`, Issue/Project transitions name the exact state, a
direct Issue target is the bound Issue (consumers of a new feature Issue derive
their target from its create grant), PR
creation binds a safe base and the approved head with `draft: false`, waits
equal the approved time/retry bounds, and distribution/read-back names only the
authorized internal group. A commit descriptor's `paths` is the approved path
scope, not a file list: each entry lies within `allowed_paths` and uses the same
prefix rule. The commit request must name exactly the live reviewed staged set,
in any order, and every staged path must fall within that scope.

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

Select the task-derived branch name before preparing the envelope; naming alone
does not need a separate prompt. Pre-existing changes follow the read-only
summary and handling decision in [branch policy](../../git-workflow/references/branch-policy.md).
Approval for that handling is not permission to publish or broaden the envelope.

Where project policy permits, one explicit user response may approve all exact
records represented by the envelope. Record derived plan, repository,
and external-write approvals against the same immutable authorization hash
instead of prompting again for the same unchanged fact.

An upstream/global policy may require a later confirmation after the branch or
artifact exists. This adapter cannot weaken that rule; satisfy it and link the
new record. Never label a stricter two-gate repository as one-shot by silently
skipping its second gate.

Before each action, run `apple-verify authorize` with the current exact
request. It recomputes live repository and Spec Kit state, verifies the private
checkpoint remains append-only, matches the operation descriptor/digest and
canonical lease, checks a fresh guarded ASC observation for Apple actions, and
atomically appends a single-use reservation before returning authority. The
external writer must use that exact descriptor while the same unexpired lease
remains active and then append the result against the reservation.

Live health must keep the approved profile, targets, skill bundle and
coordinator identity. Its status may recover from `degraded` to `healthy`
without reapproval, but reservation and dispatch both block when it falls below
the approved status.

The envelope may bind the selected feature-branch name before that branch is
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

## Dispatch an external write

Every granted action uses its own single-use reservation from `authorize`, such
as a commit, push, Issue, PR, comment, Project update, evidence publication,
checks wait, or TestFlight upload, distribution, processing wait or readback. Run
`apple-verify verify-reservation` for it immediately before the tool call, with
nothing in between: no research, rendering or other action. Dispatch must match
the reserved request and re-read the selected repository or Spec Kit state; an
Apple action runs the same private, digest-pinned ASC probe again. The call must
start within 60 seconds of the claim, sooner when the authority or lease expires
first, and its `external_write` must be recorded before that deadline (see
[the note below the table](#ledger-records-you-append)).

A crash after reservation is ambiguous and burns that reservation. Read the
target back and start a fresh authorization instead of retrying.
[Coordinator setup](coordinator-setup.md#normal-use) has the exact commands.

## Ledger records you append

The runtime writes three record types: `initialize-run` writes the
`run_authorization` approval as sequence 1, `authorize` appends
`grant_reservation`, and `verify-reservation` appends `grant_dispatch`. Never
write those yourself. The agent appends every other record. Their payloads are
defined in `contracts/schemas/ledger-record.schema.json`.
`contracts/example-ledger.jsonl` is a schema and lifecycle fixture that shows
record shapes. It is not a runnable run, so take the order from this section.

| Record | Append it | What `authorize` and the ledger check require |
| --- | --- | --- |
| `time_interval` | For active work and asynchronous waits, starting before the first `authorize` | At least one bound to the authorization hash; the summed minutes stay within `limits` |
| `lease` `acquire` | After each coordinator acquire, before a grant or protected node uses it | The exact receipt; `acquired_at` and `expires_at` equal the receipt's; the selected writer as `owner`; `approval_id` set to the `authorization_id`; `branch` and `base_sha` from the authorization's `repository`; `allowed_paths` and `allowed_actions` covering each request; the matching `resource_plan` entry when one exists |
| `lease` `heartbeat` | After each coordinator heartbeat, before the old expiry | The same lease's new receipt with a later expiry |
| `lease` `release` | After the coordinator release, once every protected node passed | The coordinator's release confirmation, or recovery evidence and confirmation after expiry |
| `approval` with kind `repository` | When the user confirms the first commit or push | `scope` is `<fingerprint>:<branch>:<remote>`, copied from the authorization's `repository`. Exactly one `approved` decision may exist for that scope. A `rejected` record after it revokes the confirmation for the rest of the run, and a second approval does not restore it, so confirming again needs a new authorization and run |
| `evidence` | After each verification, review, commit comparison, publication or checks read-back | A patch identity that matches its manifest; passed evidence carries its kind's exact tool tuple, ending no later than `recorded_at` |
| `external_write` | After the dispatched tool call returns, before the dispatch deadline (see the note below the table) | The reservation's fields plus its `dispatch_id` and `outcome`, recorded before the dispatch deadline while the lease and authorization are live; `output_target` for a create grant |
| `node` | On each workflow state change | An installed node; `passed` once, after its dependencies. A patch-bound node recomputes its `patch_identity_v1` manifest inside `allowed_paths`; protected and patch-bound nodes pass inside the authorization window, and protected nodes inside their lease; later nodes need the current acceptance, review, commit-equivalence, publication or checks read-back evidence for that identity that their position requires |
| `stop` | When the run ends `blocked`, `failed_terminal` or `cancelled` | No active lease. The stop ends the run's authority: no later lease acquire or heartbeat, reservation, dispatch or external write is valid, so continuing needs a new authorization and run |

`attempt` records count against the attempt and retry `limits`. `knowledge`,
`feedback` and `improvement` records are audit only.

There is no asynchronous completion record yet. The ledger check accepts an
`external_write` only before its dispatch deadline, at most 60 seconds after the
claim, so the guarded runtime cannot validly record a call that outlasts it,
such as a long `github.checks.wait`, `apple.testflight.upload` or
`apple.testflight.processing.wait`. Never append a late `external_write`. When
the call returns after the deadline, stop the run as `blocked` without it and
continue with exact live readback and a fresh authorization, as after an
ambiguous crash.

Write each record as one JSON object followed by a single 0x0A byte. It has
exactly `schema_version` (`1.0.0`), the run's `run_id`, a `sequence` one above
the current maximum, `recorded_at`, `record_type` and `payload`. Stamp
`recorded_at` with the current UTC time and an explicit zone, never earlier than
the latest record. Never backdate it to fit a deadline, lease or authorization
window. When the true time misses a window, the ledger check rejects the run;
recover as after an ambiguous crash, with readback and a fresh authorization.

`authorize` and `verify-reservation` hold an exclusive `flock(2)` on the ledger
file while they read, validate and append, and never stamp their records earlier
than the latest one. A hand append does not take that lock. Append only while no
other append, `authorize` or `verify-reservation` call is running for the run;
two concurrent appends can reuse a sequence number and invalidate the ledger
permanently.

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
