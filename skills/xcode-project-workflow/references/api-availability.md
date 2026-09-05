# Choose APIs from the project's supported platform range

This reference extends `xcode-project-workflow`; it is not another intake skill. Resolve this information once per affected target/configuration and refresh it when it changes.

## Read the actual support contract

Record the target/platform, minimum deployment version, selected Xcode/SDK build, Swift compiler and language mode, and current test destination. Inspect the authoritative source: build settings and xcconfig inheritance, XcodeGen specification when used, and package platform declarations. App extensions, watch apps, and packages may have different minima.

Do not infer the minimum from the installed Simulator, the Mac's OS, the newest SDK, or another target. Do not alter minimum OS, signing, capabilities, or project-generation settings merely to make an example compile.

## Choose the implementation

| Condition | Action |
| --- | --- |
| API exists in the selected SDK and supports the target's minimum OS | Use it directly if it fits the task; avoid redundant version branches |
| API exists in the SDK but requires a newer OS than the minimum | Isolate the newer implementation with appropriate availability declarations/checks and an accepted fallback |
| SDK/compiler cannot express the API | Use a supported implementation or identify the required toolchain change; a runtime check cannot make a missing declaration compile |
| The user's accepted support range is latest OS only | Prefer suitable current APIs; do not maintain compatibility layers for unsupported releases |
| A new API is beta | Label the dependency and check current release notes; do not present it as the stable production baseline |
| Runtime feature also depends on hardware, model readiness, language, permissions, or services | Check those conditions as well as OS availability and define the unavailable state |

Use `@available` for declaration availability and `if #available`/`guard #available` for supported runtime branches. `#if canImport` checks module importability, not whether a particular API or model works at runtime. Swift language-version checks and SDK availability solve different problems. [Swift attributes](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/attributes/), [Swift statements](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/statements/).

Keep compatibility at a small feature boundary. A fallback can be the existing non-AI experience or a clearly unavailable optional feature. It need not be a second model provider or a duplicate app architecture. Explain meaningful differences in product behavior.

## Use official evidence with the right scope

Use the selected SDK's declarations and compiler diagnostics alongside live Apple API documentation and release notes. Use WWDC sessions for design intent and examples, checking each example against the current SDK. For Swift language/concurrency behavior, consult the Swift documentation and the project's actual compiler settings.

Record the API, platform, introduced version, beta/deprecation state, URL, and checked date for a version-sensitive decision. If documentation and SDK declarations disagree, report the discrepancy and verify the actual build/runtime; do not silently choose the more convenient number. Do not infer every platform's support from one framework overview or one iOS symbol.

Account for back deployment: a newer SDK can provide an API to older supported systems. Inspect declaration attributes and compiler behavior rather than using its announcement date as the minimum. For example, the SDK inspected on 2026-09-05 marks `SystemLanguageModel.contextSize` available from OS 26.0 and back-deployed before 26.4; recheck the project's SDK before applying that observation. [API documentation](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize).

For coding-agent tooling, use the capabilities exposed by the selected Xcode installation. Prefer one official skill/tool exposure for the task, discover what is actually callable, and fall back explicitly when unavailable. Do not load duplicate exported and built-in copies or install another orchestration framework as a prerequisite. [External agents and Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode), [customizing agents](https://developer.apple.com/documentation/xcode/extending-and-customizing-agents).

## Keep verification proportional

Build the affected target with its real deployment settings. Exercise the fallback on an available representative older supported OS and the modern branch on a supported newer OS when the change touches both. If the oldest runtime is unavailable, state the uncovered range; compile success does not prove runtime behavior.

Do not multiply every OS by every device, locale, appearance, and text size for a minor change. Select the combinations affected by the implementation and its meaningful risks. Test model availability separately from synthetic UI fixtures. Use physical-device checks for unsupported Simulator features and performance claims.

Return a compact support statement, for example: “App minimum remains iOS 18; the optional OS 26 language feature uses the existing manual flow when unavailable; the OS 27 path is separate and requires the documented SDK.” This is an illustrative support policy, not a required minimum for every project.
