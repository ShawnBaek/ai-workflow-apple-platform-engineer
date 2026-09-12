# Choose the build and release lane

Resolve the requested outcome and existing source/build evidence before creating
another archive. Record `asc --version` and inspect the selected command's nested
`--help`. The examples below were checked against **asc 2.2.0**; upstream main may
describe commands or optional flags absent from that installation. In particular,
do not assume `asc xcode build` exists or that export options can be omitted.
CLI help is local discovery; authenticated reads still need the private account
guard. Missing credentials stop account access, not source inspection or PR work.

## Route by the input already available

| Input / requested outcome | Route and evidence |
|---|---|
| Local source → archive or IPA | `asc xcode archive`, then `asc xcode export` if an IPA is needed; or host `xcodebuild archive` / `-exportArchive`. Use the authorized container, scheme, toolchain and signing policy. Record source and artifact identity. |
| Existing IPA/PKG → uploaded build | `asc builds upload` with the exact app/artifact and supported wait options. Verify the resulting build ID and processing state. Upload is not distribution or submission. |
| Xcode Cloud build | Inspect `asc xcode-cloud workflows`, `build-runs` and `status` within the account guard. Trigger `asc xcode-cloud run` only when authorized, with the exact workflow and source reference. Resolve produced ASC build IDs through `asc xcode-cloud build-runs builds --run-id …`. |
| Existing processed ASC build → App Store version | Inspect the version's existing build association first. If staging is needed, `asc release stage` can apply approved metadata, attach the exact build and validate. It mutates version/metadata/build association; use its dry run and applicable grants. A prepared version can go to `asc review submit` under separate submission authorization. |
| Local source/IPA → combined App Store flow | `asc publish appstore` composes local build or upload plus version/build attachment; inspect `--dry-run`. Adding `--submit --confirm` also submits for review. In 2.2.0 this command does not accept an existing `--build`; use the preceding lane for a cloud-produced build. |
| Existing processed build → TestFlight | `asc publish testflight --build …` can skip upload. Resolve exact group IDs and the distinct distribution/notification/beta-review actions before acting. |

Prefer the existing compatible artifact/build over another build when its commit,
app, platform, version/build and processing/eligibility state match. A passing
GitHub Xcode Cloud check proves only that check; inspect the run's build
relationship before claiming it produced an uploadable/submittable artifact.
No local distribution identity does not by itself rule out an existing cloud
build. Do not invent eligibility or switch accounts to get past missing access.

## Local archive/export example

Run from the authoritative app checkout after its Xcode and signing gates. Use
task-owned output paths and the approved export plist; do not overwrite another
task's archive or add `--clean` / provisioning-update flags by default.

```sh
asc xcode archive --workspace '<App.xcworkspace>' --scheme '<Scheme>' \
  --configuration Release --archive-path '<task-output>/App.xcarchive'
asc xcode export --archive-path '<task-output>/App.xcarchive' \
  --export-options '<approved-ExportOptions.plist>' \
  --ipa-path '<task-output>/App.ipa'
```

Use exactly one of `--workspace` or `--project`. In 2.2.0, export requires both
`--export-options` and `--ipa-path`. Inspect the plist first: `destination=upload`
causes **an external upload** through `xcodebuild -exportArchive`, and no local IPA
is produced at that path. A command under `asc xcode` is not necessarily local
only. Export destination, signing/provisioning flags and composed publish steps
determine which approvals it needs. Local export is not App Review submission.

## Cloud source and PR handoff

GitHub PR creation belongs to `git-workflow` and the app checkout's confirmed
remote/base. `asc xcode-cloud run` consumes a source reference; it does not create
the GitHub PR or select its destination. Its `--pull-request-id` is an **ASC SCM
Pull Requests resource ID**, not an assumed GitHub PR number. Resolve that resource,
repository and head commit before use; alternatively use the supported exact
branch/Git-reference relationship. Reuse an existing matching run when suitable.

Ordinary PR validation must not silently trigger release operations. An authorized
release job uses the selected CLI version, reviewed commit, scoped credentials,
exact build/run IDs and action-specific grants. A combined command inherits every
mutation it performs; a dry run is preparation, not authorization or completion.

## Wait for the requested state

- Direct-upload export: use `asc xcode export --wait` when the next step needs
  discovery and processing of that uploaded build; record its returned identity
  and state. Do not substitute `asc builds wait` until an exact build ID is known.
- Upload processing: `asc builds wait` for the returned build ID.
- Cloud run: `asc xcode-cloud status --run-id … --wait`, with a bounded timeout.
- App Review lifecycle: `asc submit status --version-id …` in 2.2.0;
  `asc submit` itself offers status/cancel, not the submission entry point.

Use the installed help for exact flags. Preserve source/run/build/version IDs and
the observed state; build success, processing success, internal distribution and
App Review submission are separate outcomes. Record missing access or async work
precisely and continue independent authorized PR delivery.

Sources: [ASC command reference](https://github.com/rorkai/App-Store-Connect-CLI#commands-and-reference),
[upstream release lanes](https://github.com/rorkai/app-store-connect-cli-skills/blob/main/skills/asc-release-flow/SKILL.md),
[Apple distribution workflow](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases),
[Apple Xcode Cloud build runs](https://developer.apple.com/documentation/appstoreconnectapi/build-runs),
[Apple's SCM pull-request relationship](https://developer.apple.com/documentation/appstoreconnectapi/cibuildruncreaterequest/data-data.dictionary/relationships-data.dictionary/pullrequest-data.dictionary).
