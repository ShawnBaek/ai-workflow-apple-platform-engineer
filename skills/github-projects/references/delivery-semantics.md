# Delivery semantics

Use this reference once a concrete Issue, Project v2, branch, or PR is in
scope. External writes require the approval required by the repository and
user; this workflow does not grant it.

If an immutable run authorization already grants the exact unchanged action,
target, repository, branch, and idempotency key, reuse that authorization hash
instead of asking a routine second time. A scope/target mismatch or missing
Project permission becomes `blocked`/partial success; do not broaden access.

## Minimal mapping

| Delivery artifact | Required link or evidence |
| --- | --- |
| Issue | Problem/acceptance criteria, intended verification, and blocker if any. |
| Project item | The Issue or PR URL plus the existing status-field option. |
| Branch | One Issue identifier in the branch name or PR body when an Issue exists. |
| PR | Linked Issue, concise implementation summary, minimum sufficient tests, and UI screenshot/video evidence when UI behavior changed. |
| Done | Merge/acceptance reference and check/evidence outcome. |

Do not create duplicate Issues solely to represent a PR. Do not force every
small documentation-only change into a Project when the repository does not use
one.

## Ordered state changes

Apply only the steps for artifacts in scope. An issue-only report ends with
issue readback; it does not require a Project, branch or PR.

1. Discover and identify the exact repository, Project owner/number, Issue,
   status field, and option IDs.
2. With approval, create or update the Issue if it is the agreed work unit.
3. Move the existing Project item to `Ready` only when its acceptance criteria
   and dependencies are known. Move it to `In Progress` only after the writer
   lease and branch are established.
4. Create the PR through the repository's normal branch and verification flow.
   Include the Issue reference, tests actually run, relevant artifacts, and
   anything intentionally not run.
5. After the PR exists, move the Project item to `In Review`. Only mark `Done`
   after merge or explicit acceptance; mark `Blocked` with a factual cause and
   next owner when work cannot proceed.

## Partial success ledger

Record each externally visible operation independently:

| Operation | Success evidence | On a later failure |
| --- | --- | --- |
| Issue create/update | Issue URL and number | Keep it; report its current state. |
| Branch push | Remote branch SHA | Keep it; do not force-push to undo it. |
| PR create/update | PR URL and number | Keep it; do not close it automatically. |
| Project item/status update | Project URL, item ID, field option | Report the failed mutation and leave the PR intact. |
| Checks/evidence publication | Check run/artifact URL and result | Report availability/retention; do not claim the PR is fully verified. |

If a Project mutation fails after PR creation, add a factual PR comment only if
the user authorized comments; otherwise report a pending tracker reconciliation
with the exact Project, item, field, and desired status. Do not use retries to
mask an uncertain result: first re-read the item and PR state.

If a linked-worktree or Git-index sandbox boundary interrupts this flow, stop
tracker mutations and load `git-workflow`'s path-agnostic recovery procedure.
Resume only after that skill independently verifies worktree, index, branch,
and remote state in the same authoritative checkout.
