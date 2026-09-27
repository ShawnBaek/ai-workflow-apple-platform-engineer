# Choose the build and release lane

Resolve the requested outcome and existing source/build evidence before creating
another archive. Record `asc --version` and inspect the selected command's nested
`--help`. The examples below were checked on 2026-09-27 against **asc 5.6.0**
(released 2026-09-25). `asc` changes quickly, even between 5.x releases, so the
installed help wins over this page; [version differences](#version-differences)
lists the mismatches most likely on an older installation.
CLI help is local discovery; authenticated reads still need the private account
guard. Missing credentials stop account access, not source inspection or PR work.

## Route by the input already available

| Input / requested outcome | Route and evidence |
|---|---|
| Local source → archive or IPA | `asc xcode archive`, then `asc xcode export` if an IPA is needed; or host `xcodebuild archive` / `-exportArchive`. Use the authorized container, scheme, toolchain and signing policy. Record source and artifact identity. |
| Existing IPA/PKG → uploaded build | `asc builds upload` with the exact app/artifact and supported wait options. Verify the resulting build ID and processing state. Upload is not distribution or submission. |
| Xcode Cloud build | Inspect `asc xcode-cloud workflows`, `build-runs` and `status` within the account guard. Trigger `asc xcode-cloud run` only when authorized, with the exact workflow and source reference. Resolve produced ASC build IDs through `asc xcode-cloud build-runs builds --run-id …`. |
| Existing processed ASC build → App Store version | Inspect the version's existing build association first. If staging is needed, `asc release stage` can apply approved metadata, attach the exact build and validate. It mutates version/metadata/build association; use its dry run and applicable grants. A prepared version can go to `asc review submit` under separate submission authorization. |
| Local source/IPA → combined App Store flow | `asc publish appstore` composes local build or upload plus version/build attachment; inspect `--dry-run`. Adding `--submit --confirm` also submits for review, so run `asc validate` first. It has no existing-build flag; use the preceding lane for a cloud-produced or already processed build. |
| Existing processed build → TestFlight | `asc publish testflight --build-id …` distributes an existing build and skips upload; `--build-number` looks one up instead. Resolve exact group IDs and the distinct distribution/notification/beta-review actions before acting. |

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
Choose the Xcode by the
[distribution exception](../../xcode-project-workflow/references/xcode-selection.md#distribution-exception).
A beta Xcode is limited to TestFlight-only uploads. Set that Xcode's
`DEVELOPER_DIR` on each command, and check `DTXcodeBuild` in the archived app's
`Info.plist` before you upload. Apply the same check to an existing IPA/PKG.

```sh
asc xcode archive --workspace '<App.xcworkspace>' --scheme '<Scheme>' \
  --configuration Release --archive-path '<task-output>/App.xcarchive'
asc xcode export --archive-path '<task-output>/App.xcarchive' \
  --export-options '<approved-ExportOptions.plist>' \
  --ipa-path '<task-output>/App.ipa'
```

Use exactly one of `--workspace` or `--project`. Pass the reviewed
`--export-options` plist explicitly. When it is omitted, `asc` generates options
(method `app-store-connect`, automatic signing), and with `--wait` those
generated options upload directly. Inspect the plist first: `destination=upload`
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
In GitHub Actions, handle the API key, signing certificate and provisioning
profile as in `cicd`'s
[signed TestFlight upload](../../cicd/workflow-templates.md#signed-testflight-upload).

## Wait for the requested state

- Direct-upload export: use `asc xcode export --wait` when the next step needs
  discovery and processing of that uploaded build; record its returned identity
  and state. Do not substitute `asc builds wait` until an exact build ID is known.
- Upload processing: `asc builds wait` for the returned build ID.
- Cloud run: `asc xcode-cloud status --run-id … --wait`, with a bounded timeout.
- App Review lifecycle: `asc submit status --version-id …`; `asc submit` offers
  only status and cancel. `asc validate` is the readiness preflight (an account
  read). Submission itself goes through `asc review submit` for a prepared
  version or `asc publish appstore --submit --confirm`, each under its own
  submission authorization.

Use the installed help for exact flags. Preserve source/run/build/version IDs and
the observed state; build success, processing success, internal distribution and
App Review submission are separate outcomes. Record missing access or async work
precisely and continue independent authorized PR delivery.

## Version differences

| Surface | asc 2.2.0 (2026-06-20) | asc 5.6.0 (2026-09-25) |
|---|---|---|
| Existing build ID → TestFlight | `publish testflight --build <ID>` | `--build-id <ID>` (`--build-number` lookup is unchanged) |
| `asc xcode export` | `--export-options` and `--ipa-path` required | options generated when omitted; `--wait` without a plist uploads directly |
| `asc xcode build` | absent | present |

Releases in between differ again. For example, 5.2.1 still marks `--ipa-path` as
required. A flag this page names that the installed help rejects is a version
mismatch: follow the installed help and record the version.

Sources: [ASC command reference](https://github.com/rorkai/App-Store-Connect-CLI#commands-and-reference),
[asc 5.6.0 release](https://github.com/rorkai/App-Store-Connect-CLI/releases/tag/5.6.0),
[upstream release lanes](https://github.com/rorkai/app-store-connect-cli-skills/blob/main/skills/asc-release-flow/SKILL.md),
[Apple distribution workflow](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases),
[Apple Xcode Cloud build runs](https://developer.apple.com/documentation/appstoreconnectapi/build-runs),
[Apple's SCM pull-request relationship](https://developer.apple.com/documentation/appstoreconnectapi/cibuildruncreaterequest/data-data.dictionary/relationships-data.dictionary/pullrequest-data.dictionary).
