# Discovery and permissions

Perform discovery before proposing a tracker mutation. Keep the output limited
to the intended personal account and repository or Project owner; do not scan
other accounts or organizations merely to find a usable Project.

## Read-only discovery

1. Inspect the active account and token scopes with `gh auth status`.
2. Inspect the intended repository with `gh repo view OWNER/REPO` and confirm
   Issues are enabled.
3. Check the installed CLI supports the command and flags that will be needed:
   `gh issue --help`, `gh project --help`, and `gh pr --help`.
4. For a known user or organization Project, list or view only that owner's
   Projects. Resolve its number, title, and identifier before any item change.
5. Read the Project's existing fields and options. Reuse its status field and
   option names rather than creating parallel fields.

Do not assume `repo` scope permits Projects v2 operations. Projects can require
`read:project` for discovery and `project` for changes, depending on token type,
owner, and visibility. Fine-grained tokens and GitHub Apps use different
permission models. Consult GitHub's current documentation for the active
credential type instead of guessing.

## Permission failure

Classify the failure before retrying:

| Signal | Action |
| --- | --- |
| Command absent or unsupported | Stop and use an approved supported interface; do not invent flags. |
| Missing scope/permission | Report the exact required capability and request approval before changing authentication. |
| Project owner differs from repository owner | Ask for the intended Project; do not select another one. |
| Network/transient API failure | Preserve completed operations and retry only the idempotent failed request if authorized. |
| Ruleset/protection restriction | Respect it; report the blocker instead of weakening it. |

Never run `gh auth refresh --scopes ...` automatically. Never use an
administrator credential or a different account as a workaround unless the user
explicitly authorizes that account and operation.

## References

- [GitHub: About Projects](https://docs.github.com/en/issues/planning-and-tracking-with-projects/learning-about-projects/about-projects)
- [GitHub: Managing Projects with the API](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-api-to-manage-projects)
- [GitHub CLI authentication](https://cli.github.com/manual/gh_auth_status)
