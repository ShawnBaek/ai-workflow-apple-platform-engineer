# Update installed skills

Use your original installation method and client scope. Preserve local changes
and the previous complete installation for rollback. Updating a repository
checkout does not update a copied skill bundle. Before updating, read the
target version's Migration notes in the [changelog](../CHANGELOG.md).

## Identify the installation you actually have

The procedure differs per installation shape, and the shape is not obvious from
the client — the same agent can load a CLI copy, a link into a checkout, or a
versioned bundle. Resolve it before updating anything. From the client's skill
root (for example `~/.agents/skills`, or `~/.claude/skills`):

```sh
ls -la <skill-root>            # real directories, or links? where do they point?
readlink <skill-root>/apple-platform-engineer
npx skills list -g             # only lists CLI-tracked installations
```

- **Real directories** → a copy. `npx skills list -g` may still not know about
  it; an empty update result is not proof that it is current.
- **Links into a Git checkout** → update the checkout, respecting its branch.
- **Links through a shared pointer** (`…-active`) → a versioned bundle; follow
  the staged-bundle procedure, which also reconciles the per-skill links.

A skill root often mixes these, plus entries from other collections. Resolve each
entry's target and leave anything outside this collection untouched.

With `agent-harness` installed, its verifier lists every client root at once,
read-only, before you reconcile anything: Claude Code, Codex (including the
deprecated `~/.codex/skills`), the project's roots, Xcode's agent roots, and the
Skills CLI's global lock and project `skills-lock.json`. It marks which entries
are this collection's, and which are outdated, retired, split between clients,
duplicated, broken, stale in a lock or carry a collection name without
ownership evidence. Build it as in
[Build and locate the verifier](../skills/agent-harness/references/swift-verification.md#build-and-locate-the-verifier), then run:

```sh
"$APE" skill-inventory --project '<repository>'
```

Reconciling stays a separate, approved step that never touches another owner's
entries; see the
[installed skill inventory](../skills/apple-development-health/references/health-matrix.md#installed-skill-inventory).

## Confirm the update landed

An update that silently did nothing looks identical to one that worked, so check
the result rather than the command's exit status:

1. Read back the resolved path and revision the client will load — not the
   README version label.
2. Compare the active copy against the source revision you intended; only
   ignored build artifacts should differ. Unexplained differences are local
   overrides that need a decision, not something to reapply by habit.
3. Confirm every selected skill resolves and that no link is broken: rerun the
   inventory with the verifier rebuilt from the new revision (one from the
   previous revision compares with its own older copy). It reports each
   selected skill `current`; check that no
   `outdated`, `unverified`, `retired`, `unlisted`, `split`, `duplicate`, owned
   `broken` or `staleLock` finding remains for the collection. A copy that no
   lock attributes to a repository stays `unverified`, with a `reason` saying
   so: one made without the Skills CLI, or installed from a local checkout,
   which the CLI records as a path or not at all. Step 2's comparison covers
   it.
4. Refresh skill discovery, then run one representative task.

With `apple-platform-setup` installed, ask:

```text
$apple-platform-setup Update this installation and verify the selected tools.
```

Use `/apple-platform-setup` in Claude Code. If it is not installed yet, ask your
agent to follow the [update procedure](../skills/apple-platform-setup/references/updating.md).
That reference ships inside the setup skill and covers Skills CLI scope/copy
behavior, linked checkouts, versioned bundles and runtime bindings.

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
