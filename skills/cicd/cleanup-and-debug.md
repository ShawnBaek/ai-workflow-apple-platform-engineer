# Runner storage audit and failure triage

## Audit before cleanup

For a long-lived Mac runner, record filesystem capacity and itemized sizes before
proposing any deletion. Use the `xcode-storage` skill to classify each target as:

- rebuildable: job-owned output that can be recreated;
- conditional: caches, DerivedData, DeviceSupport, or Simulator devices whose
  next-use cost must be stated;
- protected: archives, signing material the current job did not create,
  installed runtimes in use, user data, and any path with uncertain ownership.

Show the exact path/item, observed size, expected reclaim, owner/job, last-use
signal when available, and rebuild/redownload/reset impact. Ask for itemized
approval. Prefer Xcode Settings > Components for runtime management and
recoverable Trash operations for approved local folders.

Never place blanket user-library, Simulator, package-cache, archive, Homebrew,
keychain, profile, or runner-workspace deletion in an `if: always()` step. A job
may remove only an item it created, named exactly, and no longer needs: a
workspace-relative path, its own directory under `$RUNNER_TEMP`, or a
provisioning-profile file it installed, at the exact path it recorded.

Temporary signing material is the required case. A job that creates a
keychain, writes a key or certificate file, or installs a provisioning profile
must, in an `if: always()` step, delete exactly that keychain, those files and
the profile paths it recorded, and restore any keychain search list it changed,
as the [signed TestFlight upload](workflow-templates.md#signed-testflight-upload)
template does. Emptying `$RUNNER_TEMP` does not unregister a keychain or remove
a profile under `~/Library`, and a self-hosted runner can keep both after the
job. Never delete the login keychain, another job's keychain, key or profile, a
profile that was installed before the job, or anything selected by a pattern.

## Safe recurring policy

Use retention rather than sweeps:

- set artifact/log retention explicitly;
- expire old job-owned artifacts through GitHub settings;
- cap concurrency so duplicate builds do not accumulate;
- monitor free-space thresholds and pause new jobs before exhaustion;
- schedule a read-only size report, then review itemized cleanup separately.

An unavailable Simulator device is not the same as an installed runtime. Do not
erase devices or remove runtimes as a generic response to disk pressure.

## Evidence on failure

Upload only the relevant evidence, with a short retention period appropriate to
the project:

- build log with the first actionable diagnostic;
- `.xcresult` bundle for affected tests;
- package fingerprint and resolution log for dependency failures;
- screenshot/video for a UI acceptance failure;
- runner diagnostic excerpt when the runner itself failed.

Do not upload signing assets, profiles, private keys, environment dumps, or
unredacted home/session logs.

## Triage by layer

| Signal | Route |
|---|---|
| runner offline, disk pressure, permission, Xcode selection | runner/environment |
| package resolve/checkout/revision | `swift-package-manager` |
| project, scheme, compiler, linker, Simulator | `xcodebuild` |
| assertion, UI synchronization, xcresult | `apple-platform-testing` |
| signing, upload, TestFlight/App Store | `app-store-connect` |
| deterministic performance regression | `apple-platform-performance` |

Do not rerun unchanged deterministic failures. Retain the original failure,
change the relevant input or implementation, and create a new attempt.

References:

- [Self-hosted runner security](https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners)
- [Workflow artifacts](https://docs.github.com/en/actions/concepts/workflows-and-actions/workflow-artifacts)
