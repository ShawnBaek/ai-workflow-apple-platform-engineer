# Disk cleanup + failure debugging on the self-hosted runner

The two things that bite self-hosted runners:
1. **Disk fills up** from DerivedData, Xcode caches, simulators, Homebrew cache. Builds suddenly start failing with "no space left on device."
2. **A failed build with no log** wastes the next 30 minutes. Always upload diagnostic artifacts.

## Cleanup commands (memorize these)

### Per-job (every workflow, in the `always()` cleanup step)

```bash
# DerivedData — biggest offender, grows unbounded
rm -rf ~/Library/Developer/Xcode/DerivedData/*

# Simulators booted by tests
xcrun simctl shutdown all || true
xcrun simctl delete unavailable || true

# Build artifacts produced by this job
rm -rf ./build
rm -f *.log *.xcresult
```

### Weekly (the `weekly-cleanup.yml` workflow)

```bash
# Xcode caches
rm -rf ~/Library/Caches/com.apple.dt.Xcode/*
rm -rf ~/Library/Developer/CoreSimulator/Caches/*

# Reset all simulators to factory
xcrun simctl erase all

# Homebrew
brew cleanup -s --prune=all
brew autoremove

# Swift Package Manager
rm -rf ~/Library/Caches/org.swift.swiftpm
rm -rf ~/Library/org.swift.swiftpm

# CocoaPods
pod cache clean --all 2>/dev/null || true

# Carthage (rare in 2026, but worth checking)
rm -rf ~/Library/Caches/org.carthage.CarthageKit

# Runner workspaces (keeps the actions-runner intact, drops _work contents)
rm -rf ~/actions-runner/_work/*/

# Logs — runner diagnostics
find ~/actions-runner/_diag -name "*.log" -mtime +14 -delete
```

### Disk check (always print before + after major cleanup)

```bash
df -h /
du -sh ~/Library/Developer/Xcode/DerivedData ~/Library/Caches/Homebrew 2>/dev/null
```

### Disk usage triage — when something blew up

```bash
# Top 20 largest folders in your home
sudo du -d 2 ~/ 2>/dev/null | sort -rn | head -20

# Or with ncdu (better UX)
brew install ncdu
ncdu ~
```

## Debug logging — always upload artifacts on failure

The workflow template (see [`workflow-templates.md`](workflow-templates.md)) wires this up. Pattern:

```yaml
- name: Build
  run: |
    set -o pipefail
    xcodebuild build ... | tee build.log

- name: Upload logs on failure
  if: failure()
  uses: actions/upload-artifact@v4
  with:
    name: build-logs-${{ github.run_id }}
    path: |
      build.log
      ~/Library/Logs/DiagnosticReports/*.crash
      ~/Library/Logs/CoreSimulator/CoreSimulator.log
    retention-days: 7
```

What to capture:

| Artifact | Path | Why |
|---|---|---|
| Build log | `build.log` (via `tee`) | The xcodebuild output, full, unfiltered |
| Test result bundle | `*.xcresult` | Open in Xcode → see exact test failures, screenshots, attachments |
| Simulator log | `~/Library/Logs/CoreSimulator/CoreSimulator.log` | Why a simulator didn't boot or crashed |
| Crash reports | `~/Library/Logs/DiagnosticReports/*.crash` | App crashes during testing |
| Runner diag | `~/actions-runner/_diag/Worker_*.log` | When the runner itself misbehaves |

Use **`actions/upload-artifact@v4`** (v3 is deprecated). `retention-days: 7` for build/test, `14` for releases. Don't let artifacts accumulate.

## When a build fails — the triage flow

The cicd skill routes failures to the matching specialist skill (install it with `npx skills add ShawnBaek/iOS-experts`):

| Failure pattern in log | Route to |
|---|---|
| `xcodebuild` exit ≠ 0; compile errors, link errors, scheme not found, signing failures | the `xcodebuild` skill |
| `asc` exit ≠ 0; submission rejected, build processing stuck, certificate expired | the `app-store-connect` skill |
| Simulator boot failure, screen capture fail, UI automation tap missed | the `xcodebuild` skill (has simulator + ui-automation tools) |
| Unit / UI test failure | Read `.xcresult` → identify the test → flag the underlying code change |
| Test perf regression (XCTMetric baseline exceeded) | the `apple-platform-performance` skill |
| Hang report from CI (`MetricKit` payload) | the `apple-platform-performance` skill → Part II (Hangs) |

When you read a failed-build log:
1. **Search for `error:` first**, then `warning:`. Skip success lines.
2. **Find the FIRST error** — later errors are usually cascades.
3. **Quote the error to the developer** with file:line — don't paste 200 lines of unrelated output.
4. **Then hand off** to the right specialist skill with the diagnostic.

## Common runner failures + fixes

| Symptom | Cause | Fix |
|---|---|---|
| "No space left on device" mid-build | DerivedData grew | Run cleanup workflow, increase frequency to daily |
| "Signing for X requires development team" | New machine, no signing setup | Manual: open Xcode → Preferences → Accounts; add the Apple ID; then xcodebuild can re-sign |
| Runner shows "Offline" in Settings → Actions | `actions.runner.*` service stopped (after macOS update or reboot loop) | `sudo ~/actions-runner/svc.sh restart` |
| Build hangs forever | Xcode prompted for a password / cert and there's no UI to see it | SSH in, run `xcodebuild` manually to see the dialog, dismiss; keep runner logged-in user |
| `xcrun: error: invalid active developer path` | Command Line Tools selected instead of full Xcode | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` |
| Test fails only on runner, passes locally | Locale, timezone, language differ on runner | Set in workflow: `defaults write NSGlobalDomain AppleLocale en_US`, `sudo systemsetup -settimezone America/Los_Angeles` |
| `brew install` prompts for password | Homebrew not in PATH for the runner user, or sudo not configured | Add to runner user's `~/.zprofile`: `eval "$(/opt/homebrew/bin/brew shellenv)"`; restart runner |
