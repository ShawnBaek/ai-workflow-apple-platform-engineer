# Update the installed collection

Inspect the active installation's method, client scope, resolved paths, local
changes and observable provenance. A bundle receipt may name a commit; a selective
copy may expose only a source URL and folder hash. Record unknown revision data
explicitly. If adding missing dependencies to an unidentified copy, stage the
selected dependent set together from one reviewed source snapshot.

Preserve rollback and account for active consumers before activation. Zero leases
alone does not establish quiescence. Keep active/historical run grants unchanged;
fresh work needs fresh bindings. Do not require approval merely to wait.

## Inventory before reconciling

Before any update, removal or relink, run the read-only
[installed skill inventory](../../apple-development-health/references/health-matrix.md#installed-skill-inventory)
from the installed verifier, with `APE` set as in
[Build and locate the verifier](../../agent-harness/references/swift-verification.md#build-and-locate-the-verifier):

```sh
"$APE" skill-inventory --project '<repository>'
```

It covers both client roots, the deprecated `~/.codex/skills`, the project
roots, Xcode's agent roots, the global Skills CLI lock and each project's
`skills-lock.json`, and names each entry's ownership evidence. Build the
reconcile plan from it:

- Act only on entries the report attributes to the collection. `outdated`,
  `retired`, `split`, owned `broken` and `staleLock` entries each map to an
  exact command for the entry's installation method and scope (a
  project-scope install is updated or removed from that project, without
  `-g`), with a backup of anything removed. An `unlisted` entry needs the
  user's confirmation before removal. An `unverified` one needs an inspection
  of its `reason`: content that could not be compared, or a copy that no lock
  attributes to a repository (made without the Skills CLI, or installed from
  a local checkout, which the CLI records as a path or not at all). It changes
  only after the user confirms it is this installation.
- Never act on your own on an entry the report does not attribute to the
  collection. `reserved`, `foreign` and Apple entries, a `broken` link with no
  ownership evidence, Xcode's own folders (`__xcode`, the `xcode-integration`
  plug-in) and `CodingAssistant/AgentPlugins` are reported with their owner's
  options and left alone, except where the next bullet lets the person decide.
  A `split` whose `occupiedBy` names a root is reported, not installed over.
- A `duplicate` that is not an owned stale copy and whose copies include no
  `reserved` one, and a `foreignSameName` outside `CodingAssistant/AgentPlugins`,
  are the person's decision, which setup can carry out; this covers another
  owner's skill installed twice, because the person decides for their own
  machine. A `duplicate` with a `reserved` copy is reported only, as
  [Apple skill exposure](apple-skill-exposure.md#apple-folders-are-foreign)
  requires. Keep these decisions out of the grouped approval and ask one entry at a
  time. Show
  the evidence first: each copy's root and resolved path, which copy each
  client loads, `equalContent` or a short diff against the collection copy,
  the `lock` detail and modification date. Offer: keep both; move the chosen
  copy to the backup folder; or, for a `foreignSameName`, keep it and leave
  the collection copy uninstalled there. Act only on that entry's explicit
  answer, and move rather than delete, recording the move for rollback. When
  the chosen copy is the collection's own lock-recorded install, back it up,
  then remove it with the Skills CLI from its scope with an explicit `-a`, so
  no `staleLock` is left.
- A `foreignSameName` in `CodingAssistant/AgentPlugins` is usually a stale
  import of a collection skill. Compare its `SKILL.md` with the current copy
  and, when it is stale, ask the person to remove it in Xcode › Settings ›
  Intelligence › Plug-ins. Do not edit that folder directly: Xcode keeps a
  `PluginsManifest.json` index beside the imports. Rerun the inventory after
  they confirm.
- Show the whole plan and get one explicit approval for the collection's own
  entries before running it. Remove
  with the Skills CLI only with an explicit `-a` for the affected clients.
- Rerun the inventory afterward; a remaining finding is reported, not retried
  in a loop.

## Skills CLI installations

Inspect the CLI and installed names first:

```sh
npx skills --version
npx skills --help
npx skills list -g
```

Use `list` without `-g` from your project for its local inventory. Record the
selected clients, installed names, global/project scope and copy/link mode.
Do not assume `update` preserves all four: inspected CLI 1.5.18 re-invokes `add`
without the original agent or method options, so it can target other detected
clients or change the installation layout. Use `update` only after verifying
that your CLI preserves those dimensions.

Otherwise stage and validate the intended source, retain the existing copy for
rollback, then use an explicit targeted reinstall. For these three skills in a
**global Codex copy** installation, using the reviewed source checkout:

```sh
npx skills@1.5.18 add '<absolute-reviewed-source-checkout>' -g \
  --skill apple-platform-engineer agent-harness apple-platform-ui --agent codex --copy
```

For a project copy, omit `-g` and run from that project. Match the actual clients
and names; include shared dependencies that need the same revision. Inspect the
installation summary before confirming. This example is not a link migration:
for existing symlinks, use the staged-bundle procedure below and account for all
clients sharing the canonical target. The [Skills CLI reference](https://github.com/vercel-labs/skills#available-options)
describes `add` options; check the selected CLI before use.

Do not use `npx skills check` as a read-only preview: in inspected CLI version
1.5.18, `check` calls the same updater as `update`. A manually installed copy
may be absent from CLI tracking, so an empty update result is not proof that
your active copy is current.

## Linked checkout or versioned bundle

- **Links into a Git checkout:** verify the resolved checkout and clean working
  state, fetch the intended upstream, review the target commit and fast-forward
  its release branch when appropriate. Preserve local edits and branch policy;
  do not reset an active development branch just to update a skill.
- **Copies or links into a versioned bundle:** stage the intended revision in a
  new bundle using the existing installer. Include the supporting resources
  needed by the installed skills. Validate it before switching the existing
  skill links/copies, and keep the prior bundle for rollback. Do not run a generic
  updater over custom links or rerun a one-off activation script without checking
  whether it supports an already installed revision.

### Switching the active pointer without corrupting it

A bundle layout usually has one pointer symlink (`…-active`) and a farm of
per-skill links resolving through it. Repointing that symlink is the step most
likely to fail silently, because the usual commands do something different when
the existing link resolves to a *directory*:

- `mv -f new.tmp active` **moves the new link inside the old bundle** instead of
  replacing the pointer. Exit status is 0 and the pointer never changes.
- `ln -sfn target active` has the same trap without `-n` on some shells, and
  `cp` on a link can copy the tree rather than the link.

Replace the pointer explicitly, then read it back:

```sh
rm -f "$HOME/.agents/<name>-active"
ln -s "$HOME/.agents/skill-bundles/<name>/<revision>" "$HOME/.agents/<name>-active"
readlink "$HOME/.agents/<name>-active"   # must print the new revision
```

If a previous attempt used `mv`, look for the stray link left inside the old
bundle and delete it, so the rollback copy stays byte-identical to its revision.

### Reconciling the per-skill link farm

Switching the pointer does not change which skills the farm exposes. After
activation, reconcile in both directions, and never clear the directory
wholesale:

1. **Protect local-only entries.** Some entries may be real directories or links
   to other sources rather than into this bundle. Resolve each entry's target
   first and leave anything that does not point into the bundle untouched — a
   `rm -rf` and relink destroys them. Links into an export of Apple's Xcode
   skills are foreign too; report them as
   [Apple skill exposure](apple-skill-exposure.md#apple-folders-are-foreign)
   describes.
2. **Prune stale links.** Remove bundle-managed links whose skill no longer
   exists in the new revision; otherwise a renamed or removed skill stays as a
   broken link that a client may still try to load.
3. **Add new links.** A revision that introduces a skill contributes nothing
   until it is linked; the farm will silently stay at the old skill set.
4. Confirm no broken links remain in any client root: rerun the inventory, or
   for one root:

   ```sh
   find "$HOME/.agents/skills" -maxdepth 1 -type l ! -exec test -e {} \; -print
   ```

### Local overrides are a decision, not just a copy

When the active copy differs from the revision it claims, extract the delta
before staging and decide per file rather than reapplying it by habit: upstream
it (the drift then disappears for good), keep it deliberately, or drop it.
Record kept and dropped overrides in the installation receipt, and keep the
patch for anything dropped. Silently reapplying overrides is what makes an
installation permanently diverge from every upstream revision.

The strongest post-switch check is a direct comparison with the source
revision — export it and diff against the activated bundle. Build outputs and
other ignored artifacts are expected; anything else is unreconciled drift.

The collection does not ship a general updater for custom versioned bundles.
Ask your agent:

> Update my installed Apple Platform Engineer skills from
> ShawnBaek/ai-workflow-apple-platform-engineer. Identify my installation method,
> preserve its scope and local changes, validate the new revision, and report the
> active paths and revision afterward.

## Verify the active result

1. Check actual loaded paths and observable source revision/hash, not only the README
   version label. Confirm one discoverable copy of each selected skill with the
   inventory, run by the verifier built from the new revision: rebuild it first
   as in [Build and locate the verifier](../../agent-harness/references/swift-verification.md#build-and-locate-the-verifier),
   because a verifier from the previous revision compares each entry with its
   own older copy. It reports each one `current`, and no `outdated`,
   `unverified`, `retired`, `unlisted`, `split`, `duplicate`, owned `broken` or
   `staleLock` finding remains for the collection. A copy that no lock
   attributes to a repository, such as one reinstalled from a local reviewed
   checkout, stays `unverified` with a `reason` saying so; check that copy
   against the source revision instead. A `CLAUDE_CONFIG_DIR` set only in
   Claude Code's settings `env` is not in the shell's environment, so pass that
   directory as `--claude-config-dir`.
2. When the selected setup uses the harness Swift runtime, the executable
   rebuilt in step 1 with the selected full Xcode is its changed executable.
   Keep executable, sources and contracts together.
3. If a private coordinator/runtime binding is configured, follow the explicit
   [runtime migration procedure](../../agent-harness/references/swift-verification.md)
   before resuming coordinated work. New hashes do not renew old approvals.
4. Start a fresh task or use your client's supported skill reload, confirm the
   resolved path, then try one representative task with its normal evidence.

If validation fails, retain or restore the previous complete installation and
record the failure. Installed files, a valid runtime binding and a successfully
executed user task are separate checks.
