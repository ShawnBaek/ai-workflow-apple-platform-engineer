# Concurrent Xcode project resource isolation

Use this when two or more authoritative Xcode projects are active on the same
Mac. Parallel source reading is unrestricted; mutable Xcode, build-cache,
Simulator/device, and UI-session state is keyed and leased independently.

## Namespace every run

Record `run_id`, normalized repository fingerprint and canonical root, exact Xcode
container, branch/HEAD, selected Xcode build, scheme/configuration/architecture,
canonical resolved DerivedData and SourcePackages locations, bundle identifier,
app bundle hash, tool session ID, platform/runtime, host ID, and the sorted,
unique, non-empty set of exact destination UDIDs.

For mutable leases, the coordinator instance is the authoritative host identity;
do not trust a caller-supplied registry label as proof that two runs share or do
not share a host.

Do not address a mutable destination by display name or the ambiguous `booted`
alias. Names such as “iPhone 17 Pro” are not unique, and several devices may be
booted. Every boot/install/uninstall/launch/privacy/location/status-bar/UI/
screenshot operation uses the leased UDID explicitly.

## Lease boundaries

- **Project mutation:** serialize per logical repository or canonical container. A second agent may
  read a frozen snapshot but may not modify the project/spec concurrently. The
  same canonical container conflicts even if a caller supplies a different
  repository fingerprint, and a project-mutation lease conflicts with the
  source-writer and build leases for that logical repository. One run may nest
  project mutation under its own source lease. It releases project mutation
  before a normal build; the sole overlap is the same run's explicit
  `xcode_project_packages` resolution, acquired source → project → build and
  released in reverse.
- **Source writer:** one normalized repository fingerprint has one writer across
  every checkout. A worktree does not grant a second writer. A different
  owner's build or project mutation for that repository conflicts; the same
  run/actor may nest source around its own build or project lease.
- **Build:** record repository/container SHA, Xcode/SDK, scheme, configuration,
  architecture, package fingerprint, and the exact canonical paths for
  DerivedData, SourcePackages, repository checkouts, artifacts, and the package
  cache. `cache_paths` must equal those five named `cache_roles` values. The
  `artifacts` cache role means SwiftPM binary artifacts; it is not an xcresult or
  archive destination. Record every explicit `-resultBundlePath`,
  `-resultStreamPath`, `-archivePath`, export path, or diagnostic bundle in
  `output_roles` and repeat its exact unique values in `output_paths`. Different
  tuples from different repositories may run together only when all canonical
  mutable cache and output path trees are disjoint. Builds for one logical
  repository serialize even when caches differ, because the tool may touch
  package or project metadata. Equal paths, parent/child paths, and resolved
  aliases conflict. Compare filesystem identity for existing paths and
  conservatively case-fold/Unicode-normalize path ancestry so APFS spelling
  aliases cannot create a second lease.
- **Package resolution:** a build-only lease is insufficient because resolution
  can write tracked `Package.resolved` or project package metadata. Set
  Every build tuple, including `none`, therefore requires the same run's source
  writer lease. Set `package_resolution_mode` to `swiftpm_lockfile` or
  `xcode_project_packages`; hold the same run's source-writer lease, and for
  Xcode-managed package metadata also hold its exact project-mutation lease.
  Acquire in source → project (when applicable) → build order and release in
  reverse. Normal compile/test/archive work uses `none`, passes
  `-disableAutomaticPackageResolution` to `xcodebuild`, and uses
  `--disable-automatic-resolution` (also exposed as
  `--force-resolved-versions`) with standalone `swift build`/`swift test`.
  After the command, compare tracked dependency/project metadata and block
  delivery if it drifted. A flag is not a substitute for the writer lease.
  Never redirect caches merely to avoid a lease.
- **Simulator/device:** key by host ID and the exact UDID set. Any UDID
  intersection on the same host conflicts. Platform, bundle ID, and run ID stay
  in evidence only. Separate projects receive separate Simulator devices even
  when their runtime/model matches, especially when bundle identifiers collide.
- **CoreSimulator runtime registry:** one owner per host-wide
  `coresimulator_runtime_registry` key. This covers runtime discovery,
  component registration/removal, image and mount recovery, and service-wide
  diagnostics. Key it by host and registry scope, not Xcode build, because
  stable and beta Xcode installations can encounter the same runtime state.
- **UI interaction:** one session owner per UDID. The owner controls install,
  launch, hierarchy, taps, screenshots, launch arguments, permissions, locale,
  appearance, and app data for that run.
- **watchOS:** lease the paired watch and companion iPhone as one resource; do
  not assign either side to another run.
- **macOS:** native app/window interaction is not a Simulator lease. Lease one
  host-scoped `macos_gui_session` with `session_scope: foreground_ui` for the
  whole foreground UI test; keep bundle/process identity in evidence.

Default Xcode user-level caches remain valid. If simultaneous operations truly
need cache isolation, that is an explicit concurrent-validation choice under the
project policy; use a generic approved cache location and record it in the build
tuple. A cache is never an alternate source checkout.

An Xcode build descriptor uses all five roles and repeats their exact unique
values in `cache_paths`:

```json
{
  "repository_fingerprint": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "container_path": "/private/source/Application.xcworkspace",
  "xcode_build": "27A000",
  "sdk": "iphonesimulator",
  "scheme": "Application",
  "configuration": "Debug",
  "architecture": "arm64",
  "package_fingerprint": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "package_resolution_mode": "none",
  "cache_roles": {
    "derived_data": "/private/cache/DerivedData",
    "source_packages": "/private/cache/DerivedData/SourcePackages",
    "repository_checkouts": "/private/cache/DerivedData/SourcePackages/checkouts",
    "artifacts": "/private/cache/DerivedData/SourcePackages/artifacts",
    "package_cache": "/private/cache/swiftpm"
  },
  "cache_paths": [
    "/private/cache/DerivedData",
    "/private/cache/DerivedData/SourcePackages",
    "/private/cache/DerivedData/SourcePackages/checkouts",
    "/private/cache/DerivedData/SourcePackages/artifacts",
    "/private/cache/swiftpm"
  ],
  "output_roles": {
    "result_bundle": "/private/results/Tests.xcresult"
  },
  "output_paths": [
    "/private/results/Tests.xcresult"
  ]
}
```

Use the paths Xcode actually resolved; this example does not authorize custom
cache redirection. Pass the canonical JSON and private harness to the CLI in
[coordinator setup](../../agent-harness/references/coordinator-setup.md).

Every mutating lease acquire goes through the explicitly configured
host-shared atomic coordinator backed by one private state file and its private
harness path/instance/script-hash binding, even when the
current run believes it is sequential. The private project registry and per-run
ledgers are evidence, not locks. Persist
the coordinator-issued receipt and fencing token, and verify the live receipt
again before reservation and immediately before the protected operation. Lease
TTL is at most one hour and longer work uses extending heartbeats. If no configured coordinator
is available, stop with `coordination_required`; do not create a daemon,
database, cache redirect, coordinator location, or worktree to bypass
coordination. Lease expiry alone never grants takeover: recovery must bind the
previous receipt/fence, use a different run's read-only observer to confirm the
owner and every child/tool process are dead, prove clean state, revalidate the
live resource, and advance the fence. These observations remain auditable host
evidence, not cryptographic truth.

On upgrade from an unversioned writer-key release, first quiesce all old tasks
and close their leases. Bootstrap the new coordinator only with an explicit
legacy-quiescence confirmation; never infer migration from an empty per-run
ledger.

## Release and failure

Release UI/device leases only after outstanding tool calls are cancelled or
finished, the intended artifacts are preserved, and per-run status overrides or
temporary launch state are recorded. Do not erase the device or remove another
project's installed app as release cleanup.

If one destination hangs, follow
[Simulator hang recovery](simulator-hang-recovery.md) within that lease. Do not
force-quit Xcode, reset CoreSimulator, or restart a host service while another
project has an active device/UI lease. A service-wide recovery requires an
inventory of all affected run IDs, quiescing/cancelling their outstanding calls,
releasing what can be safely released, acquiring the single host registry lease,
and explicit human approval. Each project keeps its own build success and
blocked runtime evidence. When discovery itself reports a runtime disk/store
failure, follow [runtime-disk registry recovery](runtime-disk-registry-recovery.md)
and do not let each project launch its own diagnostic request.

The ordered transition is: affected-run inventory; cancel or quiesce all
outstanding Simulator calls; mark each run's runtime evidence blocked; acquire
the host registry lease; perform one bounded diagnosis or the exact approved
recovery; verify with one runtime inventory; release the registry lease; acquire
one exact control-UDID lease; verify boot/install/launch; release the control
lease; then resume projects independently. The global registry and per-UDID
leases are never active together.
During this transition, select one recorded Simulator-capable provider for the
host-wide work, official-first, and leave all other providers idle. Do not close
unrelated tasks or terminate their integrations without explicit approval, and
do not restore provider fan-out immediately after recovery.

Reference: [Apple: Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).
