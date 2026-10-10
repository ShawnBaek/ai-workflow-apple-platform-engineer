# Update installed skills

Use your original installation method and client scope. Preserve local changes
and the previous complete installation for rollback. Updating a repository
checkout does not update a copied skill bundle. Before updating, read the
target version's Migration notes in the [changelog](../CHANGELOG.md).

The [update procedure](../skills/apple-platform-setup/references/updating.md)
ships inside `apple-platform-setup` and owns every step:

| Step | Section |
|---|---|
| Identify each root's installation shape and run the read-only inventory | [Inventory before reconciling](../skills/apple-platform-setup/references/updating.md#inventory-before-reconciling) |
| Rerun the Skills CLI `add` with the original clients, copy mode and a reviewed ref; never a bare `npx skills update` | [Skills CLI installations](../skills/apple-platform-setup/references/updating.md#skills-cli-installations), pinned to the [tested version](../skills/apple-platform-setup/references/updating.md#skills-cli-version) |
| Update a linked checkout or a versioned bundle and its per-skill links | [Linked checkout or versioned bundle](../skills/apple-platform-setup/references/updating.md#linked-checkout-or-versioned-bundle) |
| Confirm the update landed, not just that the command exited 0 | [Verify the active result](../skills/apple-platform-setup/references/updating.md#verify-the-active-result) |

A skill root often mixes these shapes with other collections' entries. Resolve
each entry's target and leave anything outside this collection untouched.

With `apple-platform-setup` installed, ask:

```text
$apple-platform-setup Update this installation and verify the selected tools.
```

Use `/apple-platform-setup` in Claude Code. If it is not installed yet, ask your
agent to follow the update procedure linked above.

```text
Inspect the active copy and selected tools; run the read-only inventory
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
