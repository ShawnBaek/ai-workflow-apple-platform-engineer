# Xcode MCP provider preflight

Use this before configuring or diagnosing an Xcode MCP provider for Codex,
Claude, or another external agent.
Installation, registration, exposure, and connectivity are four separate facts;
prove each one without using a build or a
Simulator run as a connectivity test.

## Resolve installation provenance without changing it

Inventory global and trusted-project MCP configuration, then record for every
Xcode-capable entry:

- configuration scope, server name, enabled state, command and arguments;
- resolved executable and symlink target;
- package-manager owner or direct installation source;
- resolved provider version and selected Xcode build;
- the server's `DEVELOPER_DIR` and the Xcode installation it resolves to, plus
  any `MCP_XCODE_SESSION_ID`, which names an Xcode tool session, and any
  `MCP_XCODE_PID`, a process ID that a registration should not set (see
  below); and
- the parent client/task of each running provider process.

A `brew tap` only registers a formula source; it does not prove that a formula
or cask is installed. A command found under an NVM, Homebrew, or system path does
not reveal which config invokes it. A global npm package is not the same as an
`npm exec ...@latest` process: the latter can resolve a different version on a
later launch. Do not install, update, untap, uninstall, or rewrite configuration
during this read-only inventory. Redact all other environment values and
credentials. Read registrations from the configuration files, such as
`~/.claude.json` and a project's `.mcp.json` for Claude Code, or
`~/.codex/config.toml` and a trusted project's `.codex/config.toml` for Codex.
Do not run `claude mcp list` or `claude mcp get` while diagnosing a wrong-Xcode
connection: they health-check approved servers, which starts `xcrun mcpbridge`
and can launch another installation's Xcode Service.

Multiple STDIO provider processes may be expected when several local tasks are
open. Count them by parent client/task and in-flight operation before calling
them leaked. Process count is amplification evidence, not proof that a provider
created a CoreSimulator fault.

## Prefer Apple's external-agent route

Apple's documented route registers the Xcode provider for an external client
with one of these commands:

```sh
claude mcp add --transport stdio xcode -- xcrun mcpbridge
codex mcp add xcode -- xcrun mcpbridge
```

Registering it is a configuration change and requires explicit approval. First
confirm that the selected Xcode supports the route and that its Intelligence
settings allow external agents. Then bind the registration to that Xcode as
described below. Do not add the same provider under multiple names.

Choose the scope before registering. Each bridge process is a new agent that
Xcode alerts about, and a client starts one in every session where the server
is registered. Apple's Codex command writes the global `~/.codex/config.toml`,
and a Claude Code user-scope entry (`-s user`) is global too, so either one
starts a bridge in every repository. Prefer registering the server only in the
repositories that need Xcode, as
[per-project registration](xcode-mcp-project-setup.md) describes for both
clients.

`xcrun mcp-server enable` is not Codex registration. It changes permission for
Xcode's separate headless MCP service; Xcode 27 release notes describe that
service as a preview whose settings can require an Xcode relaunch or Mac restart.
Inspect the exact selected Xcode help and release notes before using it. Never
enable or preserve a blanket `--unsafe-always-allow-all-agents` mode as a
convenience workaround.

Xcode's in-app agents have their own Xcode Coding Assistant configuration.
Conversely, official OpenAI documentation says the ChatGPT desktop app, Codex
CLI, and IDE extension share MCP configuration on the same Codex host. Inventory
both global and trusted-project scopes before concluding that only one Xcode
provider will start.

Use a third-party build provider only for a required capability the official
route lacks. Record the accepted fallback and a pinned/resolved version. During
a runtime incident, select exactly one Simulator-capable provider, official-first,
and disable or idle the duplicate only after approval. Prefer reversible
`enabled = false` over removal. Graceful task/provider shutdown precedes any
process termination; never force-terminate providers solely because the count is
high.

## Bind the bridge to the selected Xcode

Apple's registration sets no environment. In Xcode 27.1 beta and 27.2 beta,
`xcrun mcpbridge --help` says the bridge connects to the Xcode selected by
`xcode-select` unless `MCP_XCODE_PID` names an Xcode process (do not set it;
see below). So if an older Xcode is selected globally and a newer one is open,
the bridge can attach to the older Xcode, or launch that installation's
headless Xcode Service
(`Contents/Developer/Library/Xcode/Agents/Xcode Service.app`, the Xcode Service
menu bar extra), and answer from it instead of from the developer's window.

Resolve the selected Xcode with `xcode-project-workflow`, following
[Xcode selection](../../xcode-project-workflow/references/xcode-selection.md).
Then give the server that Xcode's developer directory. `DEVELOPER_DIR` overrides
the `xcode-select` choice for `xcrun` and the tools it runs. Xcode has no
`xcrun` of its own that you could point to instead.

```sh
# Claude Code: a personal entry for the current repository (local scope).
# Put another option between --env and the server name.
claude mcp add --scope local \
  --env DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  --transport stdio xcode -- xcrun mcpbridge
# Codex: start it with the variable; the project entry below forwards it.
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer codex
```

```toml
# Codex project .codex/config.toml
[mcp_servers.xcode]
command = "xcrun"
args = ["mcpbridge"]
env_vars = ["DEVELOPER_DIR"]
```

Codex starts a stdio server with a cleared environment, so `DEVELOPER_DIR`
reaches the bridge only through `env_vars` or the entry's `env` table. A global
Codex entry can set the path in `env`, with
`codex mcp add xcode --env DEVELOPER_DIR=<path> -- xcrun mcpbridge`, but it then
starts a bridge in every repository. Keep Xcode paths out of committed files;
[per-project registration](xcode-mcp-project-setup.md) shows the portable shared
entries for both clients.

- Adding, replacing, or editing a registration is a persistent configuration
  change. Get explicit approval for the exact client, scope, and path. Change
  the existing entry rather than adding a second Xcode server. To change a
  server in Claude Code, run `claude mcp remove` and then `add` with the
  entry's existing `--scope`, then restart the Claude Code session and confirm
  with the checks below which Xcode answers. The
  ChatGPT app, the Codex CLI, and the IDE extension share Codex's
  configuration, and the app and IDE extension need a restart to apply it.
- A registered path goes stale when that Xcode is renamed, replaced, or
  removed, or when the selection rule picks another installation. Check it
  during each task's preflight, and propose an update rather than silently
  following the old path.
- Do not set `MCP_XCODE_PID`, in a registration or for a one-session
  diagnosis. On 2026-09-27 with Xcode 27.2 beta (27B5019j), setting it to the
  running Xcode's process ID left `tools/list` unanswered after 45 seconds,
  while `DEVELOPER_DIR` alone returned the tools in about 5 seconds. Bind the
  bridge with `DEVELOPER_DIR`. If an existing registration sets
  `MCP_XCODE_PID`, report it and propose removing it. If you cannot bind the
  bridge with `DEVELOPER_DIR`, report the bridge as unbound.

Before trusting a response, check which Xcode answered:

1. The bridge process that this client started runs from the selected Xcode's
   `Contents/Developer/usr/bin/mcpbridge`. Check with
   `ps -axo pid=,ppid=,lstart=,command= | grep '[m]cpbridge'`, where the parent
   process is this client or task. This is the primary test.
2. No Xcode from another installation started after the bridge did. The bridge
   may launch its own installation's headless Xcode Service rather than
   another Xcode window, so match both forms with their start times:

   ```sh
   ps -axo pid=,lstart=,comm= | grep -E '/Contents/(MacOS/Xcode|Developer/Library/Xcode/Agents/Xcode Service\.app/Contents/MacOS/Xcode Service)$'
   ```

   An Xcode or Xcode Service from a non-selected installation that started
   after the bridge means that the bridge probably launched it.
3. The read-only workspace list includes the authoritative container that is
   open in the developer's window.

If any of these checks fails, report the connection as "connected to the wrong
Xcode" and do not use results from that Xcode. Propose the registration fix,
and meanwhile use host CLI tools with the selected `DEVELOPER_DIR`. Do not quit
or kill the other Xcode.

## Verify four states in order

1. **Installed:** the configured command resolves to the recorded executable and
   version. A tap, cache entry, or old process is insufficient.
2. **Registered:** the intended client's configuration files, read as described
   above, contain the server, enabled. `codex mcp list` and `codex mcp get` read
   them without starting it; `claude mcp list` and `claude mcp get` health-check
   approved servers, which starts a bridge. This does not prove that the current
   task loaded it. `apple-verify health` reads registrations the same way for
   the harness's authoritative root and starts no bridge by default. Its
   `--probe-xcode-mcp-bridge` opt-in starts one `xcrun mcpbridge` for a bounded
   `tools/list`, which Xcode alerts about; use it only when the developer asks
   for a live bridge check.
3. **Exposed:** after the client-prescribed restart or a new task, the expected
   Xcode tool namespace is visible. Do not assume hot reload.
4. **Connected:** one bounded, read-only workspace-list call returns from the
   selected Xcode, confirmed by the checks above. Record the exact container
   path and `workspaceIdentifier`.

If the same container is open in several Xcode windows or tabs, do not select the
first returned session. Bind the operation to the developer's authoritative
window/session; if that identity cannot be resolved safely, ask which window to
use. Then confirm scheme and active destination only when the requested work
needs them.

Do not start a build or destination inventory merely to prove MCP connectivity.
A destination-list call can traverse the global CoreSimulator catalog and is not
a harmless probe during a suspected runtime-registry stall. In that state,
follow [runtime-disk registry recovery](runtime-disk-registry-recovery.md) and
keep all other Simulator-capable providers idle.

Report the four states separately. “Configured but not exposed,” “exposed but
the first call timed out,” and “connected to the wrong Xcode window” require
different recovery; none is an app build failure.

References:

- [Apple: Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
- [Apple: Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
- [OpenAI Docs: Model Context Protocol](https://developers.openai.com/codex/mcp/)
- [Claude Code docs: MCP](https://code.claude.com/docs/en/mcp)
