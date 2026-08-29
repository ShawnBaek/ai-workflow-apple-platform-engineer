# Project agent harness

Load the installed `agent-harness` skill for broad or task-to-PR work. Put this
project's authoritative checkout, Apple/GitHub account guards, branch policy,
and approval boundaries below. Private identifiers belong in a local overlay,
not in a reusable public skill.

## Project guards

- Authoritative repository: `<absolute-path>`
- Authoritative Xcode container: `<absolute-project-or-workspace-path>`
- Allowed GitHub owner: `<owner>`
- Allowed Apple team: `<private-overlay>`
- Branch policy: `<prefix/type/slug>`

Use one repository writer at a time. Run Xcode and Simulator operations only in
the logged-in host environment. Do not auto-regenerate XcodeGen, create a
worktree, clean caches, publish, submit, merge, or broaden credentials without
the explicit approval required by this project.
