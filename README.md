# Apple Platform Engineer

```text
  .-----------.
  |    </>    |  APPLE PLATFORM
  '-----+-----'  ENGINEER
      __|__
```

**Give your AI coding agent a practical workflow for building native Apple apps.**

Apple Platform Engineer is a collection of reusable skills for Codex and Claude Code. It helps your agent design, build, debug, test, and prepare reviewable changes using Apple documentation and Xcode tools.

Previously **iOS Experts**.

For new and existing iOS, iPadOS, watchOS, and macOS projects using SwiftUI or UIKit.

## What it helps you do

- **Design before adding logic.** Explore real UI in Xcode Previews, or work from a Figma reference.
- **Find the cause of slow UI.** Investigate scrolling, launch time, and memory use with focused measurements.
- **Verify what changed.** Choose meaningful tests and capture screenshots or short recordings for review.
- **Keep changes easy to review.** Break larger tasks into coherent PRs with relevant evidence.
- **Keep development work organized.** Coordinate repository changes, Simulator use, and package/build resources.

Use a specialist for a small task, or the lead skill (`native-app-lead`) for a broader feature. Load only the guidance your task needs.

## Get started

Install with the [Skills CLI](https://www.skills.sh/docs/cli):

```sh
npx skills add ShawnBaek/iOS-experts
```

Apple builds and Simulator work require macOS and Xcode. Follow the [getting-started guide](docs/getting-started.md) before running coordinated app tasks.

Then open your app repository in your agent and try:

> Use native-app-lead to build this screen. Start with a SwiftUI preview, keep tests focused, and show the result with a screenshot.

## Explore

[Skills](docs/skills.md) · [Workflow](skills/agent-harness/SKILL.md) · [Verification](docs/verification.md) · [Contribute](CONTRIBUTING.md) · [Report a problem](skills/skill-maintenance/SKILL.md)

**Version:** 2.0.0-beta.9
