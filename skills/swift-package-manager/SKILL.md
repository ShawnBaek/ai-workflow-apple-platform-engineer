---
name: swift-package-manager
description: Manage Swift Package Manager dependencies, resolution, builds, and CI without unnecessary package churn or unsafe cache cleanup.
---

# Swift Package Manager

Use this skill when an Apple app, Xcode project, or Swift package needs dependency diagnosis, a package-version change, or CI dependency policy. Prefer Apple/Xcode documentation and tools; do not copy or replace Apple-provided skills.

## Decide before changing dependencies

- Identify the dependency owner: `Package.swift`, an Xcode project/workspace, or a generated project specification. Change the source of truth, not a derived file.
- Keep **resolve**, **update**, and **build** separate. Resolve only when dependency inputs changed or an explicit resolution is requested; update only when the requested version policy permits it.
- Commit `Package.resolved` for a leaf app or project when the repository tracks it. Do not add it to reusable library packages merely to force downstream consumers' versions.
- Before a direct Xcode CI build, resolve dependencies explicitly when inputs changed, then use `-disableAutomaticPackageResolution` for the build.
- Never delete package caches, Derived Data, credentials, or checkouts as a first response. Inspect the failing layer first.

Read [resolution and CI policy](references/resolution-and-ci.md) for lockfile, fingerprint, and CI decisions. Read [failure diagnosis](references/failure-diagnosis.md) when resolution or a build fails.

## Evidence and handoff

Record the manifest/lockfile inputs, toolchain, command and destination, whether resolution was reused or changed, and the first actionable failure. Redact repository URLs or logs that contain credentials. Keep any cache cleanup scoped, approved, and recoverable where possible.

## Sources

- [Apple: building Swift packages or apps using them in CI](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows)
- [SwiftPM: resolving package versions](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/resolvingpackageversions/)
