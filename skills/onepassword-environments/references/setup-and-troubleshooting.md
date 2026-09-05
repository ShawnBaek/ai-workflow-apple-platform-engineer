# Connect and diagnose the official local MCP

Use a bounded check of the failed layer. Retry only after a relevant change,
such as fixing the exact permission or configuration. Repeating a client restart
or renaming the server entry does not diagnose a logger failure.

## Register the existing official executable

For macOS 1Password 8.12.34, open **Settings → Developer → Integrate with MCP
clients**. That release moved MCP out of Labs. Older versions and some official
guide text still mention Labs; verify the installed version and visible setting
instead of repeatedly looking for the old page.

The macOS app bundles
`/Applications/1Password.app/Contents/MacOS/1password-mcp`. The tested Mac also
exposed it as `/usr/local/bin/1password-mcp`. Verify the resolved binary and its
1Password installation; do not install an unrelated npm package with a similar
name. Use an absolute official path when the agent's PATH does not resolve it.

Inspect the selected client's existing registration before adding an entry.
Preserve unrelated configuration; update an existing entry rather than create
duplicates. With setup authorization, a Codex registration is:

```sh
codex mcp add 1password -- /Applications/1Password.app/Contents/MacOS/1password-mcp
```

The equivalent Codex configuration is:

```toml
[mcp_servers.1password]
command = "/Applications/1Password.app/Contents/MacOS/1password-mcp"
```

For a different installed path, substitute that verified path. Other MCP clients
use their supported **stdio** server registration with the same executable.
Do not change the configuration of a client the user is not using.

## Verify five separate layers

| Layer | Evidence |
| --- | --- |
| Installation | Installed app version and resolved official executable |
| Registration | Exact client/configuration scope, command, arguments, enabled state |
| Protocol | A successful `initialize` response and nonempty `tools/list` result |
| Current task | Tool discovery in the agent task that will perform the work |
| Account | `authenticate` and `list_environments` succeed for the intended account |

Prefer the agent's actual MCP tools. If startup failed and those tools are
absent, a diagnostic client may launch the exact configured executable in the
same host/user context. This tests the server; it does not inject tools into an
already-running agent task or bypass that task's permissions.

Use the standard newline-delimited JSON-RPC sequence over the process's stdin
and stdout, with a bounded deadline (for example 15 seconds):

1. Send `initialize` with a supported `protocolVersion`, client identity, and
   capabilities; await the matching successful response.
2. Validate the negotiated protocol version and server capabilities.
3. Send `notifications/initialized`.
4. Send `tools/list`; await its matching response and inspect tool names/schemas.
5. Close only the diagnostic child process that this check started.

Keep stderr separate from JSON-RPC output, cap captured diagnostics, and avoid
logging environment variables. A handshake/tool-discovery check does not call
`authenticate`, read variables, create Environments, or mount files. Account
verification is the next explicit step in the skill.

Do not use `1password-mcp --help` as a success criterion. In the observed
macOS 8.12.34 incident it still returned `ConnectionClosed("initialized request")`
after the logger problem was fixed: a real MCP handshake succeeded. Process
exit by itself did not distinguish protocol misuse from the original failure.

## `Failed to start logger` on macOS

Observed failure:

```text
Failed to start logger: Log cannot be written, e.g. because the configured output directory is not accessible
```

This occurs before account authentication in the observed incident. Establish
the failing path and host permission result before changing anything:

1. Inspect only metadata and accessibility of the official log directory:
   `~/Library/Group Containers/2BUA8C4S2C.com.1password/Library/Application Support/1Password/Data/logs`.
   Directory existence and correct ownership do not prove that macOS permits
   the calling app to access its contents. No MCP-specific log filename is
   established by the official diagnostics guide.
2. When needed, inspect a short, incident-specific macOS privacy/TCC log window
   for the MCP process, its **responsible application**, denied service, and
   `fine_grained_object_identifier`. A shell launched by Codex can be attributed
   to Codex; a test from iTerm can be attributed to iTerm. Do not grant access to
   the wrong client just because both invoke the same executable.
3. A denied `kTCCServiceSystemPolicyAppDataDetailed` request for the 1Password
   group container points to **Privacy & Security → Files & Folders → the
   responsible app → the matching shared app-data entry**. A denied Full Disk
   Access preflight alone does not establish a need for Full Disk Access.
4. Match the container identity, not just a similar display name. In the
   observed macOS incident, **Data shared by 1Password Launcher and affiliated
   apps** controlled `2BUA8C4S2C.com.1password`. **Data shared by 1Password and
   affiliated apps** controlled the legacy `2BUA8C4S2C.com.agilebits` container.
   These labels and mappings are observations from that Mac, not a universal
   naming rule. Turning on the legacy entry did not fix the current MCP.
5. Explain the exact access change and obtain any required action-time
   approval. Permission to enable one entry is not automatically permission
   for a different entry. Acknowledge an automatic approval rejection and its
   reason; do not use a shell or indirect UI action to bypass it.
6. Apply the approved change, verify the visible switch, and repeat the bounded
   protocol check once. Then verify account authentication and ENV listing.

Do not recursively change ownership/modes, edit or reset the TCC database,
disable system protections, replace the app's HOME, invent a log-path override,
delete 1Password data, or enable broad disk access as the default repair. If
evidence instead shows a specific missing directory or ordinary file-mode defect,
report that exact finding and use a separately justified minimal repair.

## Server works, but the current agent still has no tools

Keep the successful direct handshake separate from the agent's stored startup
failure. In the observed incident, direct connection, authentication, and ENV
listing succeeded while the current Codex task retained its earlier failure.

Use a documented reconnect or refresh control if the installed client exposes
one. No supported in-turn refresh command was established for that incident;
do not invent one or promise that a configuration toggle reloads the current
turn. Coordinate a client restart if required because it can interrupt other
active tasks, then verify tool discovery again in the task that will use them.
An authorized direct client can continue ENV work through the official server,
but report that route accurately instead of claiming native tool exposure.

## Sources and scope

- [1Password 8.12.34 release notes: Developer settings](https://releases.1password.com/mac/stable/8.12.34/)
- [Official MCP configuration, tools, and approval behavior](https://www.1password.dev/environments/mcp-server)
- [Official macOS diagnostics location](https://support.1password.com/diagnostics-privacy/)
- [Codex MCP registration](https://developers.openai.com/codex/mcp/)
- [MCP 2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [MCP 2025-11-25 tool discovery](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)

The permission-name mapping, `--help` behavior, and stale task exposure above
come from a macOS incident verified on 2026-09-05 with 1Password 8.12.34. Recheck
the local facts on another version or host; they do not establish a general
1Password defect or a universal operating-system repair.
