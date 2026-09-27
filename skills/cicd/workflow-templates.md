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
    # Name the image: macos-latest moves to a new image, default Xcode and
    # Simulator runtimes without a repository change. If no hosted image has
    # the required Xcode, use the separately gated trusted workflow described
    # below; never fall through to a persistent runner.
    runs-on: macos-26
    timeout-minutes: 30
    env:
      # The repository's Xcode pin: a versioned path on that image and the
      # build it must resolve to. Hosted names can be symlinks, even to a beta.
      DEVELOPER_DIR: /Applications/Xcode_<approved-version>.app/Contents/Developer
      XCODE_BUILD: <approved-ProductBuildVersion>
      WORKSPACE: App.xcworkspace
      SCHEME: App
      DESTINATION: platform=iOS Simulator,name=<approved-device>,OS=<approved-os>
      BUILD_RESULT_BUNDLE: BuildResults.xcresult
      TEST_RESULT_BUNDLE: TestResults.xcresult
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          persist-credentials: false

      - name: Verify the pinned Xcode and record inputs
        run: |
          set -euo pipefail
          actual="$(xcodebuild -version | awk '/^Build version/ { print $3 }')"
          if [ "$actual" != "$XCODE_BUILD" ]; then
            echo "::error::DEVELOPER_DIR selects Xcode build $actual, not $XCODE_BUILD"
            exit 1
          fi
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

Choose the image label and the Xcode together from the image's published
software list, and write both into the workflow file. Do not take the Xcode path
from a repository variable: under `xcode-project-workflow`'s
[selection rule](../xcode-project-workflow/references/xcode-selection.md#choose-by-precedence),
a versioned `DEVELOPER_DIR` path in CI is the project's pin, so local agents
use the same version, while an unresolvable variable is no pin. The one
exception is a job that the repository's documentation names as a
compatibility-floor lane: it keeps proving the oldest supported Xcode, and
local agents treat its version as a minimum instead. Either way, CI keeps its
versioned path until a reviewed change moves it; it never floats to the image
default or the newest installed Xcode. The build check fails fast when the path resolves to
a different build. `DEVELOPER_DIR` changes nothing outside the job; do not run
`xcode-select --switch` in a job that can reach a persistent runner.

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

## Signed TestFlight upload

A job that signs and uploads a build needs three things: the App Store Connect
API key (`.p8`), the distribution certificate with its private key (`.p12`),
and the App Store distribution provisioning profile. A hosted runner starts
with none of them and has no Xcode account to fetch a profile, so the job
installs all three itself. Store them, base64-encoded, only as secrets of a
protected environment. Give that environment required reviewers, prevent
self-review, and a deployment-branch rule. Environment secrets reach a job only
after a required reviewer approves it, so approving this job approves one upload
of one reviewed commit. Distribution to TestFlight groups and App Review
submission stay separate `app-store-connect` gates.

```yaml
name: TestFlight upload

on:
  workflow_dispatch:
    inputs:
      release_sha:
        description: Reviewed commit; must be the head of the selected branch
        required: true
        type: string

permissions: {}

concurrency:
  group: testflight-upload
  cancel-in-progress: false

jobs:
  upload:
    environment: testflight
    permissions:
      contents: read
    # Ephemeral hosted runner. Read the argument note below before choosing a
    # self-hosted label.
    runs-on: macos-26
    # Archive and export time plus the upload step's limit.
    timeout-minutes: 90
    defaults:
      run:
        shell: bash
    env:
      # Distribution-exception Xcode (xcode-project-workflow): one that App
      # Store Connect accepts for this upload. It selects only this job's
      # archive, export and upload. It is not the development pin; that stays
      # the PR workflow's DEVELOPER_DIR.
      DEVELOPER_DIR: /Applications/Xcode_<eligible-version>.app/Contents/Developer
      XCODE_BUILD: <eligible-ProductBuildVersion>
      WORKSPACE: App.xcworkspace
      SCHEME: App
      EXPORT_OPTIONS: <reviewed-ExportOptions.plist>
      SIGNING_DIR_NAME: release-signing-${{ github.run_id }}-${{ github.run_attempt }}
    steps:
      - uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262 # v4
        with:
          persist-credentials: false

      - name: Verify the commit, Xcode and asc
        env:
          RELEASE_SHA: ${{ inputs.release_sha }}
        run: |
          set -euo pipefail
          if [ "$(git rev-parse HEAD)" != "$RELEASE_SHA" ]; then
            echo "::error::The checked-out commit is not release_sha"
            exit 1
          fi
          actual="$(xcodebuild -version | awk '/^Build version/ { print $3 }')"
          if [ "$actual" != "$XCODE_BUILD" ]; then
            echo "::error::DEVELOPER_DIR selects Xcode build $actual, not $XCODE_BUILD"
            exit 1
          fi
          # Hosted images have no asc; see the asc note below the template.
          asc --version

      - name: Install this job's signing material
        env:
          DIST_P12_BASE64: ${{ secrets.DIST_P12_BASE64 }}
          DIST_P12_PASSWORD: ${{ secrets.DIST_P12_PASSWORD }}
          DIST_PROFILE_BASE64: ${{ secrets.DIST_PROFILE_BASE64 }}
        run: |
          set -euo pipefail
          umask 077
          dir="$RUNNER_TEMP/$SIGNING_DIR_NAME"
          keychain="$dir/release.keychain-db"
          mkdir "$dir"
          security list-keychains -d user |
            sed -e 's/^[[:space:]]*"//' -e 's/"$//' > "$dir/search-list.orig"
          printf '%s' "$DIST_P12_BASE64" | base64 --decode -o "$dir/distribution.p12"
          keychain_password="$(openssl rand -base64 32)"
          security create-keychain -p "$keychain_password" "$keychain"
          security set-keychain-settings -lut 21600 "$keychain"
          security unlock-keychain -p "$keychain_password" "$keychain"
          security import "$dir/distribution.p12" -k "$keychain" -f pkcs12 -t agg \
            -P "$DIST_P12_PASSWORD" -T /usr/bin/codesign
          # man security marks -k deprecated, but it is the only way to set
          # the partition list without a password prompt.
          security set-key-partition-list -S apple-tool:,apple: -s \
            -k "$keychain_password" "$keychain" > /dev/null
          rm -f "$dir/distribution.p12"
          search_list=("$keychain")
          while IFS= read -r entry; do
            if [ -n "$entry" ]; then search_list+=("$entry"); fi
          done < "$dir/search-list.orig"
          security list-keychains -d user -s "${search_list[@]}"
          identities="$(security find-identity -v -p codesigning "$keychain" |
            awk '/valid identities found/ { print $1 }')"
          if [ "${identities:-0}" -lt 1 ]; then
            echo "::error::The certificate did not import as a valid signing identity"
            exit 1
          fi
          # Xcode 16 and later store profiles in this directory.
          profiles="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
          printf '%s' "$DIST_PROFILE_BASE64" |
            base64 --decode -o "$dir/distribution.mobileprovision"
          # -k: the certificates cms -D imports from the profile go into the
          # job keychain, not the default (login) keychain.
          uuid="$(security cms -D -k "$keychain" \
            -i "$dir/distribution.mobileprovision" | plutil -extract UUID raw -)"
          uuid_pattern='^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$'
          if ! [[ "$uuid" =~ $uuid_pattern ]]; then
            echo "::error::The provisioning profile has no valid UUID"
            exit 1
          fi
          profile="$profiles/$uuid.mobileprovision"
          if [ -e "$profile" ]; then
            echo "::notice::This profile was already installed; the job leaves it in place"
          else
            mkdir -p "$profiles"
            printf '%s\n' "$profile" >> "$dir/installed-profiles"
            cp "$dir/distribution.mobileprovision" "$profile"
          fi
          rm -f "$dir/distribution.mobileprovision"

      - name: Archive and export with the committed signing settings
        run: |
          set -euo pipefail
          out="$RUNNER_TEMP/release-build"
          mkdir "$out"
          xcodebuild archive \
            -workspace "$WORKSPACE" \
            -scheme "$SCHEME" \
            -configuration Release \
            -destination 'generic/platform=iOS' \
            -disableAutomaticPackageResolution \
            -archivePath "$out/App.xcarchive"
          xcodebuild -exportArchive \
            -archivePath "$out/App.xcarchive" \
            -exportOptionsPlist "$EXPORT_OPTIONS" \
            -exportPath "$out/export"

      - name: Verify the exported signature and team
        env:
          EXPECTED_TEAM_ID: ${{ vars.APPLE_TEAM_ID }}
        run: |
          set -euo pipefail
          out="$RUNNER_TEMP/release-build"
          ipas=("$out"/export/*.ipa)
          if [ "${#ipas[@]}" -ne 1 ] || [ ! -f "${ipas[0]}" ]; then
            echo "::error::Expected exactly one exported IPA"
            exit 1
          fi
          ditto -x -k "${ipas[0]}" "$out/unpacked"
          apps=("$out"/unpacked/Payload/*.app)
          codesign --verify --strict "${apps[0]}"
          team="$(codesign -d --verbose=2 "${apps[0]}" 2>&1 |
            sed -n 's/^TeamIdentifier=//p')"
          if [ -z "$EXPECTED_TEAM_ID" ] || [ "$team" != "$EXPECTED_TEAM_ID" ]; then
            echo "::error::The app is not signed by the approved team"
            exit 1
          fi

      - name: Upload the build without distribution or review
        # Above the processing wait of builds upload --wait (asc 5.6.0: 30 min).
        timeout-minutes: 45
        env:
          ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}
          ASC_KEY_TYPE: team
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_PRIVATE_KEY_PATH: ${{ runner.temp }}/${{ env.SIGNING_DIR_NAME }}/AuthKey.p8
          ASC_STRICT_AUTH: "true"
          ASC_APP_ID: ${{ vars.ASC_APP_ID }}
        run: |
          set -euo pipefail
          umask 077
          unset ASC_PROFILE ASC_BYPASS_KEYCHAIN ASC_CONFIG_PATH
          unset ASC_PRIVATE_KEY ASC_PRIVATE_KEY_B64
          # Written only now, after the steps that run project code.
          printf '%s' "$ASC_KEY_P8_BASE64" |
            base64 --decode -o "$ASC_PRIVATE_KEY_PATH"
          unset ASC_KEY_P8_BASE64
          ipas=("$RUNNER_TEMP"/release-build/export/*.ipa)
          asc builds upload --app "$ASC_APP_ID" --ipa "${ipas[0]}" --wait --output json

      - name: Remove this job's signing material
        if: ${{ always() }}
        timeout-minutes: 2
        run: |
          set +e
          dir="$RUNNER_TEMP/$SIGNING_DIR_NAME"
          keychain="$dir/release.keychain-db"
          [ -d "$dir" ] || exit 0
          status=0
          if [ -e "$keychain" ]; then
            security delete-keychain "$keychain" || status=1
          fi
          if [ -f "$dir/search-list.orig" ]; then
            restore=()
            while IFS= read -r entry; do
              if [ -n "$entry" ]; then restore+=("$entry"); fi
            done < "$dir/search-list.orig"
            security list-keychains -d user -s "${restore[@]}" || status=1
          fi
          if [ -f "$dir/installed-profiles" ]; then
            while IFS= read -r installed; do
              if [ -n "$installed" ]; then rm -f "$installed" || status=1; fi
            done < "$dir/installed-profiles"
          fi
          rm -f "$dir/AuthKey.p8" "$dir/distribution.p12" \
            "$dir/distribution.mobileprovision" "$dir/installed-profiles" \
            "$dir/search-list.orig" || status=1
          rmdir "$dir" || status=1
          exit "$status"
```

What the template guarantees, and what to keep when adapting it:

- Secrets enter only through a step's `env:`, never as `${{ secrets.* }}` text
  inside `run:`. The key, certificate and profile are decoded straight into
  owner-only files (`umask 077`) in a directory named for this run attempt
  under `$RUNNER_TEMP`, never into the checkout. The API key is written only in
  the upload step, so build phases, package plugins and macros that run during
  archive and export cannot read it. `asc` reads the key's path from
  `ASC_PRIVATE_KEY_PATH`, not from an argument, and `ASC_STRICT_AUTH` makes it
  fail on mixed credential sources. `ASC_KEY_TYPE: team` and clearing
  `ASC_PROFILE`, `ASC_BYPASS_KEYCHAIN` and `ASC_CONFIG_PATH` keep a runner's
  own `asc` settings and stored login out of the lookup. No key or certificate
  content appears in any command's arguments.
- `security` accepts the keychain password and the `.p12` passphrase only as
  arguments (`-p`, `-k`, `-P`) or through an interactive prompt, and GitHub
  warns that other processes can read command lines with `ps`. The keychain
  password is random, made in the job, and useless once the keychain is deleted;
  the passphrase is expanded from the step environment for one command. Run this
  job only on an ephemeral GitHub-hosted runner, or on a self-hosted runner user
  dedicated to release signing that runs one job at a time.
- The certificate goes into a new keychain, never the login keychain.
  `-T /usr/bin/codesign` limits access to `codesign`, instead of `-A` (any
  application). The partition list lets `codesign` use the key without a
  prompt. The job keychain is placed first in the user search list, ahead of
  the recorded entries, and the imported `.p12` is removed at once. Setup stops
  when the import yields no valid code-signing identity.
- The team check compares the exported app's `TeamIdentifier` with the approved
  team before any account write, without printing either value.
- The profile is installed in
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles` as
  `<UUID>.mobileprovision`, with the UUID read by `security cms -D`. Xcode 16
  and later store profiles there and still load the older
  `~/Library/MobileDevice/Provisioning Profiles`, which earlier Xcode uses.
  Decoding imports the profile's signing certificates into a keychain; keep
  `-k` so they go into the job keychain, not the runner user's default one. The
  job copies the profile only when no file with that name exists, and records
  the path before it copies. A profile that was already there stays in place
  and is never recorded. An app with extensions needs a profile for each signed
  target; install each one the same way.
- The cleanup step runs even after cancellation (`always()`). It deletes exactly
  this run attempt's keychain and files and the profile paths it recorded, and
  restores the recorded search list. `$RUNNER_TEMP` is emptied at the start and
  end of each job, but that does not unregister a keychain or remove a profile
  under `~/Library`, and GitHub notes that a self-hosted runner can keep both.
  A crashed runner skips the step, so check a persistent runner for leftover
  `release-signing-*` directories, search-list entries and profiles before its
  next signing job, and remove only the items you can attribute to that failed
  run.
- The project's committed Release settings sign manually with the distribution
  identity and the installed profiles. The reviewed `ExportOptions.plist` sets
  `method` to `app-store-connect`, `signingStyle` to `manual`, a
  `provisioningProfiles` entry (profile name or UUID) for each bundle ID, and
  `destination` to `export`, the default. With `upload`,
  `xcodebuild -exportArchive` uploads the build itself, before the team check
  and outside the gated upload step; on a self-hosted signing user with an
  Xcode account, that upload can succeed. `xcodebuild -allowProvisioningUpdates`
  with `-authenticationKeyPath` downloads missing profiles for manually signed
  targets, but for automatically signed targets it can create or update
  profiles, app IDs and certificates. That is a separate certificate/profile
  gate, never a template default.
- Hosted images do not include `asc`. On `macos-26`, add a pinned, approved step
  that installs the approved version before the verify step; without it the job
  stops at `asc --version`. A self-hosted runner may provide that version
  instead. Check flags against the installed `--help`.
- `asc builds upload --wait` waits for processing for up to 30 minutes by
  default in asc 5.6.0 (`ASC_TIMEOUT` changes that). Keep the upload step's
  timeout above that wait, and the job's timeout above archive, export and
  upload together.

References:

- [GitHub workflow syntax](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions)
- [GitHub-hosted runner images](https://github.com/actions/runner-images#available-images)
- [Deployments and environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments)
- [Using secrets in GitHub Actions](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)
- [Signing Xcode applications on GitHub runners](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [asc authentication](https://github.com/rorkai/App-Store-Connect-CLI/blob/main/authentication.mdx)
- [Xcode 16 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes) (provisioning profile location)
- `man security`, `man codesign`, and `xcodebuild -help` on the selected Xcode
- [Apple Swift package CI guidance](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows)
- [Xcode command-line tools](https://developer.apple.com/documentation/xcode/xcode-command-line-tools)
