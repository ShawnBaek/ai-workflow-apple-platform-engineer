# Safe workflow templates

These are starting points, not paste-and-run promises. Resolve the project's
authoritative workspace/project, scheme, test plan, package lockfile, runner
labels, Xcode build, and private account policy before use. Do not regenerate
XcodeGen or change package versions inside a build job.

## Build and minimum-sufficient test

```yaml
name: Build and test

on:
  pull_request:

permissions:
  contents: read

concurrency:
  group: build-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

jobs:
  build:
    # Untrusted pull-request code runs only on an ephemeral GitHub-hosted Mac.
    # If this image lacks the required Xcode, use the separately gated trusted
    # workflow described below; never fall through to a persistent runner.
    runs-on: macos-latest
    timeout-minutes: 30
    env:
      WORKSPACE: App.xcworkspace
      SCHEME: App
      DESTINATION: platform=iOS Simulator,name=<approved-device>,OS=<approved-os>
      BUILD_RESULT_BUNDLE: BuildResults.xcresult
      TEST_RESULT_BUNDLE: TestResults.xcresult
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4

      - name: Record toolchain and package input
        run: |
          xcodebuild -version
          swift --version
          shasum -a 256 <path-to-Package.resolved>

      - name: Build for testing without dependency updates
        run: |
          set -o pipefail
          xcodebuild build-for-testing \
            -workspace "$WORKSPACE" \
            -scheme "$SCHEME" \
            -destination "$DESTINATION" \
            -disableAutomaticPackageResolution \
            -resultBundlePath "$BUILD_RESULT_BUNDLE"

      - name: Run the selected tests without rebuilding
        run: |
          set -o pipefail
          xcodebuild test-without-building \
            -workspace "$WORKSPACE" \
            -scheme "$SCHEME" \
            -destination "$DESTINATION" \
            -disableAutomaticPackageResolution \
            -resultBundlePath "$TEST_RESULT_BUNDLE" \
            -only-testing:<affected-test-identifier>

      - name: Preserve verification evidence
        # Opt in only after repository policy defines a privacy scan for the
        # result bundles. Do not upload raw personal-host logs or environment.
        if: always() && vars.PUBLISH_XCRESULT == 'true'
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
        with:
          name: verification-${{ github.run_id }}
          path: |
            BuildResults.xcresult
            TestResults.xcresult
          retention-days: 14
          if-no-files-found: warn
```

The package lockfile path differs between Swift packages and Xcode projects.
Resolve it with `swift-package-manager`. If a clean runner lacks dependency
checkouts, add one explicit resolution/check-out step using the committed
`Package.resolved`; do not update versions and do not repeat resolution before
each build/test action.

Use `-project` instead of `-workspace` only when the authoritative container is
the project. Replace the single affected test with the risk-derived selection
from `apple-platform-testing`. Build-product reuse is valid only for an
identical Xcode/SDK/scheme/configuration/destination/architecture/package/test
tuple.

Do not change `runs-on` in the pull-request job to a self-hosted label. When a
required Xcode build exists only on a persistent Mac, create a separate
`workflow_dispatch` job protected by a trusted environment, verify the exact
head SHA and actor before checkout, and run it only after a maintainer approves
that code for the isolated runner. Fork/outside-contributor code never reaches
that runner merely by opening or updating a pull request.

## Read-only runner disk report

```yaml
name: Runner disk report

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:
  audit:
    runs-on: ${{ vars.MACOS_RUNNER }}
    timeout-minutes: 5
    steps:
      - name: Capacity
        run: df -h
      - name: Xcode and Simulator inventory
        run: |
          du -sh "$HOME/Library/Developer/Xcode/DerivedData" 2>/dev/null || true
          du -sh "$HOME/Library/Developer/Xcode/Archives" 2>/dev/null || true
          du -sh "$HOME/Library/Developer/CoreSimulator" 2>/dev/null || true
          xcrun simctl list runtimes
```

This workflow reports only. Cleanup is a separate, itemized, approved operation.

## Release boundary

A release workflow should be manual or protected-environment gated, verify the
private Apple account/team before reading or changing account data, build/archive
from an approved version/commit, and stop before upload/submission unless those
external writes were explicitly authorized. Route the concrete implementation
through `app-versioning`, `xcodebuild`, and `app-store-connect`.

Never put an App Store submission, certificate rotation, broad cache cleanup, or
Project/branch-rule mutation into an ordinary PR build job.

References:

- [GitHub workflow syntax](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions)
- [Apple Swift package CI guidance](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows)
- [Xcode command-line tools](https://developer.apple.com/documentation/xcode/xcode-command-line-tools)
