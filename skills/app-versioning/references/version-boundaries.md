# Versioning Boundaries

Marketing and build versions are separate from SDK upgrades and distribution operations.

- An SDK/Xcode/SwiftPM update needs its own compatibility, dependency, and testing plan.
- Deployment-target changes affect availability and must not be bundled into a version bump by default.
- Archive, export, notarization, App Store Connect upload, TestFlight distribution, submission, and release are external operations. They require the applicable signing/account/team and publication approvals.
- If a requested version is ambiguous across app, extensions, watch app, widgets, or macOS helpers, stop and ask which bundles share the release train rather than assuming all targets should change.
