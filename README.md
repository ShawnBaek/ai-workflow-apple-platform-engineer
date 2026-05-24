# indie-native-app

Agent **skills** for indie developers shipping **Apple-platform native apps end-to-end** — from blank Xcode project to App Store submission, on your own (or with a designer), without a DevOps team.

Distributed through the open [skills.sh](https://skills.sh) ecosystem, so one `npx skills add` installs them into **Claude Code, Codex, Cursor, Gemini CLI, Copilot, and 50+ other agents** — not just one tool.

A **team lead** plus **nine specialist skills**, sharing one job: kill the time-sinks that make shipping native apps painful. Start with [`native-app-lead`](skills/native-app-lead/SKILL.md) when you're not sure what's next — it sequences the work and hands off to the right specialist. **Two paths for the UI layer** — pick the one that matches your situation:

| Situation | UI path |
|---|---|
| Pure indie, no designer, no Figma file | [`apple-platform-ui`](skills/apple-platform-ui/SKILL.md) directly — makes HIG-anchored decisions itself |
| Designer hands you a Figma file (or you have your own Figma mockup) | [`figma-bridge`](skills/figma-bridge/SKILL.md) → [`apple-platform-ui`](skills/apple-platform-ui/SKILL.md) — Figma extraction, then HIG polish |

## The team: a lead + nine specialists

| Skill | When it kicks in | What it owns |
|-------|------------------|--------------|
| [`native-app-lead`](skills/native-app-lead/SKILL.md) | "Where do I start", "take me from zero to the App Store", "what's next", "which skill do I use" | Coordinates the other nine: locates you on the pipeline, names the next move, hands off to the specialist that owns it |
| [`apple-platform-ui`](skills/apple-platform-ui/SKILL.md) | "Build me a screen", "design this view", "SwiftUI / UIKit" | UI implementation in SwiftUI/UIKit, grounded in Apple HIG (pure-indie path) |
| [`figma-bridge`](skills/figma-bridge/SKILL.md) | "Figma", "generate from this frame", "code connect", "review my figma file", "set up figma mcp" | Figma → SwiftUI handoff. MCP setup (Claude Code + Codex), formal Code Connect for SwiftUI, generate-from-frame, dev-friendliness file review, lightweight `// figma:` code-connect-map convention. Hands off to `apple-platform-ui` for HIG polish. |
| [`apple-platform-performance`](skills/apple-platform-performance/SKILL.md) | "App is janky", "scroll stutters", "launch is slow", "Instruments shows…" | Hangs / hitches / launch / body cost / ML inference / audio pipeline — 27 Effective-style items in 6 Parts |
| [`xcodebuild`](skills/xcodebuild/SKILL.md) | "Build", "run on sim", "screenshot the screen", "attach debugger" | Xcode builds + simulator + UI automation via XcodeBuildMCP (XcodeGen-aware) |
| [`screenshot`](skills/screenshot/SKILL.md) | "App Store screenshots", "capture and upload" | End-to-end App Store screenshot pipeline (capture → frame → upload) |
| [`app-store-connect`](skills/app-store-connect/SKILL.md) | "TestFlight", "submit", "store metadata", "crash reports" | App Store Connect ops via the asc CLI (iOS / macOS / Mac Catalyst / watchOS / visionOS) |
| [`app-website`](skills/app-website/SKILL.md) | "Build my app's landing page", "one-pager", "download page" | One-page introduction website via SwiftUI-For-Web + Gridlover rhythm |
| [`cicd`](skills/cicd/SKILL.md) | "Set up CI", "GitHub Actions workflow", "self-hosted runner", "deploy on tag" | GitHub Actions on a self-hosted Mac runner; `act` local testing; `gh` CLI secrets; failure routing |
| [`commit-message`](skills/commit-message/SKILL.md) | "Write a commit message for this", right before `git commit` | Good commit messages from the staged diff (Conventional, Swift `[area]`, or plain) |

Each skill is a self-contained folder under `skills/<name>/` — a `SKILL.md` (the instructions the agent loads) plus any bundled sub-docs the skill reads on demand.

## Install

All install through the [`skills`](https://skills.sh) CLI — no global install needed, just `npx`.

### Everything, interactively (recommended)

Pick which skills and which agents you want:

```bash
npx skills add ShawnBaek/indie-native-app
```

### Specific skills

```bash
npx skills add ShawnBaek/indie-native-app --skill apple-platform-ui --skill commit-message
```

### Target specific agents

```bash
# Install into Claude Code and Codex at once
npx skills add ShawnBaek/indie-native-app -a claude-code -a codex

# Global (~/), Codex only, no prompts — CI-friendly
npx skills add ShawnBaek/indie-native-app -g -a codex -y

# All skills into every detected agent
npx skills add ShawnBaek/indie-native-app --all
```

### Browse before installing

```bash
npx skills add ShawnBaek/indie-native-app --list   # list the skills in this repo
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
| `apple-platform-performance` | Instruments + XCTest (ship with Xcode) | — |
| `xcodebuild` | **XcodeBuildMCP** ([xcodebuildmcp.com](https://www.xcodebuildmcp.com)) | `npx -y xcodebuildmcp@latest mcp` via your agent's MCP config |
| `screenshot` | XcodeBuildMCP + asc CLI | both via the skills above |
| `app-store-connect` | **asc CLI** ([asccli.sh](https://asccli.sh)) | `brew install asc` |
| `app-website` | **SwiftUI-For-Web** ([repo](https://github.com/ShawnBaek/SwiftUI-For-Web)) | `npm install swiftui-for-web` |
| `cicd` | **`gh` CLI** + **`act`** + a Mac self-hosted runner | `brew install gh act` |
| `commit-message` | `git` | already on your machine |

Each skill walks you through its install on first run.

## Repo layout

```
indie-native-app/
├── README.md
└── skills/
    ├── native-app-lead/SKILL.md    # the team lead — coordinates the nine below
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
    ├── apple-platform-performance/
    │   ├── SKILL.md
    │   └── part-1…6.md             # body cost, hangs, hitches, launch, diagnose, ML/audio
    ├── xcodebuild/SKILL.md
    ├── screenshot/SKILL.md
    ├── app-store-connect/SKILL.md
    ├── app-website/
    │   ├── SKILL.md
    │   └── sections.md, responsive.md, 3d-devices.md, deploy.md, api-reference.md, playwright-verify.md
    └── commit-message/SKILL.md
```

## Philosophy

Indie developers ship. They don't theme, don't have a release engineer, don't have a perf team, and don't have time to read every doc.

Each skill saves the most expensive thing — the loop of *do it, realize you missed a step, do it again*:

- **native-app-lead** kills the "what do I even do next" loop by sequencing the whole journey and handing each stage to the specialist that owns it.
- **apple-platform-ui** kills the rebuild-tweak loop by reasoning through layout in-head before ⌘R.
- **figma-bridge** kills the design-handoff-as-screenshot loop — wires the Figma MCP server, sets up Code Connect for SwiftUI, generates first-draft code from a chosen frame, then hands off to apple-platform-ui for the HIG polish. The Figma path complements (doesn't replace) the pure-indie path.
- **apple-platform-performance** kills the "ship → real users complain → reverse-engineer the regression" loop by gating it in CI with XCTMetric.
- **xcodebuild** kills the "what's the destination flag again" loop.
- **screenshot** kills the multi-hour manual screenshot ritual.
- **app-store-connect** kills the App Store Connect web-UI loop (and the 24h rejection cycle by always pre-flighting).
- **app-website** kills the "I'll just put a `<div>About</div>` page up" loop by giving you a typography-first one-pager in the same SwiftUI style as the app.
- **cicd** kills the "commit, push, wait 8 minutes, fail" loop by running workflows locally with `act` first, then deploying via `gh` CLI + a self-hosted Mac.
- **commit-message** kills the `git log | grep wip` loop.

Default to system. Deviate only when there's a real reason.

## Naming conventions

- **Skills** live in `skills/<short-name>/` (e.g. `xcodebuild`). The `name:` in each `SKILL.md` frontmatter matches the folder name.
- **Sub-docs** for big skills live beside the `SKILL.md` in the same folder (e.g. `skills/cicd/workflow-templates.md`). The `SKILL.md` stays small (overview + quick-reference table) and tells the agent to `Read` the matching sub-doc when a topic comes up — progressive disclosure. Used today by `app-website` (6 sub-docs), `apple-platform-performance` (6 sub-docs: parts 1–6 including ML/audio), `cicd` (5 sub-docs), `figma-bridge` (5 sub-docs), and `apple-platform-ui` (2 sub-docs: keyboard, launch-screen).

## Contribute

Validate locally before pushing — point `skills add` at the working copy:

```bash
npx skills add ./ --list
npx skills add ./ --skill apple-platform-ui
```

Add a new skill: create `skills/<name>/SKILL.md` with `name` + `description` frontmatter and the instructions, drop any sub-docs in the same folder, and add a row to the table above.

To get this collection onto the [skills.sh](https://skills.sh) directory/leaderboard so anyone can find it, follow the publishing flow at [skills.sh](https://skills.sh).
