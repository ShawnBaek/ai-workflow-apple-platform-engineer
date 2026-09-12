# Bound host work and storage

Before dispatch, bind [task workspaces](task-workspaces.md): exact checkout, shared-file ownership, output roots and actual sandbox/tool permissions. Folder separation alone does not enforce access or resource ownership.

Start with one active writer per repository identity, one heavy build/test job, and one active destination. Independent readers can work from frozen inputs alongside the writer. The current coordinator keys source/Xcode/build conflicts by repository fingerprint, so separate worktrees of the same repository do not permit simultaneous writers. Worktrees still require explicit authorization. Delegate only a concrete independent task and send its acceptance criteria, owned paths, frozen base and resource constraints. A worker must finish and release ownership before another acquires it.

The version 2 coordinator admits host-wide `heavy_jobs`, `active_devices`, and `internal_workers` atomically across tasks. Defaults are 1, 1 and 2: one build plus its destination fits without allowing two heavy jobs. Requested admission cannot understate the resource's minimum. Internal Xcode workers count too; `-parallel-testing-worker-count`, `-maximum-concurrent-test-simulator-destinations`, `-jobs`, Swift `-j` and compiler jobs must fit the accepted host budget. Increase host policy explicitly from observed capacity; do not let every subagent choose its own limit.

`internal_workers` counts admitted local tool workers, not LLM subagents. A read-only research agent does not consume that budget merely because it is called a worker. Count the resources its actual tools request; use the client's separate effective slot limit for model concurrency.

The lead/client queues work when the coordinator returns `resource_conflict` or `capacity_exceeded`; the coordinator is an admission gate, not a waiter queue or agent launcher. Retry when the conflicting work releases ownership or capacity, within the task's retry policy. Do not duplicate a coordinator, steal an expired lease, kill unrelated processes, or turn on maximum parallel testing to make progress. Prefer a lower-cost model for bounded extraction/formatting, a balanced model for ordinary implementation, and stronger reasoning for uncertain architecture or authorization review. The [shared routing policy](cost-and-usage.md) separates model cost from host resource limits.

Describe the blocked operation and canonical reason, not “the skill is locked”:

| Observation | Caller action |
|---|---|
| `resource_conflict` / `capacity_exceeded` | Queue the affected operation and continue independent work. Preserve the conflicting lease ID or exhausted dimension when available; report the owner only when verified. Recheck after a relevant release using supported bounded waits. Busy capacity is not a request for user permission. |
| `coordination_required`, migration or runtime/root mismatch | Diagnose the configured runtime, app root and receipt. An installed-copy defect is a setup failure, not evidence another task owns the resource. Route repair to its owner; keep unaffected work moving. Do not create another coordinator or silently bypass the guard. |
| Missing action/account/branch/signing authority | Ask only for the actual missing authorization, with the concrete action and applicable rule. Reuse confirmed facts within their scope. |

An unchanged busy response is not a failed implementation attempt. Do not poll
repeatedly or ask the user to “unlock four tasks” from a lease count alone. If
the client cannot wait/resume, preserve the pending operation and its precise
resumption condition; do not claim background progress. Release this task's
unneeded leases before waiting for another resource or human input.

Check relevant memory pressure, free disk, active builds/destinations and output sizes before admitting heavy work. Reduce concurrency before deleting caches. Capture only bounded logs and short recordings; stream large hashes, process images sequentially, and keep raw evidence only as long as the accepted retention policy needs it. Preserve original hashes and the final reviewable proof before cleaning task-owned temporary output.

Reuse DerivedData and package artifacts only for a matching build tuple. Give concurrent incompatible builds separate task-owned paths; avoid copying whole package caches into every worktree. Prefer `build-for-testing` followed by selected `test-without-building` runs when inputs match. Do not blindly reset package caches, erase all Simulators, delete archives, or remove global DerivedData. Route an actual storage-pressure cleanup to [xcode-storage](../../xcode-storage/SKILL.md), inventory candidates and obey its destructive-action scope.

For Simulator, bind an exact UDID/runtime and use [core-simulator-health](../../core-simulator-health/SKILL.md). Registry discovery uses a short host registry admission; release it before acquiring an incompatible destination lease. Never hold one lease while waiting indefinitely for a conflicting one. Shut down only a destination this task booted and owns, when no dependent work remains. A simulator screenshot validates appearance and flow; sustained performance claims usually need a real device.

Release owned leases on success, failure and cancellation. Cancel owned child processes first, preserve actionable diagnostics, then apply bounded task-output retention. Expiry alone is not cleanup or proof that a process died.
