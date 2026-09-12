# Project agent harness

Select standalone skills or the guarded `agent-harness` runtime for this project. Put this
project's authoritative checkout, Apple/GitHub account guards, branch policy,
and approval boundaries below. Private identifiers belong in a local overlay,
not in a reusable public skill.

## Project guards

- Authoritative repository: `<absolute-path>`
- Authoritative Xcode container: `<absolute-project-or-workspace-path>`
- Allowed GitHub owner: `<owner>`
- Allowed Apple team: `<private-overlay>`
- Branch policy and approval gates: `<project convention>`
- Workflow: `<standalone | guarded>`; tracking: `<none | Issues | configured board>`
- Design source: `<Figma node | supplied image | code-first Preview | not applicable>`
- Evidence: `<private output location and separately approved public artifacts>`

These are guidance preferences, not additional fields in the strict runtime JSON
schema. Resolve them from existing project instructions; do not commit populated
private paths, account guards, board IDs, or design mappings to public templates.

Use one repository writer at a time. Run Xcode and Simulator operations only in
the logged-in host environment. Do not auto-regenerate XcodeGen, create a
worktree, clean caches, publish, submit, merge, or broaden credentials without
the explicit approval required by this project.

For guarded execution, select a delivery target (`local_verified`, `pr_ready`, `testflight_uploaded`, or
`testflight_distributed`) and run the matching `apple-development-health`
profile. If the project enables Spec Kit, pin `v1.0.1`, bind its artifact
snapshot to the branch and run authorization, and keep its workflow log
subordinate to the append-only harness ledger.

One immutable run authorization may cover routine green-path Issue, commit,
push, PR, evidence, and exact TestFlight actions only when every target and
single-use grant matches and no stricter project/global gate applies. It never
authorizes merge, App Review, production release, signing-resource mutation,
credential expansion, or destructive cleanup.
