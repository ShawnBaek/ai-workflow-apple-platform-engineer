# ASC build-route check

Date: 2026-09-06. Installed CLI observed: `asc 2.2.0`, commit `44521f0`.
The [lane guide](../../skills/app-store-connect/references/build-and-release-lanes.md)
was checked against local nested command help and its linked primary sources.

- `xcode archive` requires one workspace/project, scheme and archive path.
- `xcode export` requires an export plist and IPA path in this version. An upload
  destination invokes external upload and returns no local IPA; `--wait` observes
  discovery/processing. The first review found this wait route missing; it was
  added, rather than directing a caller without a build ID to `builds wait`.
- `xcode-cloud build-runs builds --run-id` exposes the produced-build relationship.
  Apple's request schema identifies the Cloud pull-request input as an ASC SCM
  resource, not a GitHub PR number.
- `publish appstore` accepts local source or IPA, not an existing `--build` in
  2.2.0. The existing-build route uses staging as needed, then review submission.

A source-review walkthrough used a successful Cloud check with no verified build
association, missing ASC credentials and an already authorized PR request. Its
proposed actions continued PR delivery and held shipping for guarded source/run/
build verification; it did not infer artifact eligibility or demand a new local
archive from the missing distribution identity alone.

These are command-discovery, source-review and proposed-action observations.
No ASC account was queried, archive built, Cloud job triggered, artifact uploaded
or version submitted. Live release integration remains unverified. Newer CLI
versions require their own nested-help check; no update/install was performed.
