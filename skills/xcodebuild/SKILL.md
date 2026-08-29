---
name: xcodebuild
description: >-
  Builds, tests, runs, debugs, and captures Apple-platform apps with Xcode's official tools first. Use for iOS, iPadOS, watchOS, macOS, tvOS, or visionOS compile failures, Simulator/device runs, logs, debugger work, UI interaction, screenshots, or xcresult evidence. Routes external Codex/Claude through Apple's supported Xcode bridge and uses third-party adapters only by explicit fallback.
---

# Xcode Build and Runtime

Execute the smallest operation that proves the requested contract. This skill
does not choose project roots, package policy, or test scope; load
`xcode-project-workflow`, `swift-package-manager`, and `apple-platform-testing`
for those decisions.

## Required preflight

1. Complete `xcode-project-workflow` and work from its exact root/container.
2. Verify logged-in host execution before any Xcode or Simulator call. Never run
   a sandbox probe.
3. Record selected Xcode build, SDK, platform, scheme, configuration,
   destination, architecture, and package-lock fingerprint.
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

Built-in and exported Apple skills are alternative exposures; do not load both
for the same trigger. Record the selected tool/skill provider and version.
When runtime discovery is stalled, inventory all Simulator-capable providers
across open tasks and keep exactly one active for diagnosis, official-first.
Do not compare providers concurrently against an already blocked global service.

## Smallest useful operations

- Compile question: build the affected scheme/configuration/destination only.
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
same normalized failure twice stops the loop.

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
- manage certificates, upload, submit, or merge without the owning skill/gate.

References:

- [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
- [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
- [Xcode command-line tools](https://developer.apple.com/documentation/xcode/xcode-command-line-tools)
- [XCTest](https://developer.apple.com/documentation/xctest)
