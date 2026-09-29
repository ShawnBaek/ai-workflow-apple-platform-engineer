# Update installed skills

Use your original installation method and client scope. Preserve local changes
and the previous complete installation for rollback. Updating a repository
checkout does not update a copied skill bundle. Before updating, read the
target version's Migration notes in the [changelog](../CHANGELOG.md).

## Identify the installation you actually have

The procedure differs per installation shape, and the shape is not obvious from
the client — the same agent can load a CLI copy, a link into a checkout, or a
versioned bundle. Resolve it before updating anything. Read the client roots and
the Skills CLI lock:

```sh
ls -la ~/.agents/skills "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"   # real directories, or links? where do they point?
readlink "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/apple-platform-engineer"
LOCK="${XDG_STATE_HOME:+$XDG_STATE_HOME/skills}"; LOCK="${LOCK:-$HOME/.agents}/.skill-lock.json"
grep -A8 '"apple-platform-engineer"' "$LOCK"   # source, ref and hash the CLI recorded
```

The lock records source, ref and hash, not clients; the roots show those. Do
not take them from `npx skills list -g`: its `Agents` column names the clients
the CLI detects on this machine (Codex only while `$CODEX_HOME`, `~/.codex` or
`/etc/codex` exists), not the ones the install targeted; it never shows the
ref; and it lists links it did not make, such as a bundle's, as
`Source: local`.

- **Claude Code links into the CLI's `~/.agents/skills` copy** (links to
  `../../.agents/skills/<skill>`, with the skill in the lock) → a Skills CLI
  install for both clients, the layout the README command makes.
- **Real directories** → a copy. With the skill in the lock, it is a Skills CLI
  install for one client (Claude Code alone copies into `~/.claude/skills`,
  Codex alone installs into `~/.agents/skills`) or with `--copy`. Without it,
  the copy was made another way, and an empty update result is not proof that
  it is current.
- **Links into a Git checkout** → update the checkout, respecting its branch.
- **Links through a shared pointer** (`…-active`) → a custom versioned bundle;
  follow the staged-bundle procedure, which also reconciles the per-skill links.

For a Skills CLI install, rerun the original `add` with the same `-a` list and
names and the reviewed revision as `owner/repo#<ref>`, as the
[update procedure](../skills/apple-platform-setup/references/updating.md#skills-cli-installations)
shows, with the pinned [Skills CLI version](../skills/apple-platform-setup/references/updating.md#skills-cli-version).
Do not run a bare `npx skills update`: it drops the original `-a` list and
copy mode, and a pinned install (`owner/repo#<ref>`) never leaves its ref.
Rerunning `add` with the new ref, or with none, is what moves it.

A skill root often mixes these, plus entries from other collections. Resolve each
entry's target and leave anything outside this collection untouched.

With `agent-harness` installed, its verifier lists every client root at once,
read-only, before you reconcile anything: Claude Code, Codex (including the
deprecated `~/.codex/skills`), the project's roots, Xcode's agent roots, and the
Skills CLI's global lock and project `skills-lock.json`. It marks which entries
are this collection's, and which are outdated, retired, split between clients,
duplicated, broken, stale in a lock or carry a collection name without
ownership evidence. Setup reconciles the collection's own entries after one
approval. A duplicate with no Apple or client-reserved copy, or a same-name entry it
cannot attribute, is shown with its evidence and moved to a backup only on your answer for that entry, and a stale
Xcode plug-in import is yours to remove in Xcode's Intelligence settings.

Verifiers released before `skill-inventory` (2.0.0-beta.11 and earlier) lack
it and answer `Unknown command`. Build the verifier from the staged new revision, in a folder
outside every skill root (a fresh clone of the reviewed revision, for example),
as in
[Build and locate the verifier](../skills/agent-harness/references/swift-verification.md#build-and-locate-the-verifier)
with `AGENT_HARNESS_ROOT` set to that copy's `skills/agent-harness`. One built
inside `~/.agents/skills` compares the copies beside it with themselves and
reports them `unverified`. Then run:

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
   inventory with the verifier built from the new revision outside the skill
   roots, or pass `--repository-root '<reviewed checkout>'` before
   `skill-inventory` (one from the previous revision compares with its own
   older copy). It reports each selected skill `current`; check that no
   `outdated`, `unverified`, `retired`, `unlisted`, `split`, `duplicate`, owned
   `broken` or `staleLock` finding remains for the collection. A copy that no
   lock attributes to a repository, such as one made without the Skills CLI,
   stays `unverified`, with a `reason` saying so; step 2's comparison covers
   it. A reinstall from a local checkout path is different: the CLI records no
   global lock entry for it, so an earlier GitHub entry, with its old ref and
   hash, stays and the inventory flags it. Reinstall from `owner/repo#<ref>`
   so the lock is rewritten.
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
