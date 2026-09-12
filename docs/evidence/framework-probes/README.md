# Reproducible Apple framework probes

These five standalone Swift programs exercise persistence, App Intents, Foundation Models, Evaluations, and model-integration APIs without network access, downloads, account credentials, signing, Simulator use, or external services. They write only to process-owned temporary directories, except `EvaluationsAudit`, which requires an existing caller-selected output directory.

The full sequence requires Apple silicon, macOS 27 beta and the selected Xcode 27 beta SDK; individual older-API probes have lower deployment targets. Run these commands from this directory, adjusting `DEVELOPER_DIR` to the selected Xcode. Compiler work is serialized.

```sh
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
mkdir -p .build/output

xcrun swiftc -j 1 -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 PersistenceAudit.swift -o .build/PersistenceAudit
./.build/PersistenceAudit

xcrun swiftc -j 1 -parse-as-library -swift-version 6 -target arm64-apple-macosx13.0 AppIntentsAudit.swift -o .build/AppIntentsAudit
./.build/AppIntentsAudit

xcrun swiftc -j 1 -parse-as-library -swift-version 6 -target arm64-apple-macosx26.0 FoundationModelsAudit.swift -o .build/FoundationModelsAudit
./.build/FoundationModelsAudit

developer_frameworks="$(xcrun --sdk macosx --show-sdk-platform-path)/Developer/Library/Frameworks"
xcrun swiftc -j 1 -parse-as-library -swift-version 6 -target arm64-apple-macosx27.0 -F "$developer_frameworks" -framework Evaluations EvaluationsAudit.swift -o .build/EvaluationsAudit
DYLD_FRAMEWORK_PATH="$developer_frameworks" ./.build/EvaluationsAudit .build/output

xcrun swiftc -j 1 -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 ModelIntegrationAudit.swift -o .build/ModelIntegrationAudit
./.build/ModelIntegrationAudit
```

These are real macOS executable runs. `PersistenceAudit` performs a file-backed Core Data inferred migration and a SwiftData round trip. `AppIntentsAudit` calls `perform()` directly and tests entity filtering and idempotence; it does not establish Siri or Shortcuts discoverability. `EvaluationsAudit` executes three deterministic samples, retains an intentional failing sample, and atomically writes `.build/output/evaluation-result.json`. `ModelIntegrationAudit` verifies rejection of a missing Core ML model with CPU-only configuration and, on macOS 27, CoreAI option/compute-unit discovery. On older macOS it explicitly reports that CoreAI is unavailable. It measures no load-time or memory bound and performs no inference because no approved preconverted artifact is supplied.

`FoundationModelsAudit` checks system-model and locale availability before any generation. On the audited host the model reported `modelNotReady`: guided schema construction and direct typed-tool bounds were exercised, while guided generation and a model-selected tool call were correctly skipped. Re-running on a host where the system model is already available will execute those two model-backed branches; this program never installs or downloads a model.

The same sources can be compile-checked against iPhoneOS SDK interfaces without launching a device or Simulator:

```sh
iphone_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
iphone_developer_frameworks="$(xcrun --sdk iphoneos --show-sdk-platform-path)/Developer/Library/Frameworks"

xcrun swiftc -j 1 -parse-as-library -swift-version 6 -typecheck -sdk "$iphone_sdk" -target arm64-apple-ios17.0 PersistenceAudit.swift
xcrun swiftc -j 1 -parse-as-library -swift-version 6 -typecheck -sdk "$iphone_sdk" -target arm64-apple-ios16.0 AppIntentsAudit.swift
xcrun swiftc -j 1 -parse-as-library -swift-version 6 -typecheck -sdk "$iphone_sdk" -target arm64-apple-ios26.0 FoundationModelsAudit.swift
xcrun swiftc -j 1 -parse-as-library -swift-version 6 -typecheck -sdk "$iphone_sdk" -target arm64-apple-ios27.0 -F "$iphone_developer_frameworks" EvaluationsAudit.swift
xcrun swiftc -j 1 -parse-as-library -swift-version 6 -typecheck -sdk "$iphone_sdk" -target arm64-apple-ios17.0 ModelIntegrationAudit.swift
```

The iPhoneOS commands prove SDK compilation only. The Evaluations and CoreAI interfaces require the selected Xcode 27 beta SDK; their guarded use does not raise the deployment target of the surrounding model-integration probe.
