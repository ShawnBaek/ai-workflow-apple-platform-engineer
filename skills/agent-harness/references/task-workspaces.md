# Workspaces for delegated tasks

Use this with [batch delegation](collaboration.md#delegate-a-batch-of-tasks)
before dispatching work that touches a repository or runs local tools. Reuse the
task record; do not add a workspace service or new app architecture.

## Bind each assignment

Record the task and returned agent IDs, dependency/base revision, exact checkout
and branch, allowed source paths, output directory, effective tool permissions,
and required resource ownership. Separate paths the worker may read from paths
it may change. Supply reviewers immutable source/diff inputs: a live checkout
path alone does not freeze the source while another agent edits it.

Agree who owns shared files such as the project spec, `.pbxproj`, package
manifest/resolution, app entry point, navigation, asset catalogs and storyboard
connections before dispatch. Disjoint Swift files can still depend on these
shared files. Return out-of-scope changes to the lead for reassignment; a path
list never overrides the repository-writer lease.

## Worktree, sandbox and lease are different boundaries

| Boundary | What it provides | What it does not provide |
|---|---|---|
| [Git worktree](https://git-scm.com/docs/git-worktree.html) | Separate working files and index on an identified branch | A separate repository identity, credentials or filesystem sandbox; Git metadata is partly shared |
| Client sandbox/tool permissions | The access restrictions actually configured and enforced by the client | Isolation merely because a prompt names an allowed folder |
| Harness lease | Cooperative ownership and host-resource admission for supported operations | Protection against a same-user process bypassing the harness |

Follow [git-workflow](../../git-workflow/SKILL.md) for an explicitly requested
worktree, approved branch/base and Git metadata preflight. Use its sibling
`../worktree/<sanitized-branch>` convention; never nest a worktree inside the
app checkout. An Xcode worktree needs its own authoritative session/container
under [xcode-project-workflow](../../xcode-project-workflow/SKILL.md). Do not
create one worktree per assignment merely because several tasks exist.

All worktrees of one repository still share the current coordinator's writer
conflict. Transfer ownership before the next writer runs; separate branches or
folders do not enable five simultaneous implementation writers.

Use client-enforced read-only source access for reviewers and bounded write
access for the selected writer where supported. Scope tool, network and secret
access to the assignment too. Record the actual permission profile. If a client
cannot enforce the needed restriction, disclose that gap and use supplied
source excerpts with unavailable tools withheld, or lead-controlled tool calls.
If neither is supported, stop the action requiring that isolation. Decide this
before dispatch: telling a full-access child to ask the lead to run tools does
not withhold its own tools. A shared full-access session must not be described
as a sandboxed or technically read-only worker.

Xcode and Simulator operations follow the existing logged-in-host execution
gate. Bind the host runner to the exact checkout, container, output paths and
resource lease; sandbox permission alone does not grant a build or destination.
Keep this host-tool access separate from ordinary research/editing permissions;
never disable every worker's restrictions to resolve a tool failure. See the
[enforcement threat model](architecture.md) for the cooperative boundary.

## Keep task output out of app source

Preserve the repository's actual feature/module and test organization, including
storyboard/XIB, programmatic and hybrid UI. Add a file to its existing owner;
do not introduce `Domain`/`Data`/`Presentation` layers just to divide agent work.
Respect the project's source-of-truth and file-registration rules.

Prefer an existing task-output convention. If none exists, choose one explicit
output root outside the app checkout. This is an example, not required folders:

```text
workspace/
|-- App/                         authoritative checkout
|-- worktree/
|   `-- codex-fix-offline/        only when requested and approved
`-- task-output/
    `-- offline-state-<run-id>/
        |-- evidence/            final screenshots, results and review proof
        |-- logs/                bounded diagnostics
        `-- scratch/             disposable intermediate output
```

Create only needed directories. Resolve real paths/symlink targets before use,
including the existing parent of a new output path. Pass canonical paths without
symlink aliases to the runner; the coordinator is not a complete alias sandbox.
Do not let an output path alias another task's source, evidence or cache. Give
each concurrent producer its own output path. Declare build outputs and cache
paths in the build tuple, following [host resources](host-resources.md); avoid
copying package caches into every task folder. Clean only task-owned output
within the agreed retention scope after its processes and dependants finish.
Worktree removal follows Git ownership/dirty-state checks and cleanup authority;
it is not ordinary scratch deletion.
