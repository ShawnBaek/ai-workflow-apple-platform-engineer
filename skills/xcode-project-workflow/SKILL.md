---
name: xcode-project-workflow
description: >-
  Mandatory Xcode preflight: project root and container, branch, which Xcode, host execution and XcodeGen. Use before any Xcode project edit, build, test, Simulator, signing, archive or generation step.
---

# Xcode Project Workflow

Run this preflight before every Apple/Xcode task. It defines where work may
happen; `xcodebuild` and other specialists define what to run there.

## Authoritative project gate

1. For an existing Xcode app, resolve the exact directory and `.xcworkspace`
   or `.xcodeproj` the developer opened first. The opened container type is authoritative.
2. If unknown, stop and ask. Do not search for a convenient checkout, substitute
   a project for a workspace, copy the project, or create a worktree.
3. Record the real path, repository root, branch, HEAD, remote, dirty state,
   the selected Xcode (see [Xcode selection](#xcode-selection)), and the
   opened container.
4. Return to that directory before every Xcode-related operation.

Repository documentation and standalone Swift-package work use the explicitly
selected repository and `Package.swift`; they do not require an invented Xcode
app container. For a requested new app, establish its destination, platform,
minimum OS and intended project format before creating the first container.
There is no previously opened container to recover in that case. Existing
account, signing, generation and ownership rules still apply to their actions.

If an Xcode provider returns the same container path for multiple windows or
tabs, record each session/workspace identifier. Do not choose the first result
arbitrarily; bind work to the developer's authoritative window or ask which
window to use when the identity cannot be established read-only.

An opted-in private project registry may help locate candidates only before the
authoritative gate is frozen. The exact opened container still wins. If a
registry candidate, an explicit root, and the opened container do not resolve
to the same live Git top level, stop; never switch Xcode windows, checkouts, or
worktrees to make the registry entry fit.

Use `git-workflow` for remote-default discovery, task-derived branch selection,
Git metadata preflight, and PR state. A worktree requires authority from the current
task or project policy; if approved, it must become a separate
authoritative Xcode session rather than borrowing the original open window.
When the developer asks to see an agent's worktree, clone, sandbox or cloud
changes in the Xcode they already have open, use `open-xcode-handoff`: applying
that frozen patch to this authoritative checkout at their request is neither
borrowing the window for the worktree nor copying the project.

## Host execution gate

Before choosing APIs, follow [API availability](references/api-availability.md):
resolve each affected target's minimum OS, SDK/compiler, and runtime/hardware
capabilities. Prefer suitable latest APIs when the accepted support range allows
them; isolate newer optional paths and preserve supported fallbacks otherwise.

Xcode, `xcodebuild`, Simulator, signing, archive, export, and Apple CLI commands
must run in the logged-in host environment. Never try them in a sandbox first.
CoreSimulator permission errors are environment failures, not app/test results.
Stop when host execution is unavailable or requires approval.

Before signing or an Apple account operation, resolve the account/team required
by the current private project policy. Cached Xcode state, environment variables,
profiles, or CI secrets never imply an override.

## Xcode selection

This skill decides which installed Xcode every other skill means by "selected
Xcode". Resolve it once per task, before the first Xcode, `xcrun`, `swift`,
Simulator, or Xcode MCP operation. Apply the first rule that fits:

1. use an Xcode that the user names for the task, or that the private project
   or user policy sets;
2. otherwise use a project pin found in the authoritative repository:
   `.xcode-version`, a documented Xcode requirement, or a CI workflow or
   project script that sets `DEVELOPER_DIR` to a specific Xcode version (a
   path without a version is not a pin, and a CI job the repository documents
   as a compatibility-floor lane sets only a minimum);
3. otherwise use the newest installed full Xcode: the highest version, betas
   included. When a beta and a release report the same version, break the tie
   by Apple's release status (release, then release candidate, then beta),
   never by comparing build numbers across statuses; if the status is unclear,
   ask. `xcode-select -p` is one candidate, not a preference.

Run each command with `DEVELOPER_DIR=<Xcode>.app/Contents/Developer`. Never
switch `xcode-select` or change the user's global toolchain in any other way.
Record the path, version, build, and the reason it won. A newer SDK does not
raise any deployment target. If the developer's open Xcode window belongs to a
different installation, report both and ask before mixing them.

Distribution is the exception. App Store Connect accepts builds from a beta
Xcode only for TestFlight testing, and only for betas it has announced. An
archive or upload that may be submitted to the App Store must use an installed
release Xcode or an announced release-candidate Xcode. If none is installed, or
eligibility is unclear, stop and let the user choose.

For discovery commands, pins, tie-breaks, eligibility sources, and binding the
Xcode MCP bridge, see [Xcode selection](references/xcode-selection.md).

## XcodeGen gate

- Detect whether XcodeGen is the declared source of truth, but do not regenerate
  merely because source files changed or a generated project looks stale.
- XcodeGen enumerates globbed files at generation time. When an approved
  generation accompanies adding or deleting globbed resources (snapshot
  baselines, fixtures), make the file change first and generate after it;
  deleting a file that the generated project still lists fails the build with
  "Build input file cannot be found".
- Before adding a project-referenced file, determine whether the existing
  container already discovers it through a synchronized group or whether the
  XcodeGen spec and regeneration are required. Do not create an orphan source
  file or edit generated project metadata as a shortcut.
- Do not run generation while the current Xcode session is open unless the user
  explicitly requests it.
- If a new file requires regeneration, stop before that file/project mutation.
  Propose the spec change and controlled transition: obtain explicit approval,
  close the current Xcode session, update the spec at the authoritative root,
  generate once, then verify the same intended container in a new session. If
  that transition is not approved or Xcode remains open, report a blocker.
- If the generated container is absent after a fresh clone, explain the blocker
  and obtain permission for a new session/generation at the authoritative root.
- Before permitted generation, record the spec diff and expected project diff,
  run once at that root, then verify the same intended container opens.

This policy overrides any execution adapter that suggests automatic generation.

## Apple official-first routing

For the selected Xcode version, use one Apple-authored skill exposure and
Xcode's official tools when available: inside Xcode its built-in skills, outside
it one export that `apple-platform-setup` made with approval, never both, as
[Apple skill exposure](../apple-platform-setup/references/apple-skill-exposure.md)
describes. `xcrun agent` is `mcpbridge run-agent`: never run it here to find or
export skills. When the agent has no Apple skill, use Documentation Search and
Xcode's tools. Use Apple's supported external-agent bridge for an outside agent.
Third-party build tooling is an explicit fallback, not a prerequisite.

## Stop conditions

Stop without edits/builds when the root/container is unknown, the working tree
has pre-existing changes whose explicitly approved handling is absent (for a
local-only [small change](../agent-harness/references/small-change-path.md)
edited in place, only changes to its file), the remote default or intended base
of a branch the task creates is unresolved,
the Apple account boundary is unverified for an account action, Git metadata is
not writable from the current environment, a user-named or project-pinned Xcode
is not installed, or XcodeGen requires new authority.

References:

- [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
- [Extending and customizing agents](https://developer.apple.com/documentation/xcode/extending-and-customizing-agents)
