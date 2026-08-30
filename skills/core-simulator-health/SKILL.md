---
name: core-simulator-health
description: >-
  Diagnose and recover CoreSimulator, simctl, simdiskimaged, runtime, boot,
  install, launch, screenshot, and Xcode MCP failures without rebooting the Mac
  or deleting global state. Use before simulator-dependent Apple-platform work
  and whenever simulator infrastructure becomes slow, stuck, or inconsistent.
---

# Core Simulator Health

Treat Simulator infrastructure separately from app behavior. Keep diagnosis
bounded, single-owner, evidence-backed, and non-destructive.

## Hard boundaries

1. Follow the repository's Xcode host-execution policy before any xcrun,
   Simulator, Xcode MCP, or Apple-tooling command. A sandbox permission failure
   is not an app or Simulator result.
2. Resolve the exact opened Xcode container, selected Xcode build, runtime,
   destination UUID, and task owner before probing.
3. Acquire the shared simulator_or_device lease for exact device UUIDs.
   Acquire coresimulator_runtime_registry for runtime discovery or repair; it
   conflicts with every device lease on that host.
4. Use one Simulator-capable provider and one mutation at a time. Do not overlap
   boot, shutdown, install, launch, screenshot, runtime inventory, or repair.
5. Never reboot the Mac as a CoreSimulator recovery step or recommendation.
   If bounded non-reboot recovery cannot restore the capability, preserve
   diagnostics and report it degraded or blocked.
6. Never broadly kill services, erase devices, delete runtimes, clear caches, or
   alter CoreSimulator databases, mounts, Cryptex assets, or images.plist
   without a separate exact authorization.
7. Preserve user-owned devices and data. Prefer an exact temporary device for an
   explicitly authorized destructive diagnostic.
8. Never infer a permanent hang from one process-state snapshot.

## Preflight

Use Apple's official Xcode MCP or direct Apple tools first. Record:

- selected Xcode path and build;
- opened workspace/project and selected scheme;
- exact runtime version/build and destination UUID;
- the active Simulator/MCP provider owner;
- relevant CoreSimulatorService, simdiskimaged, launchd_sim, simctl, and Xcode
  MCP process IDs with parent and elapsed time;
- disk pressure as supporting evidence, never as sole root cause.

Bound the first read-only inventory. If it times out, do not start a build,
install, launch, screenshot, or a second inventory process.

## Transient U state rule

A single U state is ambiguous. Apply this sequence exactly:

1. Record the exact PID, service name, parent, elapsed time, device/runtime
   relationship, and the correlated command that is slow.
2. Wait 15–30 seconds once without starting another probe.
3. Recheck the same process or service class once.
4. If the state clears, classify it as transient boot/background work. Do not
   reboot, and do not restart the Mac “for safety.”
5. If it persists and correlated CoreSimulator calls also remain unresponsive,
   stop mutations and continue the bounded non-reboot ladder.

A Simulator device shutdown/boot is not a Mac reboot. Use it only for the exact
leased UUID and only while simctl remains responsive.

## Stuck build, install, or launch

Separate build, install, launch, and interaction states:

1. If the build succeeded, preserve that evidence. Do not rebuild merely because
   install or launch stopped responding.
2. Bound a no-progress install/launch request. Stop only the exact request or
   child PID created by this task.
3. Confirm whether the frontmost hierarchy is SpringBoard, an app launch screen,
   or an app-owned screen. A branded launch screen is not Home.
4. Retry once through separate install then launch steps on the same exact
   destination.
5. Before switching destinations, prove the original device service is the
   failing layer. A second device is a controlled comparison, not an automatic
   retry loop.
6. If direct Apple tooling works while a workspace-bound MCP action fails,
   classify only that MCP capability as degraded.

Never wait indefinitely and never start duplicate builds while an earlier
operation is still live.

## Runtime registry incidents

Normalize repeated errors such as a runtime store failing to provide a device
identifier. Collect one bounded runtime inventory and correlate:

- runtime identifiers, versions, builds, image types, and states;
- duplicate beta builds or stale deleting/unavailable records;
- selected Xcode/runtime compatibility;
- simdiskimaged continuity and the timing of each error;
- free storage and mount state as supporting evidence.

Do not conclude that runtime count, beta duplication, or low storage is causal
without a controlled result. Remove an exact runtime only with approval and
through Xcode Settings > Components or another Apple-supported interface. Never
delete runtime files directly.

## Non-reboot recovery ladder

Stop at the first successful step and rerun one read-only health check:

1. End agent-created interaction sessions and the exact stale task child.
2. Restore one official Xcode MCP/Simulator provider owner.
3. Confirm selected-Xcode and visible Simulator UI provenance. Close only an
   exact mismatched Simulator UI when evidence shows it is holding the device.
4. If a U state was observed, perform the one spaced recheck above.
5. While simctl is responsive, cleanly shut down and monitor boot for only the
   leased device.
6. Try one separate app install and launch, preserving the successful build.
7. Compare one known system-app launch or one SDK-matching runtime when the task
   permits it.
8. If inventory is still unavailable, capture bounded diagnostics such as
   xcrun simctl diagnose, relevant unified logs, and a spindump/sysdiagnose only
   when authorized. Stop with a degraded/blocked capability.

Do not convert step 8 into a reboot instruction. A user-initiated reboot outside
this workflow is not evidence that rebooting was required.

## Verification

Choose the smallest gate that proves recovery:

- inventory returns within the recorded bound;
- the exact device reaches a terminal boot state;
- install returns successfully and app container identity is observed;
- launch returns a PID and the expected app-owned hierarchy;
- screenshot/touch evidence matches the requested behavior.

For stability acceptance, repeat the exact install → launch → screenshot path
three times only when that repetition is an explicit acceptance requirement.
Otherwise one deterministic pass is sufficient.

A command exit code alone is not proof that boot migration, asynchronous runtime
deletion, app launch, or UI interaction completed. Record the observable terminal
state.

## Official references

- [Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
- [Diagnosing issues using crash reports and device logs](https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs)
- Local Apple command references: xcrun simctl help, xcrun simctl runtime help,
  and xcrun simctl diagnose --help.
