# Update the installed collection

Inspect the active installation's method, client scope, resolved paths, local
changes and observable provenance. A bundle receipt may name a commit; a selective
copy may expose only a source URL and folder hash. Record unknown revision data
explicitly. If adding missing dependencies to an unidentified copy, stage the
selected dependent set together from one reviewed source snapshot.

Preserve rollback and account for active consumers before activation. Zero leases
alone does not establish quiescence. Keep active/historical run grants unchanged;
fresh work needs fresh bindings. Do not require approval merely to wait.

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

The collection does not ship a general updater for custom versioned bundles.
Ask your agent:

> Update my installed Apple Platform Engineer skills from
> ShawnBaek/ai-workflow-apple-platform-engineer. Identify my installation method,
> preserve its scope and local changes, validate the new revision, and report the
> active paths and revision afterward.

## Verify the active result

1. Check actual loaded paths and observable source revision/hash, not only the README
   version label. Confirm one discoverable copy of each selected skill.
2. When the selected setup uses the harness Swift runtime, build the changed executable once with the
   selected full Xcode and run the relevant [Swift verification](../../agent-harness/references/swift-verification.md).
   Keep executable, sources and contracts together. A documentation-only update
   does not by itself justify a new build.
3. If a private coordinator/runtime binding is configured, follow the explicit
   [runtime migration procedure](../../agent-harness/references/swift-verification.md)
   before resuming coordinated work. New hashes do not renew old approvals.
4. Start a fresh task or use your client's supported skill reload, confirm the
   resolved path, then try one representative task with its normal evidence.

If validation fails, retain or restore the previous complete installation and
record the failure. Installed files, a valid runtime binding and a successfully
executed user task are separate checks.
