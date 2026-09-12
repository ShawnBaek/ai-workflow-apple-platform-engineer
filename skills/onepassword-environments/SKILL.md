---
name: onepassword-environments
description: >-
  Connect and use the official local 1Password Environments MCP server for
  development secrets, environment variables, and optional local .env mounts.
  Diagnose startup, macOS app-data permission, authentication, and current-agent
  tool exposure failures. Use for 1Password development ENV work, not software
  license inventory or general vault-item management.
---

# 1Password Environments

Keep development secrets in the user's chosen 1Password account and Environment.
This skill owns authorized setup, repair, and ENV work; the read-only
`apple-development-health` skill only reports readiness.

## Establish the connection

1. Identify the agent client, its actual configuration, the installed 1Password
   version, and the official executable. Installing this skill does not install
   or connect an MCP server.
2. Read [setup and troubleshooting](references/setup-and-troubleshooting.md) for
   registration or a failed connection. Record installation, registration,
   protocol response, current-task tool exposure, and account authentication as
   separate states. Do not repair a working layer because another layer failed.
3. Once connected, read the server's `1password://docs/getting-started` and
   `1password://docs/environments-guide` resources and inspect live tool schemas.
   Prefer version-specific release notes over an older settings label in a guide.
4. Call `authenticate`, let the user complete any 1Password prompt, and use the
   returned `account_id`. Confirm that the selected account is the intended one;
   never copy an account or Environment ID from an example or previous task.

## Work with development environments

Use these tool names as discovery hints; the live schema is authoritative.
Arguments currently use camelCase, including `accountId` and `environmentId`.

| Tool | Purpose |
| --- | --- |
| `authenticate` | Obtain the current connection's account ID through 1Password |
| `list_environments` | Find existing Environments in that account |
| `create_environment` | Create an authorized project/environment grouping |
| `rename_environment` | Rename the exact selected Environment |
| `list_variables` | Read variable names; stored secret values are not returned |
| `append_variables` | Add variables with `name`, `value`, and `concealed` |
| `create_local_env_file` | Mount an Environment at an approved local path |
| `list_local_env_files` | Inspect existing mounts before creating another |

List existing Environments before creating one. Reuse the matching project and
stage; distinguish `development`, `test`/`staging`, and `production` using the
actual endpoint, deployment configuration, and user's intent. A filename or the
word “product” does not establish production use. Keep uncertain classification
explicit instead of silently assigning a live credential to a development ENV.

For an authorized migration, inventory source paths and variable names without
printing values. For file migration, use a local transfer that reads the values
and constructs the official MCP's structured arguments without returning values
to the agent. Structured arguments alone do not keep secrets out of model
context. Never ask the user to paste secrets into chat. Keep values out of shell
arguments, history, debug output, screenshots,
reports, commits, and PRs. Never turn on unredacted logging to diagnose access.
Set `concealed: true` for keys, tokens, passwords, and private-key material.
Use `concealed: false` only for configuration that is safe to display.

Check existing variable names before a write. Do not assume that
`append_variables` replaces a duplicate: establish the current tool's behavior
and the intended replacement before updating existing credentials. Check the
write result and list names afterward. Name presence proves existence, not
byte-for-byte equality of secret values. Application compatibility needs a
selected consumer that returns only success/failure. If value or consumer
verification remains incomplete, preserve source files and Git stashes and
report that limitation. Source cleanup needs its own authorization. Previously
exposed plaintext credentials may need rotation; record that follow-up without
silently replacing credentials or changing the consuming application.

1Password may request connection, tool, or Environment approval. Approved
Environment access can persist until 1Password locks; do not promise a fresh
prompt for every call. Distinguish an unanswered prompt from a broken server.
Software licenses and arbitrary vault items require a separate supported tool;
do not imply these eight ENV tools can manage them.

## Mount only when the application needs a local .env

Inspect `list_local_env_files` and the destination's file metadata first. A mount
must not overwrite an existing `.env`, Git-tracked file, or unreviewed symlink.
Creating a mount is a separate filesystem exposure from storing variables.
Confirm the destination and applicable approval before creating it; an ENV
migration request alone does not select a mount path.

On macOS/Linux, these mounts are UNIX named pipes, not ordinary plaintext files.
Once a mount is authorized, other processes can read it until 1Password locks
or the mount is disabled. It is not restricted to the process that first asked.
Concurrent readers and aggressive file watchers can conflict. Verify through
mount metadata and a deliberately selected consumer that does not echo values;
do not use `cat .env`, shell tracing, or a watcher as a health check.

## Completion evidence

Report the exact layers verified, the selected project/stage, variable names or
counts, and any unverified migration or mount behavior. Do not claim the active
agent can invoke tools solely because a separate process completed a handshake.
Do not publish private account IDs, Environment IDs, source paths, or secrets as
public troubleshooting examples.

## Sources

- [Official 1Password MCP guide](https://www.1password.dev/environments/mcp-server)
- [Local .env behavior and exposure](https://www.1password.dev/environments/local-env-file)
