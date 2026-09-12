---
name: apple-platform-setup
description: >-
  Guide first-run setup and upgrades for Apple Platform Engineer. Inventory the
  selected client's skills, Xcode/Swift, GitHub CLI, ASC and optional integrations;
  carry authorized installation/configuration through verification. Use after
  installing this collection or when dependencies are missing. Route read-only
  readiness to apple-development-health and app defects to their owning skill.
---

# Apple Platform Setup

Turn an installed collection into a usable development environment. This skill
guides the current agent; it is not another permanent agent, background installer
or prerequisite for every small task. `apple-development-health` observes readiness
without repair; setup coordinates authorized changes through the existing owners.

## Select the setup from the user's task

Reuse the current client, app repository, minimum OS, chosen Xcode, delivery target
and prior approvals. Ask only for material missing choices. Offer a compact default:
local app work, PR delivery with `gh`, or a selected Apple release lane with `asc`.
A documentation-only task need not install Xcode; a Simulator task need not connect
an Apple release account. Optional tools become required only when selected work
uses them. Read [the dependency matrix](references/dependencies.md).

For an explicit read-only readiness request, use `apple-development-health` when
its prerequisites exist, or report bounded local observations if they do not.
Do not build, boot, install or configure during a no-change inspection. Report
“prerequisites observed” separately from a successfully executed build.

Resolve installed skill paths, installation method and client scope. Record
observable provenance: a bundle commit/receipt or per-skill source/hash; mark an
unavailable repository revision unknown. A selective copy need not contain a
commit ID. Check local edits, duplicates, broken links and active consumers.
Installing skills does not install tools or configure accounts. If a selected
specialist is missing, use the known matching snapshot; if it cannot be recovered,
stage the selected dependent skills together from one reviewed source snapshot,
preserving scope and rollback. Do not silently mix current upstream with an
unidentified old copy. Missing provenance does not block inventory or preparation.

## Inventory, then perform authorized setup

1. Inspect the selected tools using local lookup/version/help and the app's actual
   manifests. Record paths and versions, not only names. Detect missing, incompatible
   and shadowed tools separately. Use current primary installation documentation;
   do not copy upstream-main flags into a different installed CLI version.
2. Make the missing changes concrete: tool/version/source, installation or client
   config destination, account boundary when applicable, verification command and
   rollback. Continue within existing authorization. If an additional gate is
   required, group known missing choices into one concise request after preparing
   the changes; do not ask again for settled facts or separately for every command.
   Continue independent authorized setup while answers are pending: an unknown
   GitHub account does not prevent installing `gh`. Select compatible Xcode from
   project requirements; ask about versions or physical-device signing only when
   the selected work needs that decision.
3. Use the user's existing package manager or official installer. Homebrew and
   Node/npm are needed only when the selected installation method uses them.
   Do not run a blanket upgrade, install a second client, replace custom skill
   links, download every Simulator runtime, or install another overlapping skill
   pack merely because it is available. Follow the matching specialist for
   Xcode/MCP, GitHub, ASC, Figma and secret-provider configuration.
4. Confirm GitHub identity/destination under project policy before account-dependent
   calls. Before changing signing, resolve the Apple account, exact team and
   membership type. Keep keys/passwords/OTP and private harness data out of chat,
   shell arguments and public reports; use approved local secret storage.
   Authentication and configuration do not grant push, upload, distribution or
   submission authority.
5. Verify each changed layer and resume the selected task. A missing capability
   blocks only dependent work; do not label it “skill locked.” Use Swift for new
   custom checks, and supported `git`, `gh`, `asc` and Apple CLI commands directly.

## Bootstrap coordinated work only when selected

First-run inventory and preparation must work before a private harness exists.
Do not require a passing harness health report in order to discover its missing
runtime. For coordinated work, use the installed harness's
[Swift setup](../agent-harness/references/swift-verification.md) and
[private coordinator setup](../agent-harness/references/coordinator-setup.md):
resolve a tested matching executable or build once, verify `--help` and
`runtime-identity`, and read the existing coordinator before any new bootstrap.
Retain the exact executable path/configuration and observed source hashes.

Create the private harness and fresh run authorization/ledger only for the selected
app and actions. Use `--app-root` for an external app. An existing coordinator or
runtime mismatch is an explicit migration path, not permission to create a parallel
empty registry. Do not insert a new graph, daemon or app architecture layer for setup.

## Verify and hand off

For each selected integration distinguish **installed**, **configured**,
**authenticated** when needed, **exposed in this task**, and **verified by a real
capability call**. Report unselected items as `not_applicable`; keep an unanswered
OS/provider prompt or required client reload explicit. CLI help alone does not
prove account access, and a configured MCP entry does not prove task connectivity.

Use one bounded, harmless call for the required capability. Do not create a PR,
upload a build, start a release, or change signing merely to test credentials.
For a harness-backed delivery profile, run matching `apple-development-health`
after its prerequisites exist. For lightweight setup, direct capability checks
are sufficient; do not bootstrap a harness just to obtain a health report.
Then hand the accepted task to `apple-platform-engineer` or its focused specialist.
Perform the smallest authorized representative task; if none was requested,
report verified setup capabilities without claiming an app was built or tested.

Keep a compact private setup note: selected scope, resolved paths/versions,
changes performed, observations, remaining action and resume command. Reuse this
on the next task, revalidating only changed or expired facts. Do not turn setup
into a repeated interview or publish machine/account inventories.

## Update an existing installation

Read the installed [update procedure](references/updating.md) for the actual
installation method before choosing an updater or activation command.
Preserve the original installation scope, local customizations and rollback copy.
Stage and validate a complete new bundle first. Before activation or runtime
rebinding, account for active consumers and leases; zero leases alone does not
mean tasks no longer read the shared skill manifest. Leave active/historical
authorizations untouched. New work gets fresh bindings and health observations;
new hashes do not renew old grants. Refresh client discovery, verify the active
paths and a relevant capability, then resume. Staged, activated, connected and
task-verified are separate outcomes.

An active consumer is a dependency, not a new permission requirement. Continue
independent setup and report activation pending quiescence. Do not ask for
permission to wait or suggest cancelling another task as the default remedy.
Migrate coordinator state only when an observed contract/schema mismatch needs it.
