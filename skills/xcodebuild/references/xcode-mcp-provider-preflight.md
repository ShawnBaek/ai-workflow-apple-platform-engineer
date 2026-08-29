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
- resolved provider version and selected Xcode build; and
- the parent client/task of each running provider process.

A `brew tap` only registers a formula source; it does not prove that a formula
or cask is installed. A command found under an NVM, Homebrew, or system path does
not reveal which config invokes it. A global npm package is not the same as an
`npm exec ...@latest` process: the latter can resolve a different version on a
later launch. Do not install, update, untap, uninstall, or rewrite configuration
during this read-only inventory. Redact environment values and credentials.

Multiple STDIO provider processes may be expected when several local tasks are
open. Count them by parent client/task and in-flight operation before calling
them leaked. Process count is amplification evidence, not proof that a provider
created a CoreSimulator fault.

## Prefer Apple's external-agent route

For an external Codex client, Apple's documented route currently registers the
Xcode provider with:

```sh
codex mcp add xcode -- xcrun mcpbridge
```

That is a configuration mutation and requires explicit approval. First confirm
the selected Xcode supports the route and that Xcode Intelligence settings allow
external agents. Do not add the same provider under multiple names.

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

## Verify four states in order

1. **Installed:** the configured command resolves to the recorded executable and
   version. A tap, cache entry, or old process is insufficient.
2. **Registered:** the intended client lists the server as configured and
   enabled. This does not prove that the current task loaded it.
3. **Exposed:** after the client-prescribed restart or a new task, the expected
   Xcode tool namespace is visible. Do not assume hot reload.
4. **Connected:** one bounded, read-only workspace-list call returns from Xcode.
   Record the exact container path and `workspaceIdentifier`.

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
