---
name: xcodebuild
description: >-
  Build, run, debug and archive Apple-platform apps with Xcode's official tools. Use for compile failures, Simulator or device runs, logs, debugger or export work. Not for choosing tests (use apple-platform-testing).
---

# Xcode Build and Runtime

Execute the smallest operation that proves the requested contract. This skill
does not choose project roots, package policy, or test scope; load
`xcode-project-workflow`, `swift-package-manager`, and `apple-platform-testing`
for those decisions.

When the user asks to see an agent's worktree, clone, sandbox or cloud changes
in the Xcode they already have open, use `open-xcode-handoff` first; do not
build the agent's workspace in place of the user's open checkout.

## Required preflight

Resolve standalone versus coordinated ownership through
[project customization](../agent-harness/references/project-customization.md).
The lease steps below apply to coordinated/guarded work; standalone work still
requires exclusive ownership, established by the
[standalone ownership check](../agent-harness/references/project-customization.md#standalone-ownership-check),
and must not bypass an active coordinator.

1. Complete `xcode-project-workflow` and work from its exact root/container.
2. Verify logged-in host execution before any Xcode or Simulator call. Never run
   a sandbox probe.
3. Record the selected Xcode (path, version, and build), SDK, platform,
   scheme, configuration, destination, architecture, and package-lock
   fingerprint. `xcode-project-workflow` chooses the Xcode; run Xcode tools
   with its `DEVELOPER_DIR`.
4. Acquire the needed scoped resource lease: build tuple, Simulator/device,
   host CoreSimulator runtime registry, Xcode project mutation, or signing. Do
   not serialize unrelated read-only work.
5. Do not regenerate XcodeGen. Return to the project gate if generation is
   genuinely required.

Before adopting a workaround or narrowing platform evidence, read the release
notes for the exact selected Xcode build. Record the affected build, issue,
workaround, and missing coverage; remove/recheck it on toolchain change rather
than turning a beta workaround into permanent policy.

When several Xcode projects are active, read
[concurrent project resource isolation](references/concurrent-project-resources.md).
Use exact container/cache tuple keys and destination UDIDs; never let projects
share a mutable Simulator or UI-interaction session by device name or `booted`.

## Choose and reuse a Simulator destination

Simulator devices are persistent host state. Reuse one before creating one.
This section applies to run, test and runtime checks. A compile-only build
needs no device lease or boot: pass an existing compatible Simulator's id
(`-destination 'platform=iOS Simulator,id=<udid>'`, found with one bounded
`xcrun simctl list devices available` under step 1's short registry
admission, released before the build). With `ONLY_ACTIVE_ARCH=YES`, the Debug
default, that compiles only the device's architecture, and the build does not
boot the device. A generic destination such as `generic/platform=iOS Simulator`
compiles every Simulator architecture in `ARCHS`, even with
`ONLY_ACTIVE_ARCH=YES` (about twice the compile work with the default arm64
and x86_64); use it only when no compatible Simulator exists.

1. Take one bounded, read-only inventory before selecting and keep it as the
   baseline for step 8: `xcrun simctl list --json devices available` for the
   default set and `xcrun simctl --set testing list --json devices` for the
   parallel-testing clone set. Run it under the short registry admission of
   [core-simulator-health](../core-simulator-health/SKILL.md) step 3 and
   release that admission before acquiring a device lease. When
   `xcode-project-workflow` bound the user's open workspace, also read its
   active run destination with `XcodeListRunDestinations`, except during a
   suspected runtime-registry stall.
2. Select in this order, then record the exact UDID and runtime. For choices
   2 to 4, skip a device that another task owns or that the user is running
   or debugging on.
   1. a destination the user named;
   2. the open Xcode's active run destination, when it is a compatible
      Simulator; match its `displayTitle` and OS version to exactly one
      inventory UDID, and ask if the match is ambiguous;
   3. an already booted compatible device;
   4. an existing shutdown compatible device, which this task then boots;
   5. a new device, only when no existing compatible device fits and the user
      or approved project policy allows creating one.

   Before installing a build from another checkout on any existing device,
   check for the user's same-bundle app (on a booted device,
   `xcrun simctl get_app_container <UDID> <bundle-id>` prints its path). Ask
   first when it is installed or its state is unknown: the install replaces
   that app and can migrate its data.
3. A device this task creates is task-owned. Name it
   `agent-<task-id> <device type>`, create it with an explicit type and runtime
   (`xcrun simctl create '<name>' <device-type-id> <runtime-id>`) under a new
   registry admission, record its UDID, then release that admission and
   acquire the device lease for the new UDID before booting it. At the end
   shut it down and run `xcrun simctl delete <UDID>` before releasing its
   lease. When the user asks to keep it, rename it instead with
   `xcrun simctl rename <UDID> '<user-approved name>'` to a name without the
   `agent-` prefix; it is then an ordinary existing device that later tasks
   reuse under choices 3 and 4. A device still named `agent-<task-id>` belongs
   to that task even while it is shut down. For watchOS, reuse an existing
   pair (`xcrun simctl list pairs`) first. Lease a pair's watch and phone as
   one resource, but apply ownership per device: only a device this task
   created follows these naming, recording, keep and deletion rules; a
   pre-existing watch or phone keeps its name, is shut down only if this task
   booted it, and is never deleted (step 6). When this task pairs two devices
   under that lease with `xcrun simctl pair <watch UDID> <phone UDID>`, record
   the new pair UUID from `xcrun simctl list pairs`. Unless the user keeps
   the pair, run `xcrun simctl unpair <pair UUID>` at the end, before
   deleting any task-created device or releasing the lease.
   Never create or clone a device per agent, subagent, run, locale or retry.
4. Pass that UDID everywhere: `-destination id=<UDID>`, every device-targeting
   `simctl` command, and the `deviceIdentifier` of
   `DeviceInteractionStartSession` or `DeviceInteractionStartWorkspaceSession`,
   which otherwise matches loosely and can boot another device; the workspace
   variant offers only devices the current scheme can run on. If a session
   reports a device other than that UDID, end it and do not continue there.
   End each session this task opened with `DeviceInteractionEndSession`.
   Xcode MCP `RunProject`, `RunAllTests` and `RunSomeTests` act on the
   workspace's active run destination and take no UDID; use them only when
   the recorded UDID is that destination. Otherwise run tests with
   `xcodebuild test` and `-destination id=<UDID>`, run the app with
   `DeviceInteractionInstallAndRun` in a workspace session bound to the UDID,
   or ask before switching the run destination. Do not switch the user's
   active scheme, run destination or test plan without asking.
5. Parallel testing runs on clone devices (`Clone N of <device>`) in the clone
   set. Pass `-parallel-testing-enabled NO` to `xcodebuild test` and
   `test-without-building` unless the project's test plan requires parallel
   execution for this run; then cap it with `-maximum-parallel-testing-workers`
   within the host budget. Xcode MCP `RunAllTests` and `RunSomeTests` follow
   the active test plan and take no parallel-testing option. When that plan
   runs tests in parallel, ask the user before using those tools, or run the
   same tests through `xcodebuild test` with `-destination id=<UDID>` and
   `-parallel-testing-enabled NO`. Do not edit the user's plan or scheme
   without approval.
6. Shut down only a device this task booted. Never erase or delete a device,
   or unpair a pair, that this task did not create, including user-named
   devices and devices whose runtime is unavailable. Never run
   `simctl erase all`, `simctl delete unavailable` or `simctl delete all`.
7. When another task or agent holds the chosen device, share it only through
   the coordinator lease and the one UI-session owner rule, or queue. Do not
   create a second device to avoid waiting unless the user allows it.
8. At the end, after releasing this task's device leases, repeat both step 1
   inventory commands under a new registry admission and diff each set against
   its own baseline by UDID. Report as leftovers the task-created devices that
   step 3 did not delete and the user did not keep, and the clones that
   appeared while this task ran tests. The user's own Xcode test runs also
   create clones, so say when a clone's owner is uncertain and do not delete
   it here. Delete a leftover this task created by exact UDID only with
   approval, after releasing that admission, under a device lease for that
   UDID and while no test run uses it; a clone needs
   `xcrun simctl --set testing delete <UDID>`. Report baseline clones and
   baseline `agent-` devices whose task holds no live lease as pre-existing,
   not as this task's leftovers. Route them, uncertain-owner clones, orphan
   `~/Library/Developer/XCTestDevices` directories (which `simctl list`
   omits) and broader cleanup to `xcode-storage`.

## Tool routing

For installation, registration, duplicate-provider, or first-connection
questions, read [Xcode MCP provider preflight](references/xcode-mcp-provider-preflight.md)
before choosing a route. Keep installation, client registration, current-task
tool exposure, and a successful read-only Xcode response as separate evidence.

Use the first available authorized route:

1. Xcode's built-in official tools in the open project;
2. an external Codex/Claude agent connected through Apple's supported Xcode
   bridge;
3. host `xcodebuild`, `xcrun`, and related Apple CLI tools;
4. an explicitly approved third-party adapter such as XcodeBuildMCP.

Built-in and exported Apple skills are alternative exposures of one Xcode; load
one, as [Apple skill exposure](../apple-platform-setup/references/apple-skill-exposure.md)
describes. Never run `xcrun agent`, which is `mcpbridge run-agent`, to find or
export skills during a build task. Record the selected tool/skill provider and
version, with the Xcode build and an export's digest.
When runtime discovery is stalled, inventory all Simulator-capable providers
across open tasks and keep exactly one active for diagnosis, official-first.
Do not compare providers concurrently against an already blocked global service.

When the user selects `asc` for a build, inspect the installed `asc xcode --help`
and follow [build and release lanes](../app-store-connect/references/build-and-release-lanes.md).
Its local archive/export helpers wrap Xcode; they retain this skill's exact
container, toolchain and resource rules. Xcode Cloud is a remote build route
owned by `app-store-connect`. Neither route creates a GitHub PR: use
`git-workflow` with the app's confirmed remote/base for that handoff.

## Smallest useful operations

- Compile question: build only the affected scheme/configuration; for a
  Simulator platform, use an existing compatible Simulator's id without booting
  it (see the destination section), after changed Swift passes the format and
  lint steps of
  [Swift format and compile acceptance](../apple-platform-testing/SKILL.md#swift-format-and-compile-acceptance).
- Unit test question: run the affected target/case chosen by
  `apple-platform-testing`.
- Repeated test tuple: build-for-testing once and reuse only when every tuple
  field and source/package fingerprint matches.
- Runtime bug: build/install/launch once, reproduce deterministically, collect
  the first actionable diagnostic and relevant logs.
- Install/launch/tool hang after a successful build: preserve the build product,
  stop only the stuck request, and follow
  [Simulator hang recovery](references/simulator-hang-recovery.md) to separate
  boot, install, launch, and UI verification without rebuilding.
- Runtime discovery/store failure before a destination is usable: stop new
  Simulator requests, acquire the host-wide registry lease, and follow
  [runtime-disk registry recovery](references/runtime-disk-registry-recovery.md).
  Treat a repeated `dev_t` error or mixed Cryptex/runtime-volume inventory as a
  hypothesis to map, not permission to remove a runtime.
- UI check: use stable accessibility identifiers and deterministic launch state;
  official UI interaction/capture tools are preferred.
- Screenshot: capture raw pixels and route App Store/evidence curation to
  `screenshot`.
- Debugger: reproduce before attaching; report a concise backtrace and observed
  state rather than dumping an entire session.

Route dependency resolution/update to `swift-package-manager`; never hide an
unplanned resolve inside every build.

## Failure classification

Classify before retrying:

- environment/permission/CoreSimulator connection;
- CoreSimulator runtime-disk registry or component registration;
- project/container/scheme/destination;
- package resolution/checkout;
- compiler/linker;
- signing/account/team;
- test assertion/runtime crash;
- timeout/infrastructure.

Environment or authority failures stop. A compiler/test failure is not blindly
rerun: diagnose, change input or implementation, then create a new attempt. The
same normalized failure twice stops the loop. When the fix edits Swift source, the
new attempt first reruns the format and lint steps of
[Swift format and compile acceptance](../apple-platform-testing/SKILL.md#swift-format-and-compile-acceptance).

If install/launch hangs on two compatible destinations, or read-only Simulator
and Xcode task queries also hang, classify the remaining runtime work as a
CoreSimulator/Xcode service blocker. Do not keep opening sessions or switch
destinations indefinitely.

## Evidence

Report outcome, duration, normalized operation, first actionable diagnostic,
and artifact locations. For tests include `.xcresult` path and hash plus the
modern `xcresulttool` summary. A command exit alone does not prove the requested
screen, behavior, signing identity, or bundle value.

Keep claims platform-specific: iPad window state, watchOS device controls and
pairing, macOS native versus Catalyst, and iOS destinations require their own
relevant evidence.

## Never

- require XcodeBuildMCP when official tools are available;
- generate/regenerate XcodeGen automatically;
- run Xcode/Simulator in a sandbox or reinterpret permission errors as tests;
- select another checkout/container to make a build pass;
- resolve packages on every build without an input change;
- dump full logs when a concise diagnostic and artifact path suffice;
- modify protected CoreSimulator registry, image, Cryptex, or mount state by
  hand;
- create, clone, erase or delete a Simulator device outside
  [destination reuse](#choose-and-reuse-a-simulator-destination) or
  `xcode-storage`'s approved cleanup;
- manage certificates, upload, submit, or merge without the owning skill/gate.

References:

- [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
- [Xcode command-line tools](https://developer.apple.com/documentation/xcode/xcode-command-line-tools)
- [XCTest](https://developer.apple.com/documentation/xctest)
