# ADR 0002: Finalize expired quiescent leases without takeover

Status: proposed · Owner: repository maintainer

## Context and decision

[Issue #49](https://github.com/ShawnBaek/ai-workflow-apple-platform-engineer/issues/49)
reports finished work retaining host capacity because normal release rejects
expired receipts and recovery requires a dead owner. Add the explicit
`quiescent_release` evidence mode to `recover`, retaining its lock, exact receipt,
terminal fence and persisted confirmation. Reject replacement ownership in this
mode. Preview performs the same validation without persisting a transition.

An owner may finalize with its unchanged registered authority after expiry;
a different observer needs active authority and a completed owner. Live quiescent
owners finalize themselves. Evidence must establish completed protected operations
and preserved state, including legitimate uncommitted work.
Expired receipts remain unusable for verification, heartbeat or new mutation.

## Alternatives and consequences

Ignoring expiry in ordinary release would omit the required evidence. Automatic
reaping could admit overlapping work. A new terminal state/schema would require
migration while the very leases being repaired remain active. The tagged mode
uses existing recovery and ledger records instead.

Schema-2 layout and old evidence remain readable by the new runtime. Old strict
runtimes cannot read a record with the new evidence mode: runtime/source binding
upgrades remain explicit, and downgrade after first use is unsupported. This
cooperative harness validates bound, fresh observations; it does not independently
prove OS task quiescence. Automatic heartbeat and client task tracking remain a
separate part of #49. Focused lifecycle, denial, ledger and preview regressions
plus the full Swift suite are required before publication.

Terminal ledger entries may be recorded after the actual transition, including
after a timely normal release's expiry, but may never precede or change its
persisted timestamp. This supports response-loss reconciliation without granting
new work. Pre-upgrade live-owner harness rebinding is outside this change.
