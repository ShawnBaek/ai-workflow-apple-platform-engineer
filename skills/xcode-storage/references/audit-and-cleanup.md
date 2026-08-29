# Audit and cleanup protocol

## Inventory scope

Inventory only the categories relevant to the reported pressure:

1. Xcode installations and optional components/runtimes.
2. Simulator runtime inventory and individual devices, separately.
3. Derived Data and project-specific build artifacts.
4. Swift package checkouts/caches and resolved dependencies.
5. Archives, exported artifacts, and device-support data.
6. CI build artifacts only when the runner and retention policy are in scope.

Use supported Xcode interfaces or read-only system inspection. Do not hardcode a deletion path from a blog post; locations, ownership, and component management vary by Xcode release and installation.

For a suspected runtime-disk registry stall, add Xcode application path/build,
selected developer directory, runtime identifier/platform/version/build, image
kind, registration/signature and mount state when exposed, mapped store/image
identifier, referencing devices/run IDs, replacement availability, first error
time, and per-runtime enumeration timing. Multiple builds or image kinds are
candidates, not a finding, until the timing and exact mapping support them.
Record free bytes and the accepted storage floor separately. A low value can
increase image and cache pressure, but it is not by itself proof that capacity
caused a runtime-registry stall.

For each candidate, report a row such as:

| Target | Class | Size | Expected reclaim | Impact / recovery | Approval |
| --- | --- | ---: | ---: | --- | --- |
| exact resolved target | rebuildable / conditional / protected | measured | conservative estimate | what must rebuild, redownload, or may be lost | pending / approved |

Mark unknown ownership or a live project association as protected until the owner confirms it. Keep a before-and-after disk measurement, but do not promise that filesystem accounting will change by exactly the target's apparent size.

## Choosing a cleanup mechanism

- **Xcode components and runtimes:** prefer Xcode Settings > Components. An
  installed-toolchain Apple CLI route may remove one exact approved runtime only
  when current help supports it and identifier-to-build mapping is recorded.
  Explain replacement cost and inventory again after each item.
- **Runtime registry recovery:** diagnosis stays with `xcodebuild`; this skill
  removes only one exact, mapped, approved component through a supported Xcode
  route. Never use an unmapped store ID or mount path as the target.
- **Selected Derived Data or local build artifacts:** only after an itemized approval; use a recoverable move to Trash where practical and recheck the affected project can rebuild when that validation is in scope.
- **Simulator devices:** remove only exact, nonneeded devices after showing their identifiers and associated runtime. Never use a global erase/delete command as a storage shortcut.
- **Swift package data:** do not wipe caches to fix a package issue. First distinguish a resolver issue, a lockfile/toolchain mismatch, and a genuinely stale project-specific checkout. Follow the Swift package manager skill for resolution policy.
- **Archives:** preserve release and rollback evidence by default. Delete only exact, superseded archives after confirming they are not a distribution, crash-symbol, or audit dependency.

## Completion evidence

Record the approved targets, method used, fresh disk measurement, and any deferred candidates. If an operation is unavailable in Xcode or fails, stop with the exact error; do not substitute a broader shell deletion.
