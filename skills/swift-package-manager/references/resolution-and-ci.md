# Resolution and CI policy

## Inputs and fingerprint

Before resolving, capture a dependency-input fingerprint. Include the files that actually control the dependency graph: `Package.swift` and related manifests, the tracked `Package.resolved`, Xcode package references or their generator source, the selected Xcode/Swift toolchain, and relevant project container metadata. A changed fingerprint permits resolution; an unchanged fingerprint normally reuses the already-resolved graph.

Do not make every build a version-selection event. Resolution chooses versions and obtains checkouts; a build compiles the selected graph. An update is a deliberate request to reconsider eligible versions and needs its own reviewable diff.

Resolution is a source mutation, not merely cache population. Use
`package_resolution_mode: swiftpm_lockfile` for standalone/package lockfile
resolution and `xcode_project_packages` when Xcode package metadata may change.
Every build tuple, including `package_resolution_mode: none`, requires the same
run's source-writer lease before the build tuple because SwiftPM/Xcode can still
attempt an implicit metadata write. In the two resolution modes, that lease
authorizes the intended lockfile change;
the Xcode mode additionally requires the exact project-mutation lease. Acquire
source → project (if applicable) → build and release in reverse. A plain build
uses `none` plus a resolution-disabled invocation. The coordinator rejects any
build without the supporting source lease and serializes builds for one logical
repository.

## Lockfile policy

For an application or concrete Xcode project, commit the repository's tracked `Package.resolved` so developers and CI use the same selected graph. Preserve its existing location and generator conventions. For a reusable package library, avoid introducing a lockfile merely to constrain clients; its manifest should express supported version ranges.

If a project generator owns package references, edit the generator input and regenerate only when the project workflow explicitly authorizes regeneration. Never hand-edit a generated Xcode project as a shortcut.

## CI shape

1. Restore an input-keyed cache only when cache use is already approved by the repository.
2. Resolve dependencies explicitly when the fingerprint changed or the CI job has no valid resolved checkout.
3. Build/test with automatic resolution disabled: use
   `-disableAutomaticPackageResolution` for direct `xcodebuild`, or
   `--disable-automatic-resolution` (`--force-resolved-versions`) for
   standalone `swift build`/`swift test`.
4. Compare tracked `Package.resolved`, manifest, generator, and project metadata
   before/after. Any drift makes a declared `none` run blocked rather than a
   successful build-only result.
5. Save the result and report the lockfile/fingerprint used.

This prevents a network or registry change from silently changing the dependency graph during a normal build. It does not authorize cache deletion or a dependency update.

## Concurrent cache ownership

Record five named `cache_roles`: `derived_data`, `source_packages`,
`repository_checkouts`, `artifacts`, and `package_cache`. For Xcode these are the
actual DerivedData and SourcePackages locations. For standalone `swift build` or
`swift test`, `derived_data` is the logical `.build` products root and
`source_packages` is its workspace-state location. `cache_paths` must contain
the exact unique values of all five roles. Builds for one logical repository
always serialize; builds from different repositories also serialize when any recorded
mutable cache path intersects, even when their schemes or other tuple fields
differ. Equal paths, parent/child paths, and resolved filesystem aliases all
conflict; case and Unicode spelling aliases are conservatively serialized for
case-insensitive Apple filesystems. Use the configured host-shared atomic coordinator for every mutable
cache acquisition, even when a run believes it is sequential; a per-run ledger
is evidence, not a lock. Do not redirect caches, create a worktree, or clear
package state merely to avoid `coordination_required`.

For a standalone package, a valid role mapping is:

```json
{
  "container_path": "/private/source/Package.swift",
  "package_resolution_mode": "swiftpm_lockfile",
  "cache_roles": {
    "derived_data": "/private/source/.build",
    "source_packages": "/private/source/.build/workspace-state.json",
    "repository_checkouts": "/private/source/.build/checkouts",
    "artifacts": "/private/source/.build/artifacts",
    "package_cache": "/private/cache/swiftpm"
  },
  "cache_paths": [
    "/private/source/.build",
    "/private/source/.build/workspace-state.json",
    "/private/source/.build/checkouts",
    "/private/source/.build/artifacts",
    "/private/cache/swiftpm"
  ],
  "output_roles": {},
  "output_paths": []
}
```

The full build descriptor also includes repository fingerprint, selected Swift
toolchain in `xcode_build`, SDK, scheme/product, configuration, architecture,
package-input fingerprint, package-resolution mode, and every explicit result,
archive, export, or diagnostic output path. SwiftPM's `artifacts` cache role is
not an Xcode result or archive destination. These names are a shared coordination schema;
they do not imply that standalone SwiftPM creates Xcode DerivedData.

## Credentials

Use the existing credential mechanism only when access is authorized. Do not print tokens, private repository URLs with embedded credentials, keychain contents, or full environment dumps. A missing credential is an access blocker, not a reason to substitute a public dependency or mutate configuration.
