# Update installed skills

Use your original installation method and client scope. Preserve local changes
and the previous complete installation for rollback. Updating a repository
checkout does not update a copied skill bundle.

With `apple-platform-setup` installed, ask:

```text
$apple-platform-setup Update this installation and verify the selected tools.
```

Use `/apple-platform-setup` in Claude Code. If it is not installed yet, ask your
agent to follow the [update procedure](../skills/apple-platform-setup/references/updating.md).
That reference ships inside the setup skill and covers Skills CLI scope/copy
behavior, linked checkouts, versioned bundles and runtime bindings.

```text
Inspect the active copy and selected tools
                  |
Stage the reviewed revision; retain rollback
                  |
Validate; wait for active consumers to finish
                  |
Activate and refresh skill discovery
                  |
Verify capabilities; fresh health for harness profiles
```

The agent reuses settled choices and continues independent setup while activation
waits for active consumers. It reports staged, active and task-verified separately.
New hashes do not renew historical run authorizations.
