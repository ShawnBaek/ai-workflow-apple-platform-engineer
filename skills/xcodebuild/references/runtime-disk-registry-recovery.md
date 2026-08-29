# CoreSimulator runtime-disk registry stall

Use this when Xcode or `simctl` blocks while discovering runtimes, before a
specific Simulator destination or app is involved. A repeated diagnostic such
as `unable to get a dev_t for store <store-id>`, a long pause at one runtime
boundary, or repeated registration of many runtime images indicates a suspected
global registry/disk-layer failure. It does not prove that an app, device, or
particular runtime is corrupt.

## Stop amplification and establish ownership

Stop starting new Simulator, MCP, Device Hub, or `simctl` requests. Preserve
successful build evidence and mark runtime-dependent verification blocked; do
not change application source to work around a device-independent failure.

Inventory the Simulator-capable tool providers attached to every open task,
including Xcode's official integration and any third-party adapter. During
diagnosis, select exactly one provider for all Simulator operations and record
its name/version. Prefer the official Xcode route when it exposes the required
operation. Gracefully cancel or idle the other providers; closing another task,
disabling its integration, or terminating its process still needs the user's
approval. Processes that appeared after the first registry error may amplify
the queue, but their presence alone does not establish the original cause.

Inventory every active Xcode run on the Mac, quiesce its outstanding Simulator
calls, and acquire one host-wide `coresimulator_runtime_registry` lease. Derive
its key from `host_id + registry_scope`, where `registry_scope` covers the
system and logged-in user's shared CoreSimulator runtime registry. Do not key it
by Xcode build: stable and beta Xcode installations can encounter the same
host-level runtime/component state. Other projects may keep reading source or
using preserved build results, but no second owner may enumerate, install,
remove, mount, unmount, or repair runtimes concurrently.

The only approval-free registry lease is an acquire whose allowed actions are
exactly `read_only_diagnosis`. Before any other registry action, append a
single-use approved `destructive_action` record. Bind its approval ID, host
resource key, one action, and one exact runtime identifier to the later acquire;
the lease repeats those fields as `approval_id`, its sole `allowed_actions`
entry, and `mutation_target`. A rejection with that approval ID cancels it, and
an approved ID cannot authorize a second acquire or a different runtime.

Run at most one bounded read-only discovery call at a time. If a call visibly
re-registers the installed catalog or repeats the same error, let it reach its
deadline, record the last progress point, cancel that request, and do not launch
parallel replacements. More queued processes can amplify the stall without
being its original cause.

For failure grouping, preserve the raw store identifier in private evidence but
normalize only its numeric value to `<store-id>`. Two existing observations of
the normalized signature meet the repeat threshold; do not launch a second probe
solely to manufacture repetition. A 30-second-or-longer gap between runtime
records is supporting timing evidence, not a universal timeout or causal proof.

## Why a restart can appear to fix the issue and still recur

A normal Mac restart clears the current `launchd_sim`, CoreSimulator, and
`simdiskimaged` process state. It does not by itself remove installed runtime
components, resolve duplicate or stale runtime registration, or prevent open
tasks from starting multiple Simulator-capable providers again. Treat a reboot
as a recovery boundary, never as proof that the persistent trigger was fixed.

Low free storage can increase image-mount, cache, and runtime-registration
pressure. Record free bytes and the run's configured storage floor, then route
capacity work to the [Xcode storage audit](../../xcode-storage/SKILL.md). Do not
name low storage as the sole cause without controlled evidence, and do not turn
a registry incident into an automatic cache or runtime cleanup.

## Build a timestamped diagnosis

Record a compact, privacy-reviewed timeline and distinguish these states:

- **alive but stalled:** `simdiskimaged` retains the same process identity and
  start time across the observation window while identical registry errors or
  no-progress intervals continue;
- **restart/crash loop:** process identities or start times repeatedly change,
  with exits or launches in the logs;
- **device-local:** discovery succeeds and only one exact UDID fails;
- **runtime-specific:** discovery reproducibly pauses or fails at one exact
  platform/version/build while unrelated runtimes remain usable;
- **registry-wide:** Device Hub, runtime/device inventory, and project-neutral
  Simulator requests block before destination selection.

Order events by their first timestamp. If the first registry error predates
later hung Simulator or MCP processes, classify those later processes as
downstream or amplifying evidence unless another cause is shown.

From the authorized host environment, capture:

1. macOS build, each active Xcode path/build, and the selected developer
   directory for every affected run;
2. the first and most recent normalized error, operation, timeout, process
   identity/start time, and numeric store identifier;
3. one bounded runtime-discovery trace with elapsed time between runtime
   records;
4. free storage and filesystem-capacity evidence, kept separate from registry
   correctness;
5. a runtime table with platform, OS version, exact build, image kind, state or
   signature state when exposed, store/image identifier, mount path, owning
   Xcode/component, dependent run IDs, and observed delay.

Before a restart or component change, preserve the smallest useful Apple
diagnostic bundle while the failure is still observable:

- run one bounded `xcrun simctl diagnose` only when the service can still
  complete it; if it hangs, cancel it at the recorded deadline and do not retry;
- collect `sudo spindump simdiskimaged` only for a narrow live-hang investigation
  after the user approves the privileged collection and its output location;
- prefer Feedback Assistant's requested profile for a full sysdiagnose. A raw
  `sudo sysdiagnose` is privileged, large, and privacy-sensitive, so it requires
  explicit approval, a destination/retention plan, and review before sharing.

Never request or handle a password to run an elevated diagnostic. If collection
would prolong an unusable machine or risks losing unrelated work, record the
omission and proceed to the approved recovery boundary.

A loopback local LLM may cluster already-redacted repeated diagnostics and
runtime entities. It may not receive raw diagnostic archives, infer deletion
authority, decide causality, acquire the lease, or invoke recovery actions.

Map `<store-id>` to a runtime only when the same diagnostic or registry evidence
explicitly binds them. A numeric store identifier is never a deletion target by
itself. Read-only mount information may identify a leftover candidate, but it
is not permission to unmount it.

Several runtimes with the same marketing OS version but different builds, or a
mix of a conventional runtime volume and a `Patchable Cryptex Disk Image`, are
diagnostic candidates rather than proof of corruption. Likewise, a large
runtime count is context, not a cause. Strengthen the hypothesis only when the
exact build/image transition consistently aligns with the no-progress interval
or error and the selected Xcode no longer needs the superseded candidate.

Apple's Xcode 26.4 release notes document issue `172343027`, where a
`simdiskimaged` jetsam loop could make `simctl` or `xcodebuild -runFirstLaunch`
hang and could prevent runtime installation. That is useful precedent for a
runtime-disk-layer failure class, not proof that an alive-but-stalled process is
the same defect. Check the release notes for the exact selected Xcode build at
diagnosis time. Not finding the symptom in the currently reviewed notes does
not prove either that it is unknown or that a beta regression caused it.

## Evidence-first recovery ladder

Perform only the first applicable step, then rerun one bounded discovery probe.
Every step that closes another project, restarts the Mac, or removes a component
needs explicit approval for that exact scope.

1. Preserve the timeline and stop all affected run queues. After all owners
   agree, quit the affected Simulator/Device Hub and Xcode applications normally,
   reopen the same Xcode build and authoritative container, and run one probe.
2. If the global registry remains blocked, a normal Mac restart may be proposed
   after every Xcode/Simulator lease is quiesced and the user approves it. Do not
   substitute process killing or a service-reset loop. After login, do not
   restore all tool providers at once: start the selected Xcode and the single
   recorded Simulator provider, then perform the bounded inventory first.
3. If one exact stale or superseded runtime is strongly implicated, route the
   action through the [Xcode storage audit](../../xcode-storage/SKILL.md). Show
   its platform/version/build/image kind, size, dependent devices/projects,
   replacement source and cost, and rollback/re-download plan. Obtain approval
   for that one runtime.
4. Prefer Xcode Settings > Components for the approved runtime. An Apple CLI
   removal route is allowed only when the installed toolchain's current help
   explicitly supports exact runtime deletion, the approved runtime identifier
   maps to the displayed platform/version/build/image, and no required device or
   project depends on it. Present exact candidate and retained builds rather
   than broad labels such as “old beta,” and preserve the runtime required by
   the selected Xcode and active projects. Remove one approved item at a time,
   then inventory again. Never extrapolate one approval into “delete all unused
   runtimes.” If neither supported route can distinguish the exact build, stop
   instead of deleting filesystem state. Reinstall only the exact compatible
   runtime, one at a time, if it is still required.
5. If the runtime cannot be mapped confidently, the supported component UI is
   also blocked, or recovery would require altering protected registry internals,
   stop and file Feedback Assistant evidence. Apple provides `simctl Diagnose`
   and Xcode Sysdiagnose instructions in its Profiles and Logs collection.

Do not disable SIP, grant broad disk access merely to delete state, remove
CoreSimulator Images/Cryptex/Volumes registry files by hand, force-unmount a
runtime, erase every device, delete every runtime, kill `simdiskimaged` or
CoreSimulator services, wipe DerivedData, or reinstall Xcode as a first-line
repair. Do not copy destructive forum commands into an automated agent run.

## Verify recovery and transfer the lease

Recovery is not proved by a process restart alone. Record that:

- exactly one Simulator-capable provider is active for the test;
- one runtime inventory through the intended Xcode returns within
  its recorded budget without the repeated `dev_t` diagnostic; derive the
  budget from the project's healthy baseline or an accepted criterion rather
  than treating a sample such as 10 seconds as universal;
- the intended exact runtime/component is registered as expected and any
  remaining same-version builds are explained;
- the former runtime boundary no longer causes repeated registration or the
  observed long pause; and
- the host-wide registry lease is explicitly released before any
  `simulator_or_device` lease is acquired.

After the release is recorded, acquire one exact control UDID lease and boot it.
Then perform one install → launch → screenshot path on that destination without
rebuilding. One pass is the default minimum.
Require three consecutive passes only when intermittent recurrence or
stability is an explicit acceptance criterion; keep provider, Xcode build,
runtime build, UDID, app
artifact, and timeouts unchanged and do not insert cleanup between passes. After
infrastructure proof, return to each project's own smallest critical interaction
flow. Never substitute another project's flow as general acceptance evidence.
Reclassify every affected project independently. If failure returns before
destination selection, release the device lease before starting a new
registry-diagnosis attempt; never hold both lease classes together.

If the stall recurs, a stable-versus-beta comparison is valid only when both
toolchains are compatible with the project. Test sequentially, with one provider
and one toolchain active per approved clean-start boundary. Keep source SHA,
scheme, configuration, architecture, app behavior, and measurement method fixed;
record unavoidable runtime differences as confounders. A beta-only result raises
the regression hypothesis but does not prove it. Submit the versioned timeline,
diagnostics, inventory, and controlled comparison through Feedback Assistant.

If several things changed together, report recovery without claiming a unique
root cause. Attribute the cause to a stale/mixed runtime candidate only when a
single controlled change plus before/after evidence supports it.

References:

- [Apple: Downloading and installing additional Xcode components](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
- [Apple: Running your app on simulated or physical devices](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
- [Apple Feedback Assistant: Profiles and Logs](https://developer.apple.com/feedback-assistant/profiles-and-logs/)
- [Apple Developer Forums: Xcode and `simdiskimaged` hang diagnostic discussion](https://developer.apple.com/forums/thread/756767)
- [Apple: Xcode 26.4 release notes, issue 172343027](https://developer.apple.com/documentation/xcode-release-notes/xcode-26_4-release-notes)
- [Apple: Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
