---
name: app-versioning
description: Safely change Apple app marketing and build versions while preserving the project’s real version source of truth.
---

# App Versioning

Use this skill to change an Apple app's marketing version or build number. It does not migrate SDKs, alter deployment targets, archive, upload, submit, or release an app.

## Locate the version authority first

Inspect the project before editing: XcodeGen specification, `.xcconfig` files, project build settings, and `Info.plist` values. Determine which one actually supplies `MARKETING_VERSION` / `CFBundleShortVersionString` and `CURRENT_PROJECT_VERSION` / `CFBundleVersion` for each affected app and extension.

- Edit the authoritative source once; do not blindly synchronize several files that merely mirror or inherit the values.
- Use `agvtool` only when the project already uses Apple Generic Versioning and it is demonstrably authoritative. Do not introduce it just to make a bump convenient.
- Preserve repository version policy and platform-specific overrides. If the project uses generated project files, edit the specification rather than generated output unless the project explicitly says otherwise.

## Verify only the changed contract

For every affected app or extension, inspect effective build settings and, when a proportionate host build is authorized, verify the built bundle's `CFBundleShortVersionString` and `CFBundleVersion`. Report the exact source changed, resolved values, target/configuration, and any target intentionally not built.

Do not create tests for a version-only change. Run the smallest relevant project validation; a full matrix is justified only when the project policy or changed shared version authority requires it.

## Boundary

Stop after the verified version update. Route archive, signing, notarization, upload, TestFlight, App Store submission, and release metadata to the appropriate approved release workflow, including its account and team checks.

## Sources

- [Apple: build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
- [Apple: preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution)
