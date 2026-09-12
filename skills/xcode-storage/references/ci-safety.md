# CI cleanup safety

CI cleanup is a retention and capacity decision, not a test repair technique.

- Measure runner disk pressure and identify the job, cache key, artifact retention policy, and exact directories owned by that job before changing cleanup.
- Prefer platform-managed cache/artifact retention, job-scoped temporary directories, and post-job removal of paths created by that same job.
- Preserve test results, `.xcresult` bundles, screenshots, videos, logs, and archives for the configured diagnostic/release retention window.
- Never add an unconditional deletion of user-level Derived Data, Simulator data, Swift package caches, archives, Homebrew data, or another runner's workspace.
- If a build requires more capacity, fail with the capacity evidence and escalate the retention/capacity decision. Do not silently trade diagnostic evidence for free space.
