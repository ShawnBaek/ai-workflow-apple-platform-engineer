# Selected dependency setup

Cover the collection's tool surfaces without requiring every tool for every task.
Inventory first; installation/authentication commands run only within the user's
selected setup scope. Check the installed command's help and current official
source before choosing version-specific flags.

| Surface | When needed | Setup owner and smallest useful check |
|---|---|---|
| Codex / Claude and skill files | The selected client | Preserve that client's install method/scope; resolve one discoverable copy of each selected skill and its matching frontmatter. Each skill folder installs on its own: confirm every selected skill's `../<skill>/` links resolve in the same skill root, and include `agent-harness` with the lead and any specialist that links its references. Use the client's supported refresh/new-task flow; do not require both clients. |
| Git and `gh` | Git for repository work; `gh` for GitHub/PR delivery | `git-workflow`: inspect root, branch, redacted remote and local commit identity. Check `git --version`, `gh --version` and PR create/edit/review help. With the confirmed account, verify `gh auth status` and the exact `gh repo view`; do not create a test PR. Check image/video `--attach` support for proof. |
| Full Xcode, Swift and Apple CLIs | Native build/Preview/Simulator work; full Xcode and Swift 6 for building this verifier | `xcode-project-workflow` / `xcodebuild`: resolve the selected Xcode by its [selection rule](../../xcode-project-workflow/references/xcode-selection.md) (the newest installed unless the user or project pins one; an App Store archive follows its distribution exception), then inspect deployment targets, `xcodebuild -version`, `swift --version`, `xcrun swift-format --version` (required by [Swift format and compile acceptance](../../apple-platform-testing/SKILL.md#swift-format-and-compile-acceptance); Xcode's copy prints `main`, so `xcodebuild -version` identifies it) and `xcrun --find` for required tools. Command Line Tools alone do not provide full native build support. Select `DEVELOPER_DIR` per command rather than silently changing global Xcode. |
| Simulator runtimes / devices | The selected runtime UI or test target | `core-simulator-health`: establish registry health, then one exact compatible runtime/destination. Install only needed platform components through Xcode. A build/boot/launch is a separate task check, not an MCP login probe. |
| SwiftPM / XcodeGen / project tools | Declared by the app | `swift-package-manager` / `xcode-project-workflow`: inspect lockfiles and generator config, then version/help. Preserve pinned dependencies; do not resolve or regenerate an open project during tool discovery. |
| Harness Swift executable / shared coordinator | Coordinated execution | Installed `agent-harness` setup: [build, then locate](../../agent-harness/references/swift-verification.md#build-and-locate-the-verifier) the executable from matching sources/contracts; check `--help`, `runtime-identity` and read-only coordinator `status`; fresh private bindings and health. Reuse a verified matching binary; do not rebuild on every task. |
| Official Xcode MCP bridge | Selected external-agent Xcode integration | `xcodebuild` provider preflight: selected Xcode supports `mcpbridge`; the Claude Code or Codex registration lives only in the repositories that need Xcode, not in global scope, as [per-project registration](../../xcodebuild/references/xcode-mcp-project-setup.md) describes, and is bound to that Xcode's `DEVELOPER_DIR` (a persistent change that needs approval and a new session); the current task exposes the tools; then one read-only workspace call is answered by that Xcode. Do not install duplicate providers or boot a Simulator just to check connection. |
| `asc` / Apple account / signing | Selected ASC, Xcode Cloud, TestFlight or App Store work | `app-store-connect`: version plus nested help; private account guard, then one exact app/build read when authorized. Choose local archive, Cloud or existing-build lane before requiring local signing. No upload/distribution/submission during setup verification. |
| Figma | Explicit Figma design source | `figma-bridge`: configured client, exposed tools and one permitted read of the requested file/node. Code-first Preview design does not require Figma. |
| Sketch MCP | Selected Sketch design work | `sketch-design-from-codebase`: Sketch 2025.2.4 or later from sketch.com (the Mac App Store build has no MCP server) is running with Settings > General > MCP Server on and the document permission its preflight names. The client registers `http://localhost:31126/mcp` as an HTTP server (Claude Code: `claude mcp add --transport http sketch http://localhost:31126/mcp`; Codex: an `[mcp_servers.sketch]` table with that `url`), a persistent change that needs approval and a new session. The current task exposes the tools; then one read-only `get_libraries` call shows the Apple UI Kit libraries for the target platforms. Do not create, edit or save a document to test the connection. |
| 1Password Environments | User-selected development secret provider | `onepassword-environments`: official provider, handshake, current-task exposure and authenticated Environment listing without values. Local `.env` mounting is a separate authorized exposure, not a default setup step. |
| Icon Composer / screenshot tools | Selected icon or media work | `icon-composer` / `screenshot`: locate the supported Apple app/framework/CLI and verify the required operation on a task-owned example when requested. Do not add an image service or XCUITest framework for discovery. |
| Spec Kit / GitHub Projects | Already selected by the project | `agent-harness` Spec Kit adapter / `github-projects`: pinned tool and project artifacts; only the selected board/scopes. Missing optional project access does not block ordinary PR work. |
| Trello | Selected card cleanup, tracker sync or QA handoff | `trello-pm-card-sync` / `release-qa-handoff`: the official Trello MCP server (`https://mcp.trello.com/v1`, OAuth 2.0) or the client's Trello connector is registered, authenticated and exposed in the current task; then one read of the configured board and its lists. Grant write access only when sync or a QA move is selected. Do not create, move or comment on a card to test access; an enterprise admin can restrict or block it in Atlassian Administration. |
| AppleSampleCode MCP / local LLM / project registry | Explicitly selected optional capability | `apple-development-health` matrix and harness references: bounded corpus-status, local capability or exact registry resolution. No automatic corpus download, model pull, public server or registry creation. |
| Homebrew / Node / npm / other package managers | Only the chosen installer or project requires them | Inspect existing method and versions; use upstream install guidance for missing components. Do not add Node for a Git-based skill install or a self-contained ASC binary. |

SwiftUI, UIKit, AppKit, StoreKit, App Intents and the Apple AI frameworks use the
selected SDK/project dependencies; they are not separate global CLI packages.
Use their specialist skills to check SDK/runtime/device eligibility. CI runners,
Apple Ads credentials and delivery-message transports are selected integrations
with their existing `cicd`, `apple-ads` and `delivery-report` owners, not baseline
installation requirements.

## Discover before configuring

Typical local discovery uses `command -v`, version/help and the declared project
files. Bound probes and output. A missing command is evidence for a setup step,
not permission to run an unreviewed installer. After installation, repeat the
specific failed probe, then one harmless capability check. Preserve partial
success and resume at the failed layer.

For example, with an existing approved Homebrew installation, the primary GitHub
and ASC installation guides currently provide `brew install gh` and `brew install asc`.
Inspect installed versions afterward; do not run these as unconditional upgrades
or install an overlapping ASC skill pack. Package-manager installation itself
needs its own applicable scope. Complete interactive OS/account prompts through
their supported UI without asking the user to paste credentials.

For Xcode MCP, follow the existing
[provider preflight](../../xcodebuild/references/xcode-mcp-provider-preflight.md),
which owns registration and the installed/configured/exposed/connected checks.
Installing a CLI is not client registration, and registration is not a successful
call. Keep global and project config scopes distinct.

Sources: [Apple command-line tools](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools),
[Xcode platform components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components),
[Codex MCP](https://developers.openai.com/codex/mcp/),
[GitHub CLI installation](https://github.com/cli/cli#installation),
[ASC installation](https://github.com/rorkai/App-Store-Connect-CLI#quick-start),
[Homebrew installation](https://docs.brew.sh/Installation),
[Sketch MCP server](https://www.sketch.com/docs/mcp-server/),
[Trello MCP](https://support.atlassian.com/trello/docs/connect-trello-to-ai-assistants-with-trello-mcp/).
