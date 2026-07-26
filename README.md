# iOS-experts

**Version:** 1.1.0

This is the stable indie native app skills collection for shipping across Apple platforms.

Agent skills for indie developers shipping Apple-platform native apps end-to-end — from a blank Xcode project to App Store submission.

Distributed through the open [skills.sh](https://skills.sh) ecosystem, so one `npx skills add` installs them into **Claude Code, Codex, Cursor, Gemini CLI, Copilot, and 50+ other agents** — not just one tool.

A **team lead** plus **twelve specialist skills**, sharing one goal: make shipping native apps less painful. Start with [`native-app-lead`](skills/native-app-lead/SKILL.md) when you're not sure what's next — it sequences the work and hands off to the right specialist. **Two paths for the UI layer** — choose the one that matches your situation:

| Situation | UI path |
|---|---|
| Working without a designer or Figma file | [`apple-platform-ui`](skills/apple-platform-ui/SKILL.md) directly — makes HIG-anchored decisions itself |
| Working from a Figma design | [`figma-bridge`](skills/figma-bridge/SKILL.md) → [`apple-platform-ui`](skills/apple-platform-ui/SKILL.md) — extracts the design from Figma, then applies Apple HIG polish |

## The team: one lead and twelve specialists

| Skill | When it kicks in | What it owns |
|-------|------------------|--------------|
| [`native-app-lead`](skills/native-app-lead/SKILL.md) | "Where do I start", "take me from zero to the App Store", "what's next", "which skill do I use" | Coordinates the other twelve: locates you on the pipeline, names the next move, and hands off to the specialist that owns it |
| [`apple-platform-ui`](skills/apple-platform-ui/SKILL.md) | "Build me a screen", "design this view", "SwiftUI / UIKit" | UI implementation in SwiftUI/UIKit, grounded in Apple HIG (no-designer path) |
| [`figma-bridge`](skills/figma-bridge/SKILL.md) | "Figma", "generate from this frame", "code connect", "review my figma file", "set up figma mcp" | Figma → SwiftUI handoff. MCP setup (Claude Code + Codex), formal Code Connect for SwiftUI, generate-from-frame, dev-friendliness file review, lightweight `// figma:` code-connect-map convention. Hands off to `apple-platform-ui` for HIG polish. |
| [`core-data`](skills/core-data/SKILL.md) | "Core Data", "migration", "xcmappingmodel", "readonly database", "NSPersistentCloudKitContainer", "persistent history" | Core Data architecture, staged/manual/lightweight migration strategy, concurrency topology, store-load crash triage, and CloudKit mirroring decisions |
| [`apple-platform-performance`](skills/apple-platform-performance/SKILL.md) | "App is janky", "scroll stutters", "launch is slow", "Instruments shows…" | Hangs / hitches / launch / body cost / ML inference / audio pipeline — 27 Effective-style items in 6 Parts |
| [`icon-composer`](skills/icon-composer/SKILL.md) | "Design an app icon", "Icon Composer", "replace the Xcode icon", "check icon sizes" | Layered iOS, iPadOS, macOS, and watchOS icons; Default/Dark/Clear/Tinted appearances; Xcode handoff; legacy `.icns` and asset-catalog verification |
| [`xcodebuild`](skills/xcodebuild/SKILL.md) | "Build", "run on sim", "screenshot the screen", "attach debugger" | Xcode builds + simulator + UI automation via XcodeBuildMCP (XcodeGen-aware) |
| [`screenshot`](skills/screenshot/SKILL.md) | "App Store screenshots", "capture and upload" | End-to-end App Store screenshot pipeline (capture → frame → upload) |
| [`app-store-connect`](skills/app-store-connect/SKILL.md) | "TestFlight", "submit", "store metadata", "crash reports" | App Store Connect ops via the asc CLI (iOS / macOS / Mac Catalyst / watchOS / visionOS) |
| [`app-website`](skills/app-website/SKILL.md) | "Build my app's landing page", "one-pager", "download page" | One-page introduction website via SwiftUI-For-Web + Gridlover rhythm |
| [`cicd`](skills/cicd/SKILL.md) | "Set up CI", "GitHub Actions workflow", "self-hosted runner", "deploy on tag" | GitHub Actions on a self-hosted Mac runner; `act` local testing; `gh` CLI secrets; failure routing |
| [`commit-message`](skills/commit-message/SKILL.md) | "Write a commit message for this", right before `git commit` | Good commit messages from the staged diff (Conventional, Swift `[area]`, or plain) |
| [`xcode-project-workflow`](skills/xcode-project-workflow/SKILL.md) | Any Xcode project task | Keeps work in the first-opened project directory, starts from `origin/main` or `origin/master`, requires feature-branch approval, and prevents unnecessary XcodeGen regeneration |

Each skill is a self-contained folder under `skills/<name>/` — a `SKILL.md` (the instructions the agent loads) plus any bundled sub-docs the skill reads on demand.

## Install

Install everything through the [`skills`](https://skills.sh) CLI — no global installation is needed; use `npx`.

### Everything, interactively (recommended)

Pick which skills and which agents you want:

```bash
npx skills add ShawnBaek/iOS-experts
```

### Specific skills

```bash
npx skills add ShawnBaek/iOS-experts --skill icon-composer
```

### Target specific agents

```bash
# Install into Claude Code and Codex at once
npx skills add ShawnBaek/iOS-experts -a claude-code -a codex

# Global (~/), Codex only, no prompts — CI-friendly
npx skills add ShawnBaek/iOS-experts -g -a codex -y

# All skills into every detected agent
npx skills add ShawnBaek/iOS-experts --all
```

### Browse before installing

```bash
npx skills add ShawnBaek/iOS-experts --list   # list the skills in this repo
npx skills find ios                                 # search skills.sh by keyword
```

### Manage installed skills

```bash
npx skills list                  # what's installed (project + global)
npx skills update                # pull latest
npx skills remove commit-message # uninstall one
```

> Installs into **Project** scope (`./<agent>/skills/`) by default — committed with your repo, shared with your team. Add `-g` for **Global** scope (`~/<agent>/skills/`), available across all your projects.

## The end-to-end flow

```
   [optional: figma-bridge]  →   apple-platform-ui        apple-platform-performance        xcodebuild
        ↓                              ↓                         ↓                       ↓
   Figma MCP setup,              SwiftUI code              Hangs / hitches /        Build + run on
   Code Connect for SwiftUI,     with mocks,               launch / body cost /     simulator;
   generate from frame,    →     Light/Dark/XXL    →       ML inference / audio →   capture logs;
   // figma: code-connect map    previews,                 — 27 Effective items     UI tests
   (skip if no Figma file)       HIG polish                + XCTMetric tests
                                                          ↓
                            screenshot                app-store-connect
                                 ↓                         ↓
                        Capture App Store           Upload IPA,
                        shots; frame;          →    TestFlight,
                        upload via asc              submit for review
                                 ↓                         ↓
                                 └─── app-website ────────┘
                                       (screenshots feed the
                                        Features section;
                                        App Store URL feeds
                                        the Download badge)

   commit-message sits across all of them — invoked right before any `git commit`
   to turn the staged diff into a properly-formatted, useful message.

   icon-composer creates the layered app icon before release, installs the canonical
   AppName.icon package in Xcode, and hands target verification to xcodebuild.

   cicd wraps the whole loop — GitHub Actions on a self-hosted Mac runner
   builds + tests on every PR, archives + ships to TestFlight on tag push.
   Failures route back to xcodebuild / app-store-connect / apple-platform-performance
   for diagnosis.
```

## External tools (some skills wrap third-party CLIs / MCP servers)

| Skill | External dependency | Install once |
|-------|---------------------|--------------|
| `apple-platform-ui` | none (uses Xcode itself) | — |
| `figma-bridge` | **Figma MCP server** + (optional) **Code Connect Swift package** | `claude mcp add figma --url https://mcp.figma.com/v1 --transport http` (or the Codex equivalent); `.package(url: "https://github.com/figma/code-connect", from: "1.0.0")` in `Package.swift` |
| `core-data` | none (Apple frameworks + Xcode model editor) | — |
| `apple-platform-performance` | Instruments + XCTest (ship with Xcode) | — |
| `icon-composer` | **[Icon Composer](https://developer.apple.com/icon-composer/)** + optional **[SF Symbols](https://developer.apple.com/sf-symbols/)** | Download both from Apple; Icon Composer requires macOS Tahoe 26.4 or later |
| `xcodebuild` | **XcodeBuildMCP** ([xcodebuildmcp.com](https://www.xcodebuildmcp.com)) | `npx -y xcodebuildmcp@latest mcp` via your agent's MCP config |
| `screenshot` | XcodeBuildMCP + asc CLI | both via the skills above |
| `app-store-connect` | **asc CLI** ([asccli.sh](https://asccli.sh)) | `brew install asc` |
| `app-website` | **SwiftUI-For-Web** ([repo](https://github.com/ShawnBaek/SwiftUI-For-Web)) | `npm install swiftui-for-web` |
| `cicd` | **`gh` CLI** + **`act`** + a Mac self-hosted runner | `brew install gh act` |
| `commit-message` | `git` | already on your machine |

Each skill explains any additional setup it needs when you first use it.

## Repo layout

```
iOS-experts/
├── README.md
└── skills/
    ├── native-app-lead/SKILL.md    # the team lead — coordinates the twelve below
    ├── apple-platform-ui/
    │   ├── SKILL.md
    │   ├── keyboard.md
    │   └── launch-screen.md
    ├── figma-bridge/
    │   ├── SKILL.md
    │   ├── mcp-setup.md            # Claude Code + Codex MCP install
    │   ├── code-connect.md         # SwiftUI Code Connect (CLI + GitHub UI)
    │   ├── code-connect-map.md     # // figma: URL comment convention
    │   ├── figma-review.md         # developer-friendliness audit
    │   └── generate-from-frame.md  # generate_figma_design + avoid-large-frames
    ├── core-data/
    │   ├── SKILL.md
    │   ├── migrations.md
    │   └── concurrency.md
    ├── apple-platform-performance/
    │   ├── SKILL.md
    │   └── part-1…6.md             # body cost, hangs, hitches, launch, diagnose, ML/audio
    ├── icon-composer/
    │   ├── SKILL.md
    │   └── platform-handoff.md      # platform sizes, Xcode integration, legacy fallbacks
    ├── xcodebuild/SKILL.md
    ├── screenshot/SKILL.md
    ├── app-store-connect/SKILL.md
    ├── app-website/
    │   ├── SKILL.md
    │   └── sections.md, responsive.md, 3d-devices.md, deploy.md, api-reference.md, playwright-verify.md
    ├── cicd/
    │   ├── SKILL.md
    │   └── workflow-templates.md, self-hosted-runner.md, secrets-and-variables.md, act-local-testing.md, cleanup-and-debug.md
    └── commit-message/SKILL.md
```

## Philosophy

Indie developers ship. They don't theme, don't have a release engineer, don't have a perf team, and don't have time to read every doc.

Each skill saves the most expensive thing — the loop of *do it, realize you missed a step, do it again*:

- **native-app-lead** kills the "what do I even do next" loop by sequencing the whole journey and handing each stage to the specialist that owns it.
- **apple-platform-ui** kills the rebuild-tweak loop by reasoning through layout in-head before ⌘R.
- **figma-bridge** kills the design-handoff-as-screenshot loop — wires the Figma MCP server, sets up Code Connect for SwiftUI, generates first-draft code from a chosen frame, then hands off to apple-platform-ui for HIG polish. The Figma workflow complements the no-designer workflow.
- **core-data** kills the "works on clean install, crashes on upgrade" loop by defining migration strategy, store-load triage, and safe context boundaries.
- **apple-platform-performance** kills the "ship → real users complain → reverse-engineer the regression" loop by gating it in CI with XCTMetric.
- **icon-composer** kills the "looks right at 1024 px, ships wrong everywhere else" loop by making the layered source, Xcode handoff, platform sizing, and archive verification one workflow.
- **xcodebuild** kills the "what's the destination flag again" loop.
- **screenshot** kills the multi-hour manual screenshot ritual.
- **app-store-connect** kills the App Store Connect web-UI loop (and the 24h rejection cycle by always pre-flighting).
- **app-website** kills the "I'll just put a `<div>About</div>` page up" loop by giving you a typography-first one-pager in the same SwiftUI style as the app.
- **cicd** kills the "commit, push, wait 8 minutes, fail" loop by running workflows locally with `act` first, then deploying via `gh` CLI + a self-hosted Mac.
- **commit-message** kills the `git log | grep wip` loop.

Default to system. Deviate only when there's a real reason.

## Naming conventions

- **Skills** live in `skills/<short-name>/` (e.g. `xcodebuild`). The `name:` in each `SKILL.md` frontmatter matches the folder name.
- **Sub-docs** for big skills live beside the `SKILL.md` in the same folder (e.g. `skills/cicd/workflow-templates.md`). The `SKILL.md` stays small (overview + quick-reference table) and tells the agent to `Read` the matching sub-doc when a topic comes up — progressive disclosure. Used today by `app-website` (6 sub-docs), `apple-platform-performance` (6 sub-docs: parts 1–6 including ML/audio), `cicd` (5 sub-docs), `figma-bridge` (5 sub-docs), `apple-platform-ui` (2 sub-docs: keyboard, launch-screen), `core-data` (2 sub-docs: migrations, concurrency), and `icon-composer` (1 sub-doc: platform handoff).

## Contribute

Validate locally before pushing — point `skills add` at the working copy:

```bash
npx skills add ./ --list
npx skills add ./ --skill apple-platform-ui
```

Add a new skill: create `skills/<name>/SKILL.md` with `name` + `description` frontmatter and the instructions, drop any sub-docs in the same folder, and add a row to the table above.

### Required branch workflow

Before starting work in this repository:

1. Inspect the clean working tree, current branch, remote, and remote default branch.
2. Start from the latest `origin/main` (or `origin/master` if that is the repository default).
3. Propose a concise feature-branch name and wait for approval before editing.
4. Create the approved feature branch in the existing checkout. Do not create a worktree or alternate checkout.

For Xcode projects, keep using the directory containing the project or workspace
that was opened first. If the project uses XcodeGen, do not regenerate while the
current Xcode session is open unless explicitly requested.

Create and validate skills with the `skills.sh` CLI, for example:

```bash
npx skills add ./ --list
npx skills add ./ --skill <name>
```

Do not add a skill only to a private agent directory; the source of truth for
this repository is `skills/<name>/SKILL.md` and its README entry.

To get this collection onto the [skills.sh](https://skills.sh) directory/leaderboard so anyone can find it, follow the publishing flow at [skills.sh](https://skills.sh).
