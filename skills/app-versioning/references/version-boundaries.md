# Versioning Boundaries

Marketing and build versions are separate from SDK upgrades and distribution operations.

- An SDK/Xcode/SwiftPM update needs its own compatibility, dependency, and testing plan.
- Deployment-target changes affect availability and must not be bundled into a version bump by default.
- Archive, export, notarization, App Store Connect upload, TestFlight distribution, submission, and release are external operations. They require the applicable signing/account/team and publication approvals.
- Embedded bundles are not a separate release train. An app extension, including a widget, must carry the same `CFBundleShortVersionString` and `CFBundleVersion` as its containing app, and a watch app embedded in an iOS app must match its companion. Xcode's embedded-binary validation warns about an extension mismatch, and its WatchKit validation reports that the watch and companion values are "required to match". A bump that changes only the main app is incomplete. Update each existing per-target copy; recommend one inherited project- or `.xcconfig`-level value, and restructure only when the task or project policy allows it.
- Ask which release train a bundle follows only when it ships on its own: a separate App Store app, a watch-only app, or a macOS helper or tool that the project distributes or versions independently. Do not assume every such target should change.

The two validation messages above were read from the `DevToolsCore` framework of Xcode 27.1 and 27.2 beta on 2026-09-27. Apple's archived [TN2420](https://developer.apple.com/library/archive/technotes/tn2420/_index.html) states the same rule for app extensions and their containing apps, and an Apple DTS engineer repeats it in the [developer forums](https://developer.apple.com/forums/thread/730234).
