# GitHub Actions workflow templates (macOS self-hosted)

The canonical `.github/workflows/*.yml` files for an indie iOS / macOS / watchOS app. Built for a self-hosted Mac runner labeled `[self-hosted, macOS, arm64, xcode]`. Installs missing packages via **Homebrew** (Mac-first audience). Always cleans up after itself.

## File 1 — `build-and-test.yml`

Runs on every PR and on push to main. Fails the PR if the project doesn't build or tests don't pass.

```yaml
name: Build and Test

on:
  pull_request:
  push:
    branches: [main]

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    runs-on: [self-hosted, macOS, arm64, xcode]
    timeout-minutes: 30

    env:
      SCHEME: ${{ vars.APP_SCHEME }}           # e.g. MyApp
      WORKSPACE: ${{ vars.APP_WORKSPACE }}     # e.g. MyApp.xcworkspace
      DEVICE: ${{ vars.SIMULATOR_NAME }}       # e.g. iPhone 16

    steps:
      - uses: actions/checkout@v4

      - name: Show environment
        run: |
          xcodebuild -version
          xcrun simctl list devices booted
          brew --version

      - name: Generate Xcode project (XcodeGen projects only)
        run: |
          if [ -f project.yml ] || [ -f project.yaml ]; then
            brew list xcodegen 2>/dev/null || brew install xcodegen
            xcodegen generate
          fi

      - name: Resolve SPM dependencies
        run: xcodebuild -resolvePackageDependencies -workspace "$WORKSPACE" -scheme "$SCHEME"

      - name: Build
        run: |
          set -o pipefail
          xcodebuild build \
            -workspace "$WORKSPACE" \
            -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,name=$DEVICE" \
            -configuration Debug \
            | tee build.log

      - name: Test
        run: |
          set -o pipefail
          xcodebuild test \
            -workspace "$WORKSPACE" \
            -scheme "$SCHEME" \
            -destination "platform=iOS Simulator,name=$DEVICE" \
            -resultBundlePath TestResults.xcresult \
            | tee test.log

      - name: Upload logs on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: build-logs-${{ github.run_id }}
          path: |
            build.log
            test.log
            TestResults.xcresult
          retention-days: 7

      - name: Cleanup (always runs)
        if: always()
        run: |
          rm -rf ~/Library/Developer/Xcode/DerivedData/*
          rm -f build.log test.log
          rm -rf TestResults.xcresult
          xcrun simctl shutdown all || true
          xcrun simctl delete unavailable || true
```

## File 2 — `release-testflight.yml`

Manual trigger (`workflow_dispatch`). Archives, exports the IPA, uploads to TestFlight via `asc`.

```yaml
name: Release to TestFlight

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Marketing version (e.g. 1.2.3)'
        required: true
      build:
        description: 'Build number (CFBundleVersion)'
        required: true

jobs:
  release:
    runs-on: [self-hosted, macOS, arm64, xcode]
    timeout-minutes: 45

    env:
      SCHEME: ${{ vars.APP_SCHEME }}
      WORKSPACE: ${{ vars.APP_WORKSPACE }}
      APP_ID: ${{ vars.ASC_APP_ID }}           # numeric App Store Connect app ID
      ASC_KEY_ID: ${{ vars.ASC_KEY_ID }}       # public — env var
      ASC_ISSUER_ID: ${{ vars.ASC_ISSUER_ID }} # public — env var
      ASC_PRIVATE_KEY: ${{ secrets.ASC_PRIVATE_KEY }} # secret — full .p8 contents

    steps:
      - uses: actions/checkout@v4

      - name: Ensure asc is installed
        run: |
          if ! command -v asc >/dev/null 2>&1; then
            brew install asc
          fi
          asc --version

      - name: Generate Xcode project (XcodeGen projects only)
        run: |
          if [ -f project.yml ] || [ -f project.yaml ]; then
            brew list xcodegen 2>/dev/null || brew install xcodegen
            xcodegen generate
          fi

      - name: Set version
        # If the project uses .xcodeproj directly: use agvtool.
        # If the project uses XcodeGen (project.yml is the source of truth):
        # patch project.yml + regenerate the .xcodeproj. agvtool would write
        # into the generated file and the next `xcodegen generate` would
        # overwrite it.
        run: |
          if [ -f project.yml ] || [ -f project.yaml ]; then
            YAML=$([ -f project.yml ] && echo project.yml || echo project.yaml)
            sed -i '' "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${{ inputs.version }}\"/g" "$YAML"
            sed -i '' "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"${{ inputs.build }}\"/g" "$YAML"
            xcodegen generate
          else
            agvtool new-marketing-version "${{ inputs.version }}"
            agvtool new-version -all "${{ inputs.build }}"
          fi

      - name: Archive
        run: |
          set -o pipefail
          xcodebuild archive \
            -workspace "$WORKSPACE" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -archivePath ./build/MyApp.xcarchive \
            | tee archive.log

      - name: Export IPA
        run: |
          xcodebuild -exportArchive \
            -archivePath ./build/MyApp.xcarchive \
            -exportPath ./build \
            -exportOptionsPlist .github/ExportOptions.plist

      - name: Upload to TestFlight via asc
        run: |
          asc auth login --key-id "$ASC_KEY_ID" --issuer-id "$ASC_ISSUER_ID" \
            --private-key <(echo "$ASC_PRIVATE_KEY")
          asc builds upload --app "$APP_ID" --ipa ./build/MyApp.ipa

      - name: Upload archive on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: release-logs-${{ github.run_id }}
          path: |
            archive.log
            ./build/*.ipa
          retention-days: 14

      - name: Cleanup
        if: always()
        run: |
          rm -rf ./build
          rm -f archive.log
          rm -rf ~/Library/Developer/Xcode/DerivedData/*
          xcrun simctl shutdown all || true
```

## File 3 — `weekly-cleanup.yml` (highly recommended on long-lived runners)

Disk fills up fast on a runner. Run this every Sunday at 3am:

```yaml
name: Weekly Runner Cleanup

on:
  schedule:
    - cron: '0 10 * * SUN'    # 10:00 UTC Sun = 3am PT / 6am ET
  workflow_dispatch:

jobs:
  cleanup:
    runs-on: [self-hosted, macOS, arm64]
    steps:
      - name: Disk before
        run: df -h /

      - name: Purge DerivedData
        run: rm -rf ~/Library/Developer/Xcode/DerivedData/*

      - name: Purge Xcode caches
        run: |
          rm -rf ~/Library/Caches/com.apple.dt.Xcode/*
          rm -rf ~/Library/Developer/CoreSimulator/Caches/*

      - name: Delete unavailable simulators
        run: xcrun simctl delete unavailable

      - name: Erase booted simulators (resets them clean)
        run: xcrun simctl erase all

      - name: Prune Homebrew cache
        run: brew cleanup -s --prune=all

      - name: Prune SPM cache
        run: rm -rf ~/Library/Caches/org.swift.swiftpm

      - name: Prune CocoaPods cache (if used)
        run: |
          if command -v pod >/dev/null 2>&1; then
            pod cache clean --all
          fi

      - name: Prune runner work directory
        run: rm -rf ~/actions-runner/_work/*/  # keeps the folder, drops contents

      - name: Disk after
        run: df -h /
```

## File 4 — `ExportOptions.plist` (commit alongside the workflow)

Path referenced by the release workflow. Adjust `teamID` and `provisioningProfiles` to your app:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store</string>
    <key>teamID</key>
    <string>YOUR_TEAM_ID</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>uploadSymbols</key>
    <true/>
    <key>uploadBitcode</key>
    <false/>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
```

## When the project already has a `Makefile`

Many indie repos ship a `Makefile` with entry points like `make build-ios`, `make build-watch`, `make archive-ios` that wrap the right `xcodebuild` invocation (with the right `-project` vs `-workspace`, the right destination, the right derived-data path, etc.).

If a `Makefile` exists at the repo root and has the targets you need, **call them from CI instead of duplicating the xcodebuild flags.** Keeps the local-dev command and the CI command in lockstep — when one changes, both change.

```yaml
      - name: Build iOS (uses Makefile)
        run: |
          set -o pipefail
          make build-ios 2>&1 | tee ios-build.log
```

Detection check: before adding raw `xcodebuild` steps, `grep -E '^[a-z-]+:' Makefile` to list available targets. Match the workflow's intent to the targets the developer already maintains.

## Project vs workspace — pick the flag the project actually uses

The template above uses `-workspace`. Many indie XcodeGen projects produce a `.xcodeproj` without a `.xcworkspace` — in that case use `-project` instead. If unsure: `ls *.xcworkspace *.xcodeproj 2>/dev/null` after generating; pick whichever exists.

## Workflow file conventions

- **One file per pipeline.** `build-and-test.yml`, `release-testflight.yml`, `weekly-cleanup.yml`. Don't merge unrelated triggers into one file.
- **`concurrency` block on PR builds.** Cancels the in-flight build when the developer pushes again — saves runner time.
- **`timeout-minutes`** on every job. A hung build holds the runner forever.
- **`set -o pipefail` + `tee`** on every long-running command. Lets you upload the log as an artifact on failure.
- **`if: always()`** on the cleanup step. Cleanup must run whether the build passed, failed, or timed out.
- **`actions/upload-artifact@v4` with `retention-days`.** Don't keep logs forever — 7–14 days is plenty.
