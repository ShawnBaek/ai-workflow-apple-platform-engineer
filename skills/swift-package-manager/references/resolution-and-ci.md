# Resolution and CI policy

## Inputs and fingerprint

Before resolving, capture a dependency-input fingerprint. Include the files that actually control the dependency graph: `Package.swift` and related manifests, the tracked `Package.resolved`, Xcode package references or their generator source, the selected Xcode/Swift toolchain, and relevant project container metadata. A changed fingerprint permits resolution; an unchanged fingerprint normally reuses the already-resolved graph.

Do not make every build a version-selection event. Resolution chooses versions and obtains checkouts; a build compiles the selected graph. An update is a deliberate request to reconsider eligible versions and needs its own reviewable diff.

## Lockfile policy

For an application or concrete Xcode project, commit the repository's tracked `Package.resolved` so developers and CI use the same selected graph. Preserve its existing location and generator conventions. For a reusable package library, avoid introducing a lockfile merely to constrain clients; its manifest should express supported version ranges.

If a project generator owns package references, edit the generator input and regenerate only when the project workflow explicitly authorizes regeneration. Never hand-edit a generated Xcode project as a shortcut.

## CI shape

1. Restore an input-keyed cache only when cache use is already approved by the repository.
2. Resolve dependencies explicitly when the fingerprint changed or the CI job has no valid resolved checkout.
3. Build/test with automatic resolution disabled for direct `xcodebuild` invocations, for example `-disableAutomaticPackageResolution`.
4. Save the result and report the lockfile/fingerprint used.

This prevents a network or registry change from silently changing the dependency graph during a normal build. It does not authorize cache deletion or a dependency update.

## Credentials

Use the existing credential mechanism only when access is authorized. Do not print tokens, private repository URLs with embedded credentials, keychain contents, or full environment dumps. A missing credential is an access blocker, not a reason to substitute a public dependency or mutate configuration.
