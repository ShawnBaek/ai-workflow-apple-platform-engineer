# Select the Xcode for a task

This reference extends `xcode-project-workflow`. Wherever another skill says
"selected Xcode", it means the installation chosen here. Resolve it once per
task, before the first Xcode, `xcrun`, `swift`, Simulator, or Xcode MCP
operation. Resolve again only when the user's choice, the project pin, or the
installed set changes.

## Discover installed full Xcodes

These reads do not launch Xcode:

```sh
mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'"
find /Applications "$HOME/Applications" -maxdepth 1 -name 'Xcode*.app' 2>/dev/null
```

Merge both lists by real path. Spotlight also finds copies that are not
installations, such as an expanded download in `~/Downloads`, a mounted volume,
or a backup. List them in the report, but select one only when the user names
it. If Spotlight is off or finds nothing, the `find` output is the inventory.

For each candidate `X`:

```sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  -c 'Print :ProductBuildVersion' "$X/Contents/version.plist"
DEVELOPER_DIR="$X/Contents/Developer" /usr/bin/xcrun --find xcodebuild
```

A candidate counts as a full Xcode only when both reads succeed and
`xcodebuild` resolves inside `$X/Contents/Developer`. Command Line Tools
(`/Library/Developer/CommandLineTools`) are never a candidate.

## Choose by precedence

1. **User choice.** Use an Xcode path or version that the user names for this
   task, or one that the private project or user policy sets. If it is not
   installed, stop and say so. Never download or install Xcode without separate
   approval.
2. **Project pin.** Use only what the authoritative repository actually contains:
   - `.xcode-version` in the directory of the project or workspace. It holds one
     version string such as `26.4` or `27.0b3`, following the
     [XcodesOrg convention](https://github.com/XcodesOrg/xcodes/blob/main/XCODE_VERSION.md)
     that fastlane's [`xcodes` action](https://docs.fastlane.tools/actions/xcodes/)
     reads by default. Match it exactly, so a beta pin needs that beta.
     `version.plist` has no beta number, so match a beta pin by looking up the
     candidate's `ProductBuildVersion` on
     [Apple Developer releases](https://developer.apple.com/news/releases/).
     If that lookup fails, ask.
   - An Xcode requirement in the repository's own documentation, or a CI
     workflow or project script that sets `DEVELOPER_DIR` or picks an Xcode path
     or version. A minimum such as "Xcode 26.4 or later" only narrows the
     candidates, and the newest one left wins. A CI-only path such as
     `/Applications/Xcode_26.4.app` pins the version, not the local path. A
     path without a version, such as `/Applications/Xcode.app` or
     `/Applications/Xcode-beta.app`, or a CI variable whose value you cannot
     resolve, is not a pin.
   - Compatibility-floor lane: a CI job that the repository's own documentation
     names as a compatibility-floor lane keeps proving the oldest Xcode the
     project supports. Its versioned path is a minimum, not a pin: it narrows
     the candidates to that version or later, like "Xcode 26.4 or later" above.
     The exception covers only the jobs the documentation names; any other
     versioned CI path is still a pin.
   - These are not pins: `swift-tools-version`; the project's `objectVersion`,
     `LastUpgradeCheck`, or compatibility version; Xcode Cloud workflow
     settings, which govern only that cloud lane; and the Mac's current
     `xcode-select -p`.

   If the pinned Xcode is not installed, report a blocker and do not substitute
   another one silently. When a user choice overrides a pin, record the
   override.
3. **Newest installed.** Otherwise pick the highest `CFBundleShortVersionString`,
   beta included. Compare the version numerically, one component at a time:
   `27.10` beats `27.2`, and `27.0.1` beats `27`. A beta and the release of the
   same version report the same version string, so break a tie by release
   status, not by raw build number:
   - Look up each `ProductBuildVersion` on
     [Apple Developer releases](https://developer.apple.com/news/releases/)
     and prefer the build Apple listed later. For one version, that means the
     release over a release candidate over a beta.
   - Compare build numbers only between builds of the same status, such as two
     betas: major number, then train letter, then build number, then suffix.
     Across statuses the numbers mislead, because beta builds carry higher
     numbers than the release. Xcode 16 beta 6 (`16A5230g`) and Xcode 16
     (`16A242d`) both report `16.0`, and the release is the newer one.
   - If you cannot establish the status of both builds, report both and ask
     which to use.

   If the same build is installed in several places, prefer the copy in
   `/Applications`.

Neither the bundle name nor the version string says whether an Xcode is a beta.
On 2026-09-26, Apple listed Xcode 27.1 (27A9269) as a beta even when it was
installed as `Xcode.app`. See [Apple Developer releases](https://developer.apple.com/news/releases/)
and the [Xcode 27.1 beta release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes).
When release status matters, for example for a version tie, distribution, or a
documented workaround, look up the exact build in Apple's release notes.

## Apply it per command

```sh
XCODE=/Applications/Xcode-beta.app   # the selected installation
DEVELOPER_DIR="$XCODE/Contents/Developer" xcodebuild -version
DEVELOPER_DIR="$XCODE/Contents/Developer" xcrun swift --version
```

`DEVELOPER_DIR` overrides the system-wide active developer directory (see
`man xcode-select`, ENVIRONMENT). The `/usr/bin` tool shims, `xcrun`, and
`xcode-select -p` all honor it. With the variable set, `xcode-select -p` prints
its value. Never run `xcode-select --switch` or `--reset`, edit shell profiles,
or change the user's global toolchain in any other way. Xcode has no `xcrun` of
its own, so the environment variable is the selection mechanism.

Keep one selection for every build, test, archive, Preview, Simulator runtime,
and MCP operation in the task. Changing it partway through is a toolchain
change: record it again and recheck any release-note workarounds.

The selection changes the SDK and compiler, not the app's support range. Keep
every deployment target and package platform minimum unchanged, as described in
[API availability](api-availability.md).

`apple-verify health` checks the toolchain with `xcode-select -p` and
`xcrun --find xcodebuild` in the environment it inherits. Launch it with the
same `DEVELOPER_DIR` so that it checks the selected Xcode rather than the global
one. Its `mcp.xcode` check also runs `xcrun mcpbridge` in that environment and
only looks for `xcrun` and `mcpbridge` in the client's registration. A pass
therefore does not prove that the registration itself sets `DEVELOPER_DIR`.
Check the registration as the provider preflight below describes. The check
reads the registration with each client's `mcp get` in the directory where you
launch it, so launch it from the repository root to see a project registration.
Its own `xcrun mcpbridge` run starts a bridge, and so does Claude Code's
`mcp get` health check of an approved server; Xcode alerts about each one.

The developer's authoritative window may run in a different installation. To
check, list running copies with `ps -axo pid=,comm= | grep '/Contents/MacOS/Xcode$'`.
If it does, report both installations and ask which to use before you combine
CLI results with that window's Previews, MCP tools, or run destinations.

## Record

In the intake record and in reports, record:

- the selected path, `CFBundleShortVersionString`, and `ProductBuildVersion`;
- Apple's release status for that build when you checked it, with the source;
- the reason it won: `user`, `pin:<file>`, or `newest`;
- the other candidates you considered; and
- `xcode-select -p`, when it differs from the selection.

## Distribution exception

App Store Connect announces upload eligibility for each Xcode release in its
[Help release notes](https://developer.apple.com/help/app-store-connect/release-notes/).
The following was checked on 2026-09-26:

| Xcode | Announced eligibility | Example |
| --- | --- | --- |
| Beta | TestFlight internal and external testing only, for the SDKs it names | Xcode 27.2 beta (Sep 16, 2026): all six platform SDKs. Xcode 27.1 beta (Sep 18, 2026): iOS and iPadOS 27.1 beta SDKs only |
| Release candidate | The App Store, plus TestFlight internal and external testing | Xcode 27 RC (Sep 9, 2026). Exceptions happen: Apple barred App Store submission of builds made with Xcode 16 RC because of a crash-on-launch issue |
| Release | The App Store, plus TestFlight | Xcode 27 (27A266a), Sep 14, 2026 |

- An archive, export, or upload that may be submitted to the App Store must use
  an installed Xcode that App Store Connect announced "for the App Store" for
  that platform. Use the newest such Xcode, unless a user choice or pin selects
  another eligible one. This rule also covers a TestFlight build that may be
  submitted later. Development work keeps the default selection; only the
  archive, export, and upload commands use this Xcode. Record both selections.
- The announcement is not enough on its own. The Xcode and SDK must also meet
  the current upload minimum in
  [Submitting to the App Store](https://developer.apple.com/app-store/submitting/).
  An older release that a user choice or pin selects can fall below it; treat
  that as ineligible.
- Use a beta only for an upload that the user asked to keep TestFlight-only, and
  only for a platform SDK that its announcement names. Tell the user that the
  build cannot go to App Review.
- For an existing archive or IPA, read `DTXcodeBuild` and `DTSDKBuild` from the
  app's `Info.plist` before you upload or submit it. An Xcode Cloud build uses
  the Xcode version set in its workflow, not the local selection, and the same
  eligibility rules apply to it.
- If no installed Xcode is eligible, or you cannot find the announcement for the
  exact version and platform, stop and ask the user to choose: install a
  released Xcode, accept TestFlight-only, or stop. Never resolve this by
  downloading or installing Xcode or by switching the global selection.

## Xcode MCP bridge

By default, `xcrun mcpbridge` connects to the Xcode that `xcode-select` selects.
A registration that does not set the Xcode can therefore answer from an older,
hidden Xcode while the developer works in a newer window. Bind the bridge to
the selected Xcode through `DEVELOPER_DIR`, never `MCP_XCODE_PID`, and verify it
with the
[provider preflight](../../xcodebuild/references/xcode-mcp-provider-preflight.md#bind-the-bridge-to-the-selected-xcode).
If you cannot bind it, report the bridge as unbound. A committed project
registration names no Xcode; each person binds it as
[per-project registration](../../xcodebuild/references/xcode-mcp-project-setup.md)
describes.
