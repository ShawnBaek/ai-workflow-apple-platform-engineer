# Simulator install, launch, or tool hang recovery

Use this when compilation already succeeded but Simulator boot, app install,
launch, UI hierarchy capture, or the Xcode tool queue stops responding. Keep
build evidence and runtime evidence separate: an install hang does not turn a
successful compile into a build failure, and a successful compile does not prove
that the app ran.

## Bound the current operation

Before a long-running step, record its phase, tool/provider, start time,
destination UDID and runtime, app bundle path and hash, bundle identifier, and a
phase-specific timeout. The project may override the budget; otherwise five
minutes is a conservative ceiling for a first install or launch on a newly
booted Simulator. Waiting without a deadline is not verification.

When the deadline expires:

1. interrupt only the outstanding install, launch, hierarchy, or tool-list
   request and record whether cancellation completed;
2. do not start another build, another device-interaction session, or several
   concurrent status requests;
3. verify that the existing app product still matches the current source,
   package, configuration, SDK, and architecture tuple;
4. preserve the successful build result and classify the blocked phase as
   Simulator/runtime infrastructure.

Never kill unrelated Xcode/Git processes, erase a device, delete DerivedData,
remove a runtime, or reset app data as a first response.

## Split the pipeline without rebuilding

Use the selected official Xcode tool's separate actions when available; the
host `simctl` equivalents can be used through the authorized Apple CLI route.
Apply a bounded timeout to each call.

1. Confirm the exact destination exists and reaches its booted state.
2. Install the already-built `.app` on that destination.
3. Confirm installation for the exact bundle identifier.
4. Launch the installed bundle and record the process/launch result.
5. Only after launch succeeds, start UI hierarchy/screenshot/interaction
   verification.

Do not switch to a combined build-and-run operation after the build already
passed. Rebuild only if the source/package/toolchain tuple or app product is
missing or stale.

## Distinguish device-local from service-wide failure

One bounded control attempt on a second Simulator with the same runtime and a
compatible architecture is allowed after releasing the first device lease. It
tests the runtime service, not product compatibility, and does not expand the
platform claim.

Escalate the classification to Xcode/CoreSimulator service-wide when either:

- the same install/launch phase hangs on both destinations; or
- even a read-only device inventory, boot-status request, Xcode task listing,
  or session shutdown does not return within its budget.

At that point stop all Simulator-dependent graph nodes, release device/build
leases when the tools permit it, and mark UI/runtime acceptance evidence
`blocked`. Continue only work that does not depend on runtime proof; never claim
the screen or tap flow was verified.

Skip the second-device control attempt and move directly to
[runtime-disk registry recovery](runtime-disk-registry-recovery.md) when the
failure occurs before destination selection: repeated
`unable to get a dev_t for store <store-id>` diagnostics, a live-but-stalled
`simdiskimaged`, repeated registration of the installed runtime catalog, or a
reproducible pause at one exact runtime build/image transition. These signals
need a host-wide registry lease and one diagnostic owner; additional `simctl`,
MCP, or Device Hub requests can amplify the queue.

## Host recovery and diagnostics

Prefer a normal user-visible recovery: stop the affected run, quit Simulator or
Device Hub and Xcode normally, reopen the same Xcode version and authoritative
container, then retry one separated install/launch sequence. Ask before closing
the developer's active apps or restarting the Mac. Do not use force-kill,
CoreSimulator-service reset, device erase, runtime removal, DerivedData deletion,
or a different checkout as a generic cure.

If the service still fails, preserve a concise timeline and the first relevant
host diagnostic. Collect a full Simulator diagnostic only when needed and
privacy-review it before sharing; it may contain usernames, paths, device/app
metadata, and logs. Recheck the release notes for the exact Xcode build before
adopting a toolchain-specific workaround.

The runtime-disk guide takes precedence over generic restart advice when runtime
enumeration itself is blocked. Do not remove a runtime or touch a mount from an
unmapped numeric store identifier.

## Device-interaction boundary

Device interaction begins only after installation and launch are confirmed.
Use one exclusive session for the chosen destination. Capture hierarchy and
screenshot before and after each action, retry one shifted/transitioning target
once, and then report the observed failure. Loading state is transient; an
unresponsive install/session/tool queue is infrastructure failure, not an app UI
bug.

References:

- [Apple: Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
- [Apple: Xcode command-line tool reference](https://developer.apple.com/documentation/xcode/xcode-command-line-tool-reference)
- [Apple: Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
- [Apple: Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
