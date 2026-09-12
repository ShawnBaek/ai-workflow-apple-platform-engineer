---
name: xcode-storage
description: Audit and safely reclaim Xcode, Simulator, Swift package, archive, and build storage on Apple-platform development machines. Use for disk-pressure investigation or approved cleanup; do not use for normal builds or broad cache deletion.
---

# Xcode Storage Audit

Treat developer storage as evidence first, cleanup second. Do not delete anything merely because it is rebuildable: an active project, offline development, release recovery, or another user can make that cost material.

## Start with an inventory

Perform a read-only inventory of the relevant categories and record each target's resolved path, size, last-use signal where available, owner/project association, expected reclaim, and recovery impact:

| Class | Typical contents | Default handling |
| --- | --- | --- |
| Rebuildable | selected Derived Data and completed build intermediates | candidate only after exact approval |
| Conditional | Simulator devices, downloaded runtimes/components, package caches, device support, archives | inspect use and replacement cost first |
| Protected | source checkouts, user data, signing material, active build/test evidence, unknown files | never delete through this workflow |

Do not equate a Simulator device with an installed runtime: removing a device does not necessarily reclaim its runtime, and removing a runtime can affect many devices. Use Xcode's current settings and simulator inventory to establish the relationship rather than assuming paths or sizes.

If discovery itself stalls, repeatedly reports
`unable to get a dev_t for store <store-id>`, or exposes mixed-build
Cryptex/runtime-volume candidates, this is not an ordinary space cleanup. First follow
[CoreSimulator runtime-disk registry recovery](../xcodebuild/references/runtime-disk-registry-recovery.md)
under the host-wide registry lease. This skill owns only the itemized approval
and supported removal/re-download of one exact mapped component.

Read [audit-and-cleanup.md](references/audit-and-cleanup.md) for the inventory and approval protocol. Read [ci-safety.md](references/ci-safety.md) for CI runners.

## Approval boundary

Before a cleanup, present an itemized proposal: exact targets, current size, estimated reclaim, whether it is recoverable, replacement cost, and affected projects or runtimes. Obtain approval for those exact targets. A request to "free disk space" is not permission for a blanket cleanup.

Prefer Xcode Settings > Components for installed Xcode components and runtimes.
An exact Apple CLI runtime-removal route is permitted only when the selected
toolchain's current help exposes it and the approved identifier is mapped to the
displayed build; remove one target, then inventory again. For independently
identified rebuildable local artifacts, prefer moving the exact approved target
to Trash when practical. Confirm the outcome with a fresh inventory. Do not
remove source checkouts, signing assets, unknown folders, or anything outside
the approved list.

Runtime approval must name platform, version, exact build, image kind,
store/image mapping, affected devices/projects, measured size, replacement
availability/cost, and rollback or re-download plan. A numeric store identifier,
mount path, runtime count, or duplicate marketing version alone is insufficient.

## Hard stops

Never run or recommend broad destructive commands such as blanket `rm -rf` against developer directories, `simctl erase all`, wiping all package caches, deleting all archives, or deleting runner workspaces. Do not add an unconditional cleanup step to CI.

Never delete CoreSimulator registry, Images, Cryptex, or Volumes state directly;
force-unmount runtime images; terminate CoreSimulator daemons as cleanup; or
disable system protections to make deletion possible.

If storage pressure blocks a build, report the measured constraint and the smallest candidate targets. Pause for approval rather than improvising a cleanup.
During a runtime-registry incident, low free storage is supporting pressure
evidence only. It does not authorize cleanup and is not a sole-cause finding
without a controlled before/after change.

## References

- [Audit and cleanup protocol](references/audit-and-cleanup.md)
- [CI cleanup safety](references/ci-safety.md)
- [Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
