# Optional private project registry

Set `APE` to the built Swift verifier; see [setup](../../../docs/getting-started.md).

Use the registry only when a developer wants one local inventory to locate
several Apple projects or several checkouts of one project. It is a read-only candidate adapter before the harness is frozen. It is never authority, a task
database, or a resource lock.

## Resolution contract

Keep these signals in order:

1. For an Xcode task, the exact project or workspace the developer opened is authoritative. A conflicting explicit repository path blocks resolution.
2. Otherwise, an explicit repository path wins over registry entries.
3. Only when neither signal resolves the target may the registry provide
   candidates for the current developer and host.
4. Select a registry candidate only after live validation of its canonical Git
   top level, normalized remote fingerprint, and repository-relative Xcode
   containers.
5. If more than one valid candidate remains, return `needs_selection`. Never
   choose the first, newest, or `primary` entry automatically.

Resolver outcomes are machine-readable: `resolved` exits 0, `blocked` exits 2,
`needs_selection` exits 3, and `unavailable` exits 4. A registry-backed CLI
result includes a canonical `registry_sha256`; retain it with the resolution
reason, `resolver_version`, `worktree_authorized`, `candidate`, `warnings`, and
live evidence. Registry-backed CLI output always supplies this stable health
projection; `needs_selection` may additionally include local candidate choices.
Valid selection may include sanitized warnings only for missing or mismatched
unselected checkout facts, which health classifies as degraded rather than
silently repairing or selecting them.

The `primary` and `worktree` values describe existing checkouts; they grant no
permission. A worktree still requires explicit approval for the current task.
The resolver never creates, copies, switches, repairs, or deletes a checkout.

Once resolved, copy the validated absolute root and exact Xcode container into
the run harness. From that point the normal repository, branch, Xcode, health,
and authorization gates apply. Revalidate live state before every protected
write; registry contents are never proof that a checkout is still safe.

## Private setup

1. Copy
   [`project-registry.local.example.json`](../templates/project-registry.local.example.json)
   to a developer-selected private or ignored location. No parent directory is
   prescribed.
2. Choose opaque `developer_id`, `host_id`, `project_id`, and `checkout_id`
   values. Do not store credentials, Apple/GitHub account data, customer names,
   or message destinations.
3. From the installed skill, inspect each exact Git top level without printing
   its remote:

   ```sh
   "$APE" resolve-project --fingerprint-path '<absolute-repository-path>'
   ```

4. Store the returned `remote_fingerprint`, absolute checkout path, checkout
   kind, and repository-relative `.xcworkspace` or `.xcodeproj` paths.
5. Resolve a candidate and inspect the structured result before creating a run:

   ```sh
   "$APE" resolve-project \
     --registry '<private-registry-path>' \
     --developer-id '<developer-id>' \
     --host-id '<host-id>' \
     --project-id '<project-id>'
   ```

Pass `--explicit-path` when the user supplied an authoritative checkout. Pass
`--opened-xcode-container` for an Xcode task. An existing worktree may be
considered only after the current task explicitly authorizes `--allow-worktree`.

## Static registry versus live task state

The registry may contain only durable discovery data. Do not add branch, HEAD,
dirty state, task/session IDs, Spec Kit feature IDs, GitHub Issue/Project state,
agent/model choice, lease owner, timestamps, tokens, or account identifiers.

Each task keeps its own append-only run ledger. Multiple read-only tasks may use
one logical project concurrently, but mutation requires one repository-wide
writer lease derived from versioned normalized repository identity. Different
checkouts do not create different writer identities. Every mutating acquire uses
the explicitly configured host-shared atomic coordinator and records its
fenced receipt; without a live receipt, stop with `coordination_required`
instead of treating registry or ledger files as locks. The coordinator location
is private runtime configuration, never a registry field.
The exact key, overlap, and expiry rules are machine-readable in
`../contracts/capabilities.json` under `resource_overlap_policy` and
`cross_run_coordination_policy`.

## Privacy and publication

- Keep the populated registry untracked and outside screenshots, CI artifacts,
  prompts sent to retrieval systems, PR bodies, and completion reports.
- Publish only schemas, placeholder examples, stable reason codes, and hashes.
- Never print a credential-bearing remote URL. Reject remotes containing user
  information, query, or fragment before hashing.
- Do not embed a real project name, developer home path, or private registry
  contents in fixtures or examples.
