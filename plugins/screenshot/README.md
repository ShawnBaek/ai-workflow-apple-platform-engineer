# screenshot

End-to-end **App Store screenshot pipeline** for indie developers.

Boots the right simulators, drives the app UI to the screens you want, captures images at every App Store-required device size, optionally composites them into device frames with overlay text, and uploads via the asc CLI.

Replaces the multi-hour ritual of "open Simulator → navigate to screen → ⌘S → rename → upload" times 5+ device sizes times N locales.

## What it does

A 5-step pipeline you'd otherwise do by hand:

1. **Plan** — agrees with you on which screens, devices, locales, framed or plain.
2. **Drive the simulator** — boots the right device, sets locale + `9:41` status bar, navigates to each screen via UI automation, captures.
3. **Frame (optional)** — composites the raw captures into device bezels with marketing text using `asc screenshots frame` or Fastlane `frameit`.
4. **Upload via asc** — sequential upload in display order, per `(locale, display-type)` pair.
5. **Verify** — checks per-display-type counts after, tells you what's still missing.

Knows the 2026 App Store required device sizes (iPhone 6.9", iPhone 6.5", iPad Pro 13"/12.9", Apple Watch Ultra, Mac) and their asc display-type IDs.

## What it deliberately doesn't do

- Boot simulators or run captures before you confirm the plan.
- Auto-upload screenshots to a production version without an explicit "upload" instruction.
- Compose framed screenshots in raw SwiftUI / Canvas (use the right tool).
- Skip the `9:41` status bar override (industry standard for a reason).
- Continue without XcodeBuildMCP + asc set up — routes to the relevant agent first.

## When to use

- "I need App Store screenshots for the listing."
- "Capture 5 screens at all required iPhone sizes."
- "Frame these screenshots with a headline overlay."
- "Re-capture screenshots in Korean and Japanese."
- "Upload the framed shots to App Store Connect."

## Prerequisites

This agent **requires** two other agents to be set up first:

- [`xcodebuild`](../xcodebuild/README.md) — for `simulator boot`, `simulator launch`, `simulator screenshot`, `ui-automation/*`.
- [`app-store-connect`](../app-store-connect/README.md) — for `asc screenshots upload`.

You'll also want to add a launch argument like `-UITestMode YES` to your app so screenshot runs render deterministic mock data instead of your real, changing state. Otherwise "Recent Activity" looks different every capture.

## Install

```bash
npx claude-plugins install @shawnbaek/agent-design/screenshot
```

Requires Claude Code v2.0.12+. Or interactively inside Claude Code:

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install screenshot@indie-native-app
```

## References

- Apple's authoritative screenshot specs → https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications
- XcodeBuildMCP → https://www.xcodebuildmcp.com
- asc CLI → https://asccli.sh
- Fastlane frameit (alternative framing tool) → https://docs.fastlane.tools/actions/frameit/

## Companion agents in this marketplace

- [`apple-platform-ui`](../apple-platform-ui/README.md) — builds the screens you're about to screenshot.
- [`xcodebuild`](../xcodebuild/README.md) — owns the simulator + UI automation under this agent.
- [`app-store-connect`](../app-store-connect/README.md) — owns the upload under this agent.
