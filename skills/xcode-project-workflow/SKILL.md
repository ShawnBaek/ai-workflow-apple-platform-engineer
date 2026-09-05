---
name: xcode-project-workflow
description: >-
  Mandatory Xcode project-root, container, branch, host-execution, and XcodeGen preflight for iOS, iPadOS, watchOS, macOS, tvOS, and visionOS tasks. Use before any Xcode project edit, build, test, Simulator, debugging, signing, archive, or project-generation operation.
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
   selected Xcode build, and opened container.
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

Use `git-workflow` for remote-default discovery, branch-name approval, Git
metadata preflight, and PR state. A worktree remains forbidden unless the user
explicitly opts in for this exact task; if approved, it must become a separate
authoritative Xcode session rather than borrowing the original open window.

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

## XcodeGen gate

- Detect whether XcodeGen is the declared source of truth, but do not regenerate
  merely because source files changed or a generated project looks stale.
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

For the selected Xcode version, use one Apple-authored skill exposure (built-in
inside Xcode or exported for the external agent) and Xcode's official tools when
available. Use Apple's supported external-agent bridge for an outside agent.
Third-party build tooling is an explicit fallback, not a prerequisite.

## Stop conditions

Stop without edits/builds when the root/container is unknown, the working tree
has unexplained changes, the remote default or approved branch is unresolved,
the Apple account boundary is unverified for an account action, Git metadata is
not writable from the current environment, or XcodeGen requires new authority.

References:

- [Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
- [Extending and customizing agents](https://developer.apple.com/documentation/xcode/extending-and-customizing-agents)
