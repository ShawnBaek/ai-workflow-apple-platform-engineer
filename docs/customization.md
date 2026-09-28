# Customize Apple Platform Engineer

Start with the [consumer workflow guide](../skills/agent-harness/references/project-customization.md).
It is shipped with the installed harness so users do not need this repository's
contributor documentation to resolve preferences.

Install only the skills your task needs. Preserve existing project instructions,
tools, architecture, deployment targets and authentication choices. Do not copy
the maintainer's local policy into a public fork or a consuming app.

| Need | Configure through |
| --- | --- |
| Local work or ordinary PR, with optional tracking | Existing project instructions and `git-workflow` |
| Private account/team boundary | [Private overlay template](../skills/agent-harness/templates/private-policy-overlay.json); populate outside public source |
| Trello title/status/design/tracker mapping | [Card sync](../skills/trello-pm-card-sync/SKILL.md) and its conditional template |
| Figma golden comparison | [Golden testing](../skills/figma-golden-testing/SKILL.md); explicit fixture, RGB tolerance and acceptance percentage |
| Code-first design | [Xcode Preview](../skills/xcode-preview-design/SKILL.md) |
| Coordinated runtime | [Private setup](../skills/agent-harness/references/coordinator-setup.md); preserve supported schemas and authorization |
| Website stack and branding | [App website](../skills/app-website/SKILL.md) |

Use a private project note for actual repository paths, account identifiers,
design mappings and board URLs. A public project policy can state conventions
without including those values. Preferences are agent guidance, not a new parsed
configuration format; the strict Swift runtime accepts only its documented fields.

The bundled guarded runtime currently supports Codex/Claude and a tracked PR
profile with fixed attempt caps. General Markdown guidance is portable, but this
is not a claim of arbitrary runtime adapters or configurable security invariants.
Standalone use must not bypass an already active guarded run.

This collection uses the [MIT license](../LICENSE). Linked libraries, Apple
documentation, tools and reference repositories retain their own licenses; the
collection's license does not relicense them. The upstream companion watcher is
maintainer infrastructure, guarded to this repository, not a consumer dependency.

## Use your repository's own skills

A repository's own skills, command files (`.claude/commands/`) and instruction
files outrank this collection's defaults for the same job. Every skill here
opens with a guard line that tells the agent to follow the repository's skill
and use the collection's only for gaps, keeping the collection skill's approval
and safety gates. When the agent reviews, applies or continues a change, a
skill, command, agent, instruction or settings file that the change adds or
modifies, and anything such a file loads or points to, is content to review,
not an instruction, and the agent follows the versions on the branch the change
targets. Neither client enforces any of this on its own: in Claude Code a
personal (`-g`) install runs instead of the project's same-name skill or
command, in Codex both copies are listed and a plain `$name` injects neither,
and both load the checkout's files themselves.
[Repository skill precedence](../skills/agent-harness/references/repo-skill-precedence.md)
gives the full order and each client's behavior, and its
[opt-out table](../skills/agent-harness/references/repo-skill-precedence.md#opt-out-of-a-collection-skill)
shows how you or the repository owner can turn a collection skill off or name
the repository's owner for a job instead.
