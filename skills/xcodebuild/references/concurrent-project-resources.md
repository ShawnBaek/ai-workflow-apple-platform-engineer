# Concurrent Xcode project resource isolation

Use this when two or more authoritative Xcode projects are active on the same
Mac. Parallel source reading is unrestricted; mutable Xcode, build-cache,
Simulator/device, and UI-session state is keyed and leased independently.

## Namespace every run

Record `run_id`, repository fingerprint and canonical root, exact Xcode
container, branch/HEAD, selected Xcode build, scheme/configuration/architecture,
resolved DerivedData and SourcePackages locations, bundle identifier, app bundle
hash, tool session ID, platform/runtime, and exact destination UDID.

Do not address a mutable destination by display name or the ambiguous `booted`
alias. Names such as “iPhone 17 Pro” are not unique, and several devices may be
booted. Every boot/install/uninstall/launch/privacy/location/status-bar/UI/
screenshot operation uses the leased UDID explicitly.

## Lease boundaries

- **Project mutation:** serialize per canonical container. A second agent may
  read a frozen snapshot but may not modify the project/spec concurrently.
- **Build:** key by repository/container SHA, Xcode/SDK, scheme, configuration,
  architecture, package fingerprint, and resolved cache paths. Different tuples
  may run together; an identical mutable cache/result path may not.
- **Package resolution:** serialize when projects explicitly share a package
  checkout/cache path. Never redirect caches merely to avoid a lease.
- **Simulator/device:** one active owner per UDID. Separate projects receive
  separate Simulator devices even when their runtime/model matches, especially
  when bundle identifiers collide.
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
- **macOS:** native app/window interaction is not a Simulator lease. Serialize
  the relevant GUI/test session and bundle/process separately.

Default Xcode user-level caches remain valid. If simultaneous operations truly
need cache isolation, that is an explicit concurrent-validation choice under the
project policy; use a generic approved cache location and record it in the build
tuple. A cache is never an alternate source checkout.

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
do not restore provider fan-out immediately after a reboot.

Reference: [Apple: Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices).
