# xcodebuild

Drives Xcode builds, simulators, tests, debugging, and UI automation through the **XcodeBuildMCP** server (https://www.xcodebuildmcp.com).

You stop typing `xcodebuild -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.2' -scheme ...` and start saying "build and run on iPhone 16."

## What it does

- Walks you through installing XcodeBuildMCP as an MCP server in Claude Code (one-time setup).
- Sets up per-project `.xcodebuildmcp/config.yaml` so the agent stops asking which scheme.
- Picks the right MCP tool for the task — `build`, `build-and-run`, `test`, `screenshot`, `attach`, `breakpoint`, `tap`, `swipe`, log capture — instead of chaining `xcodebuild` invocations.
- Detects the active scheme and simulator inside Xcode 26.3+.
- Surfaces build failures as a single file:line + diagnostic, not a 10k-line log dump.

## What it deliberately doesn't do

- Run raw `xcodebuild` shell commands when an MCP tool exists for the same job.
- Modify `project.pbxproj` or `Info.plist`.
- Manage signing certificates (that's the `app-store-connect` agent).
- Compose multi-step chains when one MCP call covers it.

## When to use

- "Build and run on the simulator."
- "Run the unit tests for just `AuthTests`."
- "Take a screenshot of the current screen."
- "It crashes on launch — attach LLDB."
- "Tap the Login button on the simulator."

## Prerequisites

- Xcode installed (Xcode 26.3+ gets auto-scheme/sim detection).
- Node.js (for `npx` install of the MCP server).

## One-time MCP install

Add to your Claude Code MCP config (`~/.claude.json` or project `.mcp.json`):

```json
{
  "mcpServers": {
    "XcodeBuildMCP": {
      "command": "npx",
      "args": ["-y", "xcodebuildmcp@latest", "mcp"]
    }
  }
}
```

Restart Claude Code. Tools appear as `mcp__XcodeBuildMCP__*`. The agent walks you through this on first use.

## Per-project config (optional)

Saves answering "which scheme?" every time. At your repo root:

```yaml
# .xcodebuildmcp/config.yaml
schemaVersion: 1
enabledWorkflows:
  - simulator
  - ui-automation
  - debugging
sessionDefaults:
  scheme: MyApp
  projectPath: ./MyApp.xcodeproj
  simulatorName: iPhone 16
```

## Install

```bash
npx claude-plugins install @shawnbaek/agent-design/xcodebuild
```

Requires Claude Code v2.0.12+. Or interactively inside Claude Code:

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install xcodebuild@indie-native-app
```

## References

- XcodeBuildMCP homepage → https://www.xcodebuildmcp.com
- Source → https://github.com/getsentry/XcodeBuildMCP
- License: MIT

## Companion agents in this marketplace

- [`apple-platform-ui`](../apple-platform-ui/README.md) — produces the SwiftUI code this agent builds and runs.
- [`screenshot`](../screenshot/README.md) — uses this agent's `simulator screenshot` for the capture step.
- [`app-store-connect`](../app-store-connect/README.md) — takes the archived build and ships it.
