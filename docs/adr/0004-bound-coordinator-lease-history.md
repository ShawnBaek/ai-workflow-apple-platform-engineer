# ADR 0004: Bound the coordinator's terminal lease history

Status: proposed · Owner: repository maintainer

## Context and decision

The host coordinator kept every released and recovered lease forever. Each
locked call reloads and revalidates the whole state, each mutation rewrites it,
and every `runtime_ui` health evaluation adds a lease. Cost grew linearly until
the state would pass the 32 MiB read limit and block every caller.

Each acquire, heartbeat, release or recovery now drops a released or recovered
lease once seven days have passed since both its terminal transition and its
owner's authorization window ended. It keeps a lease past that window when the
lease carries `next_fencing_token`, or when a kept recovery names it as its
replacement, because the load check requires both. Active leases, run
authorities, host policy history and the fencing sequence are never dropped.

## Alternatives and consequences

A time-only window would drop the history of a run whose authorization is still
open. That run's `authorize` and `verify-reservation` recheck every earlier
release or recovery confirmation in its ledger against the state and would
block. An archive file would keep the records but add a second persisted
artifact with its own failure and privacy rules. A new state field recording
the retired fences would make older runtimes refuse the state.

The layout and schema version are unchanged, and older schema-2 runtimes still
read a compacted state. After a lease is dropped, its receipt stays stale, its
confirmation no longer validates against the state, and no fencing token is
reissued. The run ledger remains the audit record for receipts, confirmations
and recovery evidence. A run with a long authorization window keeps its own
terminal leases until seven days after that window ends, including a runtime
probe run's admissions. Run authorities still grow by one record per run.
`RuntimeStateAndProbeScopeTests` measures the lease section over 60
acquire/release cycles and checks the kept fencing proof and replacement.
