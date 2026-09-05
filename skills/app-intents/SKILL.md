---
name: app-intents
description: Expose Apple app actions and entities through App Intents, App Shortcuts, Siri, and relevant system surfaces. Use for intent parameters, entity queries, discoverability, and newer Apple Intelligence integrations while preserving the project's minimum supported OS and existing domain logic.
---

# App Intents

Own the app-to-system action and entity boundary. Prefer an available Apple-authored skill for exact SDK adoption. An App Intent and a Foundation Models `Tool` are separate interfaces; share an existing domain operation where useful, without assuming one automatically registers the other.

## Establish one useful action

Use `xcode-project-workflow` before project changes. Resolve the affected target, minimum OS, SDK, and intended surface. App Intents predates WWDC26; newer entity, execution, and Apple Intelligence APIs have separate availability. Read the precise declaration before using it. [AppIntent](https://developer.apple.com/documentation/appintents/appintent).

Describe the user's action, its inputs, result, required permissions, and whether it changes data. Trace the existing implementation first. Support SwiftUI, storyboard/XIB, and programmatic UIKit apps through their actual domain and navigation paths; no UI rewrite is required for intent adoption.

## Implement the system boundary

- Keep intent execution thin: validate inputs and call the existing operation. Determine which process can execute it, what storage/dependencies that process can access, and whether foreground UI is required. Avoid initializing an entire app screen merely to execute an action.
- Expose only relevant entities and properties. Use stable identifiers, meaningful display values, and localized metadata. Create a small representation when persistence objects cannot safely cross this boundary; do not mirror every model automatically. [AppEntity](https://developer.apple.com/documentation/appintents/appentity).
- Resolve identifiers against current accessible data. Deleted or inaccessible entities must not become fabricated results. Bound queries and handle ambiguity through the framework's appropriate disambiguation flow. [EntityQuery](https://developer.apple.com/documentation/appintents/entityquery).
- Apply authentication, permission, and confirmation requirements inside the actual operation. Make retryable actions safe and handle cancellation without claiming committed work was rolled back.
- Add App Shortcuts and discoverability metadata for useful user actions. Verify phrases, parameter presentation, and result behavior on the intended surface. [AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider).
- Add Spotlight indexing, donations, or annotations only for a defined surface and data policy. Account for edits, deletion, sign-out, and access changes; previously indexed content must not bypass current access checks.

## Adopt newer capabilities selectively

For a compatible SDK/OS and a concrete need, inspect newer entity collections, cross-device identities, richer parameters, long-running intent cancellation, and execution-target controls. Avoid generating compatibility wrappers for every new symbol. Apple describes these in [WWDC26 App Intents capabilities](https://developer.apple.com/videos/play/wwdc2026/345/).

Do not promise a Siri/Apple Intelligence experience solely because the intent compiles. Verify the intended system support, device, locale, account state where relevant, and actual discoverability. A source declaration is only one part of that integration.

## Verify the affected flow

Use focused Swift checks for parameter/domain validation and entity resolution. Select edge cases relevant to the change, such as a deleted entity, ambiguous name, denied access, or repeated execution. Run the action from its intended system surface; preserve the result and resulting app state.

Use an existing UI test only where interaction coverage warrants it. A short manual Simulator/device exercise with a screenshot or recording can be sufficient for a narrow UI integration; unsupported system intelligence needs a suitable physical device or an explicit blocked result. Avoid a new cross-app XCUITest framework.

Return supported OS/surface, affected action and domain code, focused test results, and concise evidence. Follow existing signing, commit, and PR approval rules. This skill does not grant distribution permissions.
