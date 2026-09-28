# Apple development health matrix

Collect only the rows required by the selected profile. Bound every probe and
record timeout as an infrastructure observation, never as a failed app test.

## Agent and skill surfaces

- Confirm the selected mode: Codex, Claude, or collaborative with one writer.
- Resolve each required skill in the effective client environment. Report a
  missing skill, duplicate shadowing copy, broken symlink, and different client
  versions separately.
- Check Codex and Claude configuration independently. Shared files or installed
  skills do not prove that the current task exposed the same tools.
- A Local LLM is optional and loopback-only. When selected, prove only the
  required retrieve/rerank/extract/cluster capability; do not pull a model,
  expose a port, or send credentials during health collection.

## Installed skill inventory

A guarded run's `agent.skills` check binds only its required skills, and a
standalone installation has no harness at all. `apple-verify skill-inventory`
covers both: it needs no harness and reports every installed entry.

```sh
"$APE" skill-inventory --project '<repository>' [--output '<new-report.json>']
```

It lists the top-level entries of these roots and reports a missing one as
`absent`:

| Client | Roots |
| --- | --- |
| Claude Code | `$CLAUDE_CONFIG_DIR/skills` (else `~/.claude/skills`); `.claude/skills` in the project directory and each parent up to the repository root |
| Codex | `~/.agents/skills`; the deprecated `$CODEX_HOME/skills` (else `~/.codex/skills`), which Codex still loads; `.agents/skills` in the same directories, and `.codex/skills` there, which Codex loads only for a trusted project (the inventory lists it without reading that setting) |
| Xcode's agents, when present | `~/Library/Developer/Xcode/CodingAssistant/codex/skills`, its `__xcode` folder of Xcode's own Apple skills, `ClaudeAgentConfig/skills` and the imported `AgentPlugins` |

`--home`, `--codex-home`, `--claude-config-dir` and `--xdg-state-home` replace
the environment values. Hidden entries (Claude Code's `.trash`, Codex's
`.system`) are counted, not classified. So are the names Claude Code skips in
its roots: a `synced` folder in any capitalization, and a folder named
`anthropic-skills` or starting with `anthropic-skills:`. Codex also loads a
`SKILL.md` nested deeper in a root, and Claude Code may read a main checkout's
project skills from a linked worktree; pass that checkout as `--project` to
list it. Of plugin skills, only the ones Xcode imports into `AgentPlugins`
are listed. The others, in Claude Code's and Codex's plugins and in Xcode's
`codex/plugins` and `ClaudeAgentConfig/plugins`, are named
`<plugin>:<skill>`, so none collides with a collection name.

The inventory reads two kinds of Skills CLI lock. The global lock records
global installs into the user roots. It is
`$XDG_STATE_HOME/skills/.skill-lock.json` when that variable is set, else
`~/.agents/.skill-lock.json`. A project-scope install (`npx skills add`
without `-g`) is recorded only in `skills-lock.json` in the directory it ran
in. That lock covers the same directory's `.agents/skills` and
`.claude/skills`, and the report lists it under `projectLocks`. No lock covers
`.codex/skills` or Xcode's roots, and the global lock never covers a project
root.

An install from a local path is recorded differently. A global one gets no
lock entry, and a project one gets an entry with `sourceType` `local` and a
path relative to the lock. A path names no repository, so such an entry
attributes its skill to no one. Each lock's report lists those names under
`localSource`, and the names it still gives a former name of this repository
under `legacySource`: those were installed before the rename and are likely
outdated.

Each client lists a folder once. A root that reaches the same folder as an
earlier root of the same client, such as `~/.codex/skills` linked to
`~/.agents/skills`, is reported as `sameFolder` and not listed again. A folder
two clients share, such as `~/.claude/skills` linked to `~/.agents/skills`, is
listed for each client, and the later root names the earlier one in
`sameFolderAs`.

An entry is the collection's only when one of these holds, and the report
names that evidence:

- `path`: it resolves into the running verifier's own `skills/` folder;
- `copy`: it resolves into the `skills/` folder of another copy of this
  collection outside the scanned roots, such as a versioned bundle an
  activation link selects or another checkout. That copy's
  `agent-harness/lifecycle/skill-lifecycle.json` names this repository or a
  former name, or, in a release from before that file,
  `agent-harness/contracts/capabilities.json` exists, the marker the verifier
  uses to find its own harness. Either file counts only in a real
  `agent-harness` folder: that folder, its `lifecycle` or `contracts` folder
  and the file itself are never links, so a folder of other owners' skills
  that links any of them to a checkout is not a copy. A lifecycle file that
  names another source makes the copy another owner's. The entry names the copy's `root` and the
  `version` in its `VERSION` file under `installedFrom`, and is compared with
  the running verifier's copy like any other;
- `lock`: the lock that covers its root names this repository or a former
  name (`legacySources`) for it;
- `hash`: its content hash equals the collection copy's;
- `link`: it resolves to the folder of an entry one of those rules made ours,
  through its own link or a root linked to another root.

Everything else is foreign, and Xcode's own `__xcode` skills are Apple's;
neither is ever claimed. A name Xcode reserves, or a client builtin the
collection does not use, is `reserved` whatever the evidence.

The verifier may run from an installed copy. Its `skills/` folder is then a
scanned root that can also hold other owners' skills: `~/.agents/skills` for a
global Skills CLI install, or the project's `.agents/skills` for a
project-scope one. There only two kinds of entry are the collection's and
serve as reference copies: the verifier's own `agent-harness`, and the entries
that root's lock gives this repository or a former name.

A lock proves nothing about a name it does not give a repository, even when it
records `agent-harness`, because one installation can mix sources. A skill
added later from a local checkout, as the
[update reference](../../apple-platform-setup/references/updating.md#skills-cli-installations)
does, has no global entry or only a local-path project entry, and a copy made
without the CLI has none. These are `unverified`, never claimed and never
foreign, with a `reason`:

- a collection name beside the verifier with no lock entry:
  `beside the verifier; no lock records it`;
- one whose lock records a local path:
  `beside the verifier; its lock records a local path, which names no repository`;
- a copy elsewhere with the same content as either:
  `same content as the copy beside the verifier, which no lock attributes`;
- any other collection name that the lock covering its root records from a
  local path, with `lock: local`:
  `its lock records a local path, which names no repository`;
- any other collection name in a root whose lock is unreadable (not a regular
  file, or not valid JSON), with `lock: unreadable`:
  `the lock covering its root is unreadable`; and one that resolves to such an
  entry's folder:
  `resolves to the folder of an entry whose lock is unreadable`. That lock's
  report has `status` `unreadable` and a `reason`.

A collection name that its lock gives another repository or package is
`foreignSameName`, with `lock: foreign`.

Content is compared with the copy beside the running verifier, so run the
verifier built from the revision you expect. Before an update, the new
revision's verifier reports links into the older bundle `outdated`, with that
bundle's `installedFrom` version; afterwards, `current`. A copy inside a
scanned root proves nothing by its location, because other owners' skills can
share that folder, so a verifier built elsewhere finds no ownership evidence
for its unlocked entries. A client root that is itself a link to a checkout's
`skills/` folder makes that checkout a scanned root, so its collection names
are `unverified` beside the verifier; link each skill instead, as the
[per-skill link farm](../../apple-platform-setup/references/updating.md#reconciling-the-per-skill-link-farm)
does. Whether a newer release exists is a separate update check.

| Class | Meaning |
| --- | --- |
| `current` | The collection's, current and identical to the copy beside the verifier |
| `outdated` | The collection's and current, but its content differs |
| `unverified` | The collection's, but its content could not be compared; or a collection name no lock attributes to a repository, as above. `reason` says which |
| `retired` | The collection's retired ID is still installed; the report names `replacedBy` |
| `unlisted` | Its evidence (`path`, `copy`, `lock` or `link`) makes it the collection's, but the lifecycle file does not list the name |
| `split` | A current skill the collection installed for one client but not the other, in a `current`, `outdated` or `unverified` copy, once both have collection entries. `occupiedBy` names the lacking client's roots where another entry already holds the name |
| `duplicate` | Two roots of one client list the same name for different folders; `equalContent` says whether their content matches. In Claude Code, `/<name>` runs the personal copy over a project one, and the repository root's copy over a nested directory's, which stays reachable as `/<dir>:<name>`. Codex lists both, and a plain `$name` injects neither. Entries that resolve to one folder are not duplicates: Codex dedupes a `SKILL.md` it reaches twice |
| `broken` | A link whose target is missing |
| `staleLock` | A lock names this repository or a former name for a retired or unlisted skill, or for one installed in none of the roots it covers; `lock` says which lock |
| `foreignSameName` | An entry with a current or retired collection name, no ownership evidence and none of the `unverified` cases above: another owner's (`lock: foreign` when its lock names that owner), or an installation this verifier cannot attribute. An `AgentPlugins` skill is namespaced `<plugin>:<skill>` and does not collide with the bare name; it is listed so a stale import stays visible |
| `reserved` | Another owner's entry with a name Xcode or a client reserves |

`split` and `duplicate` compare the Claude Code and Codex roots only. They
match entries by folder name, while Codex names a skill by its `SKILL.md`
frontmatter `name`, so a renamed folder is not matched. Each root also counts
`foreign` entries (another owner's, with an unrelated name), `apple` entries
(Xcode's own skill folders) and `ignored` ones (not a skill folder, such as a
file beside Xcode's own skills). The report also gives per-root counts, a
per-class summary and, for each class present, the approval-gated
[setup step](../../apple-platform-setup/references/updating.md#inventory-before-reconciling)
that would reconcile it. It exits 0 when nothing needs a decision, 1 when a
finding does, and 2 on an error.

The inventory is strictly read-only. It creates, modifies, deletes and chmods
nothing. It opens only the lifecycle file, the locks, the files of skill
folders it hashes, and the lifecycle file and `VERSION` of a copy of the
collection an entry resolves into, never client configuration,
authentication, history or session files or a plugin manifest. `--output`
writes one new file. It refuses to overwrite, to write at a lock path, even an
absent one, or to write inside a scanned root, the collection's skills folder
or a folder a scanned entry links to, whether the path reaches it as given or
once resolved. It executes no remediation.

## CLI provenance

For each required CLI (`git`, `gh`, `swift`, `xcodebuild`, `xcrun`, `asc`,
`specify`, `codex`, `claude`, and optional `ollama`), record:

- command lookup and all matches;
- resolved real path;
- version/help response;
- package-manager ownership when relevant;
- selected client/config scope.

Cross-check a claimed Xcode MCP binary against Homebrew formula inventory,
global npm packages, transient npx cache, and live process parentage. A Homebrew
tap is not an installed formula. `npm exec ...@latest`, a global NVM binary, and
a Homebrew formula are different provenance and drift risks.

## Optional private project registry

Select this component only when the run actually used the registry adapter. The
required health check ID is `repository.project_registry`.

Run the resolver once with `--registry`, the current opaque developer/host IDs
and the same explicit-root/opened-container signals used by intake. Record its
`resolver_version`, canonical `registry_sha256`, status/reason code, selected opaque
project/checkout IDs, remote fingerprint, and whether worktree consideration
was explicitly authorized. Copy the stable health-projection fields into the
report's structured `project_registry_resolution`; omit any local
`candidates` selection list. A prose evidence item cannot replace it.
Then independently confirm the selected canonical path is the exact live Git
top level and matches the harness authoritative root. For Xcode work, also
confirm the selected repository-relative container resolves to the exact opened
container.

A uniquely resolved, live-matching candidate is healthy. Invalid or stale
unselected inventory makes the component degraded and should be repaired
outside health. A developer/host mismatch, ambiguous candidates, selected
remote/root/container mismatch, or unapproved worktree is blocked. Do not print
the populated registry, credential-bearing remotes, or unrelated absolute
paths; do not edit the registry, scan the filesystem, or select a fallback.

## Xcode MCP ladder

Installation, registration, current-task exposure, and read-only connectivity
are four separate facts. Report every provider injection layer:

1. official Codex route: `xcode -> xcrun mcpbridge`;
2. direct third-party Codex MCP entry;
3. MCP contributed by an installed Codex plugin;
4. Xcode Coding Assistant AgentPlugin, including an independent npx process.

`xcrun mcp-server enable` enables an Apple service/permission; it is not Codex
registration. Codex registration uses
`codex mcp add xcode -- xcrun mcpbridge` (global) or an `[mcp_servers.xcode]`
table in a trusted project's `.codex/config.toml`
([per-project registration](../../xcodebuild/references/xcode-mcp-project-setup.md)),
bound to the selected Xcode through the server's `DEVELOPER_DIR` as in
[provider preflight](../../xcodebuild/references/xcode-mcp-provider-preflight.md#bind-the-bridge-to-the-selected-xcode).
A newly registered tool may require a
new client/task before it is exposed. Treat blanket
`--unsafe-always-allow-all-agents` as a security warning.

After registration and exposure, make one bounded read-only call. Bind the
opaque workspace identifier returned by the current Xcode session; do not pick
the first duplicate path/window. A diagnostic process search can match the
diagnostic command itself, so observe again after it exits before declaring a
provider live.

Use a capability matrix rather than one connection bit:

| Capability | Separate result |
| --- | --- |
| workspace discovery | exact current workspace response |
| target/scheme/destination discovery | only when needed by the task, not a connectivity probe |
| interaction session start/end | fresh session lifecycle |
| workspace-bound install/run | selected workspace and destination |
| hierarchy/touch/capture | actual interaction semantics |
| direct Apple CLI path | fallback evidence, not proof MCP is healthy |

Health itself probes only discovery and, after an access grant, one fresh
session. The install/run and hierarchy/touch/capture rows cite evidence from
the skill that performed them (`xcodebuild`, `screenshot`) for the same
workspace and destination. Without that evidence, list the row as omitted in
the check's `evidence`; a row the task requires then leaves the check
`degraded` or `blocked`, never `healthy`.

One capability may be degraded while another works. After a user grants Xcode
agent access, discard a stale session, start one fresh session, retry the blocked
read-only capability once, then stop if unchanged. Do not repeat 300-second
build/install/launch loops.

## AppleSampleCode MCP

Treat AppleSampleCode as an optional independent analysis source, not an Apple
official MCP or a substitute for live Apple documentation. When the harness
selects `apple_sample_code_mcp`, verify these layers separately for each selected
client:

The required health check ID is `mcp.apple_sample_code`.

1. exact registration name `apple-sample-code` and streamable HTTP endpoint
   `https://mcp.applesamplecode.com/mcp`;
2. exposure in the current task after any required client restart;
3. the exact read-only tools `search_samples`, `get_sample`, `compare_samples`,
   and `get_status`;
4. one bounded `get_status` call with `refresh: false`.

Codex registration is
`codex mcp add apple-sample-code --url https://mcp.applesamplecode.com/mcp`;
Claude Code registration is
`claude mcp add --transport http apple-sample-code https://mcp.applesamplecode.com/mcp`.
These are repair/configuration mutations and do not belong inside health. An npm
or public MCP Registry release is not required for the remote endpoint.

Do not probe this streamable HTTP server with GET and call an allowed `405` a
failure. Use an MCP client or a bounded JSON-RPC initialization plus the
read-only tool call. Record server version, corpus revision, sample and validated
sequence-diagram counts, source mode, `isLatest`, `lastError`, and observation
time without turning current counts or an alpha version into permanent policy.
`isLatest: null` is unknown freshness; `isLatest: false` is degraded when the
corpus remains usable; a missing revision, missing tool, failed initialization,
or unusable status response is blocked when selected. If not selected, report
`not_applicable` rather than requiring installation.

## GitHub, Spec Kit, and delivery

- Verify the exact remote repository under the approved GitHub user or
  organization, the viewer's write-level permission on it, Issues availability,
  and PR capability. An organization owner never equals the signed-in login;
  repository permission is the authority.
- Inspect Project v2 only when selected. Missing `read:project`/`project` scope is
  a scoped Project limitation; do not refresh OAuth during health collection.
- When Spec Kit is selected, require the pinned release `v1.0.1`,
  `.specify/feature.json`, intended `specs/<feature>` artifacts, and the chosen
  workflow run's `state.json`, `inputs.json`, and append-only `log.jsonl` when
  present. Bind the explicit feature directory and approved Git branch as two
  independent identities. Compare immutable accepted artifacts before every
  external write and mutable workflow continuity as a separate checkpoint.
- When Spec Kit is selected, record the `specify --version` answer; any answer
  other than `specify 1.0.1` is a migration candidate that `spec-snapshot`
  refuses.
- Spec Kit logs describe specification/workflow state; the harness ledger owns
  approvals, attempts, leases, evidence, and external writes.
- For TestFlight profiles, verify the private Apple account/team guard before
  account discovery, then exact app, bundle, platform, version/build policy,
  `asc` capability, agreements/compliance, signing/archive prerequisites, and
  named internal group IDs. Each authorized group must be listed by
  `asc testflight groups list --app <id>` (asc 0.38.0 or later; the
  `beta-groups` alias was removed in 1.0.0) with `isInternalGroup` true.
  Do not upload during health collection.

## CoreSimulator and runtime layers

Health collects only the read-only runtime inventory: `xcrun simctl list
runtimes --json`, plus `xcrun simctl list devices available --json` when the
task needs a destination, each once within 30 seconds. An inventory that does
not return in time is an infrastructure gate failure, not an app failure. Use
one bounded retry for a read-only MCP capability. Route duplicate-build,
disk-image, unavailable or `Deleting` findings to `core-simulator-health`
without mutation; it owns runtime repair.

Never infer a single root cause from old beta images, a large inventory, low
disk space, multiple MCP processes, host/Xcode drift, or runtime verification
error `-67054`. They are evidence or hypotheses until a controlled comparison
proves causality.

A fully usable runtime has further layers that health does not run, because
they boot devices, install apps or run tests: a monitored boot of a temporary
device (named and deleted as in
[destination reuse](../../xcodebuild/SKILL.md#choose-and-reuse-a-simulator-destination)),
a second boot when stability is an acceptance criterion, a system-app
launch, project install and launch, XCTest execution with counts,
hierarchy/screenshot/touch observation, and session shutdown.
`core-simulator-health` (boot and recovery), `xcodebuild` and
`apple-platform-testing` (install, launch and tests) run them under their own
authorization and ownership. When the task needs them, cite that skill's
current evidence for the same Xcode, runtime and destination. Otherwise list
them as omitted layers in the simulator check's `evidence`. A required layer
without current evidence leaves that check `degraded` or `blocked`; the
inventory alone never makes it `healthy`.

When reading that evidence, exit code 0, `Ready`, `Verified`, first boot,
screenshot, or install alone does not prove the complete path. In terminal boot
text, an aggregate `Data Migration Failed` is Simulator OS migration evidence
and does not implicate app Core Data/SwiftData when the app was not installed or
launched. A runtime can be partially usable and should then be `degraded`, not
healthy or dead.

Fresh-device runtime health and existing-device task validation are distinct.
Likewise, a provider omitting an older runtime from its interaction targets is a
provider coverage result, not proof that the runtime is absent. Preserve app
build/test evidence separately from infrastructure evidence.

Before labeling an interaction failure as an app bug, use hierarchy-derived
coordinates and the actual gesture semantics. A continuous drag is one
down-hold-move-up gesture; a sequence of taps is not equivalent. If the active
interaction grammar has no pinch command, use an enabled XCUITest target and
`XCUIElement.pinch(withScale:velocity:)`; do not guess syntax or claim runtime
pinch evidence from compilation alone.

## Companion upstream

For a public reference-only upstream, check repository visibility, default
branch HEAD, reviewed revision, selected source blob hashes, license state, and
consumer skill. Do not clone merely for health, execute upstream generators, or
copy code/assets/docs. A changed revision creates a review candidate; it never
auto-merges a consumer-skill change.
