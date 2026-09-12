# Branch policy

Repository policy and an explicit user instruction take precedence over this
default. Before editing, verify the exact repository path, credential-redacted
remote, and current branch; identify the current remote default branch and
create the approved feature branch from it.

When the repository has no naming rule, use:

```
codex/<type>/<slug>
```

Allowed default types are `feat`, `fix`, `chore`, `docs`, and `release`. An
optional issue reference may appear in the slug, for example
`codex/fix/123-simulator-timeout`. Convert slashes, spaces, and other
path-unsafe characters in the requested name to hyphens; keep the resulting
slug concise and descriptive.

Release branches follow the repository's release policy when one exists. Do
not invent a release branch convention or replace a repository-defined naming
scheme with this default.
