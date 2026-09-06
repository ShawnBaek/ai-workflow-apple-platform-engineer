# Selected dependency setup

Cover the collection's tool surfaces without requiring every tool for every task.
Inventory first; installation/authentication commands run only within the user's
selected setup scope. Check the installed command's help and current official
source before choosing version-specific flags.

| Surface | When needed | Setup owner and smallest useful check |
|---|---|---|
| Codex / Claude and skill files | The selected client | Preserve that client's install method/scope; resolve one discoverable copy of each selected skill and its matching frontmatter. Use the client's supported refresh/new-task flow; do not require both clients. |
| Git and `gh` | Git for repository work; `gh` for GitHub/PR delivery | `git-workflow`: inspect root, branch, redacted remote and local commit identity. Check `git --version`, `gh --version` and PR create/edit/review help. With the confirmed account, verify `gh auth status` and the exact `gh repo view`; do not create a test PR. Check image/video `--attach` support for proof. |
| Full Xcode, Swift and Apple CLIs | Native build/Preview/Simulator work; full Xcode and Swift 6 for building this verifier | `xcode-project-workflow` / `xcodebuild`: inspect selected Xcode and deployment targets, `xcodebuild -version`, `swift --version` and `xcrun --find` for required tools. Command Line Tools alone do not provide full native build support. Select `DEVELOPER_DIR` per command rather than silently changing global Xcode. |
| Simulator runtimes / devices | The selected runtime UI or test target | `core-simulator-health`: establish registry health, then one exact compatible runtime/destination. Install only needed platform components through Xcode. A build/boot/launch is a separate task check, not an MCP login probe. |
| SwiftPM / XcodeGen / project tools | Declared by the app | `swift-package-manager` / `xcode-project-workflow`: inspect lockfiles and generator config, then version/help. Preserve pinned dependencies; do not resolve or regenerate an open project during tool discovery. |
| Harness Swift executable / shared coordinator | Coordinated execution | Installed `agent-harness` setup: matching sources/contracts plus `--help`, `runtime-identity` and read-only coordinator `status`; fresh private bindings and health. Reuse a verified matching binary; do not rebuild on every task. |
| Official Xcode MCP bridge | Selected external-agent Xcode integration | `xcodebuild` provider preflight: selected Xcode supports `mcpbridge`, correct client registration, current-task tool exposure, then one read-only workspace call. Do not install duplicate providers or boot a Simulator just to check connection. |
| `asc` / Apple account / signing | Selected ASC, Xcode Cloud, TestFlight or App Store work | `app-store-connect`: version plus nested help; private account guard, then one exact app/build read when authorized. Choose local archive, Cloud or existing-build lane before requiring local signing. No upload/distribution/submission during setup verification. |
| Figma | Explicit Figma design source | `figma-bridge`: configured client, exposed tools and one permitted read of the requested file/node. Code-first Preview design does not require Figma. |
| 1Password Environments | User-selected development secret provider | `onepassword-environments`: official provider, handshake, current-task exposure and authenticated Environment listing without values. Local `.env` mounting is a separate authorized exposure, not a default setup step. |
| Icon Composer / screenshot tools | Selected icon or media work | `icon-composer` / `screenshot`: locate the supported Apple app/framework/CLI and verify the required operation on a task-owned example when requested. Do not add an image service or XCUITest framework for discovery. |
| Spec Kit / GitHub Projects | Already selected by the project | `agent-harness` Spec Kit adapter / `github-projects`: pinned tool and project artifacts; only the selected board/scopes. Missing optional project access does not block ordinary PR work. |
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
[Homebrew installation](https://docs.brew.sh/Installation).
