# cicd

Sets up **GitHub Actions CI/CD on a macOS self-hosted runner** for an indie iOS / macOS / watchOS app.

You stop fighting `xcodebuild` flags in YAML and stop paying for GitHub's slow hosted macOS runners. Your Mac (or a dedicated Mac mini) runs the jobs, faster and free.

## What it does

The 6-step canonical pipeline:

1. **Writes the workflow file** (build-and-test, release-to-TestFlight, weekly cleanup) — copy-paste templates that work, no trial-and-error.
2. **Registers a self-hosted runner** via `gh` CLI registration tokens. Service-installed so it boots with the Mac.
3. **Wires secrets and variables** via `gh secret set` (sensitive — `.p8`, passwords) and `gh variable set` (public — scheme, bundle ID, app IDs).
4. **Tests locally with `act`** (https://nektosact.com) — `act -P macos-latest=-self-hosted` runs the workflow on the host Mac before you push. No commit-and-pray.
5. **Commits + opens the PR** via `gh pr create --fill` once local runs are green.
6. **Watches the PR run** and, on failure, routes the diagnostic to the right specialist agent.

Plus:

- **Homebrew for everything**, with `brew list <pkg> || brew install <pkg>` guards so steps are idempotent.
- **`if: always()` cleanup step** in every workflow — purges DerivedData, shuts down simulators, deletes unavailable ones. The runner's disk does not survive without this.
- **Debug log upload on failure** — `tee` the build output, `actions/upload-artifact@v4` with 7-day retention, so you can read what broke.
- **Weekly maintenance workflow** for long-lived runners (Homebrew cache, SPM cache, simulator erase, runner work dir prune).
- **Failure routing**:
  - `xcodebuild` non-zero → [`agent-xcodebuild`](../xcodebuild/README.md)
  - `asc` non-zero / submission rejected → [`agent-app-store-connect`](../app-store-connect/README.md)
  - XCTMetric baseline exceeded → [`agent-apple-platform-performance`](../apple-platform-performance/README.md)

## What it deliberately doesn't do

- Use GitHub's hosted macOS runners without flagging the cost + speed trade-off.
- Ship a workflow without a cleanup step or `timeout-minutes`.
- Put a private key in a `gh variable` (or a bundle ID in a `gh secret`).
- Auto-merge after CI passes — you review and merge.
- Skip local `act` testing because "it should be fine."

## When to use

- "Set up CI for my iOS app."
- "Add a TestFlight upload workflow that runs on tag push."
- "Test this workflow file locally before I push it."
- "My self-hosted runner's disk is full — what do I clean?"
- "PR build failed — what broke?"
- "Wire the ASC API key into the workflow."

## Prerequisites

- A Mac (yours or a dedicated mini) running the latest macOS your app supports.
- **Xcode** installed via App Store.
- **`gh` CLI**: `brew install gh && gh auth login`.
- **Homebrew**: `brew --version`.
- For deploy workflows: **asc CLI** (`brew install asc`) and an [App Store Connect API key](https://appstoreconnect.apple.com).
- For local workflow testing: **act** (`brew install act`).

## Install

```bash
npx claude-plugins install @shawnbaek/agent-design/cicd
```

Requires Claude Code v2.0.12+. Or interactively inside Claude Code:

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install cicd@indie-native-app
```

## References

- GitHub Actions docs → https://docs.github.com/en/actions
- Adding self-hosted runners → https://docs.github.com/en/actions/hosting-your-own-runners
- `act` (local workflow runner) → https://nektosact.com
- `act` runners + `-self-hosted` flag → https://nektosact.com/usage/runners.html
- `gh` CLI → https://cli.github.com

## Companion agents in this marketplace

- [`xcodebuild`](../xcodebuild/README.md) — receives build failures for triage.
- [`app-store-connect`](../app-store-connect/README.md) — runs the actual TestFlight upload via `asc`; receives ASC failures for triage.
- [`apple-platform-performance`](../apple-platform-performance/README.md) — receives XCTMetric perf regressions for triage.
- [`commit-message`](../commit-message/README.md) — writes the `ci: …` commits for workflow changes.
