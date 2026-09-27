---
name: app-versioning
description: Change Apple app marketing and build versions at the project's real source of truth. Use when bumping a version or build number (MARKETING_VERSION, CURRENT_PROJECT_VERSION).
---

# App Versioning

Use this skill to change an Apple app's marketing version or build number. It does not migrate SDKs, alter deployment targets, archive, upload, submit, or release an app.

## Locate the version authority first

Inspect the project before editing: XcodeGen specification, `.xcconfig` files, project build settings, and `Info.plist` values. Determine which one actually supplies `MARKETING_VERSION` / `CFBundleShortVersionString` and `CURRENT_PROJECT_VERSION` / `CFBundleVersion` for each affected app and extension. When values differ between targets or come from several places, follow [version source detection](references/version-source-detection.md).

- Edit the authoritative source once; do not blindly synchronize several files that merely mirror or inherit the values.
- Change an app and the bundles it embeds together. An app extension (including a widget) and a watch app inside an iOS app must carry the containing app's `CFBundleShortVersionString` and `CFBundleVersion`; Xcode's embedded-binary validation reports a mismatch. Update every per-target copy that exists; recommend one inherited project- or `.xcconfig`-level value, but restructure existing per-target settings only when the task or project policy allows it. Ask only about a bundle that ships on its own; see [version boundaries](references/version-boundaries.md).
- Use `agvtool` only when the project already uses Apple Generic Versioning and it is demonstrably authoritative. Do not introduce it just to make a bump convenient.
- Preserve repository version policy and platform-specific overrides. If the project uses generated project files, edit the specification rather than generated output unless the project explicitly says otherwise.

For a build intended for upload, `CFBundleVersion` must be higher than every build already uploaded for that marketing version, and a macOS build must be higher than every earlier macOS build of the app. Increment it before archiving unless the project's release path assigns it: Xcode's App Store Connect distribution can replace it at upload ("Manage version and build number"), and CI may set it, so the uploaded value can differ from the project's.

## Verify only the changed contract

For every affected app, extension, and embedded watch app, inspect effective build settings and, when a proportionate host build is authorized, verify the built bundle's `CFBundleShortVersionString` and `CFBundleVersion`. Embedded bundles must equal their containing app. Report the exact source changed, resolved values, target/configuration, and any target intentionally not built.

Do not create tests for a version-only change. Run the smallest relevant project validation; a full matrix is justified only when the project policy or changed shared version authority requires it.

## Boundary

Stop after the verified version update. Route archive, signing, notarization, upload, TestFlight, App Store submission, and release metadata to the appropriate approved release workflow, including its account and team checks.

## Sources

- [Apple: build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference)
- [Apple: preparing your app for distribution](https://developer.apple.com/documentation/xcode/preparing-your-app-for-distribution) (build-string increments and Xcode-managed build numbers)
- [Apple: `CFBundleVersion`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleversion) and [`CFBundleShortVersionString`](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleshortversionstring)
- [Apple TN2420: version numbers and build numbers](https://developer.apple.com/library/archive/technotes/tn2420/_index.html) (archived; extensions match their containing app, and release trains)
- [Apple DTS: an app extension's versions must match its app](https://developer.apple.com/forums/thread/730234)
