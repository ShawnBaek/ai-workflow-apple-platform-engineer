# Capture and verify the selected build

Use existing `xcode-project-workflow`, `xcodebuild` and `screenshot` procedures for
container selection, destination ownership and capture state. Do not boot another
device merely to make screenshots while a task already owns a suitable destination.

## Discover the actual command surface

For a Simulator lane, inspect selected-toolchain help first:

```sh
xcrun simctl help get_app_container
xcrun simctl help io
```

Use one resolved UDID, never an ambiguous `booted` destination in a concurrent run.
After a verified build/install/launch, supported commands include:

```sh
xcrun simctl get_app_container '<UDID>' '<bundle-id>' app
xcrun simctl io '<UDID>' screenshot '<new-raw.png>'
xcrun simctl io '<UDID>' recordVideo --codec=h264 '<new-raw.mov>'
```

Inspect the installed bundle's version/build and executable/resource provenance,
not merely the project settings. Wait for the recording-started signal before the
first relevant interaction. Stop its owning process with SIGINT and wait for its
exit so the file finalizes. Do not kill unrelated Simulator
processes or capture another app that happens to be foreground. Device and macOS
capture follow their supported Xcode/OS paths, not a Simulator command substitute.
The inspected `simctl` defaults to HEVC; select a supported source codec explicitly
and still check/derive the final preview's dimensions, frame rate and encoding.

Installed `asc 2.2.0` exposes local `screenshots capture/run` as experimental;
capture defaults to the `axe` provider and requires an installed app. It does not
prove freshness by itself. Use it only when selected and available, with exact
destination and independently established build identity. Do not install another
capture provider when Apple's tools already meet the task.

## Check media through Apple frameworks

Use ImageIO to decode the final image, check pixels and transparency, and create
PNG/JPEG exports without changing the raw file. With AVFoundation, inspect loaded
video tracks and their preferred transform, duration, codec/frame rate and audio;
extract frames with `AVAssetImageGenerator` and preserve the returned actual time.
Use an exact-time request when a specific frame is required, and record any time
deviation. Hash both source and derivatives with CryptoKit.

Trimming through `avconvert` is described by `screenshot`. Inspect the output
again: a container suffix or a requested export preset does not prove actual
dimensions, duration, encoding or Apple acceptance. Distinct preview and screenshot
slots can need distinct exports from their full-resolution source.

## ASC handoff, after authorization

Read installed nested help instead of guessing names or flags:

```sh
asc --version
asc screenshots validate --help
asc screenshots upload --help
asc video-previews upload --help
asc video-previews set-poster-frame --help
```

In inspected 2.2.0, the command is `video-previews`, not `app-previews`.
`screenshots validate` is a local format/size check and does not establish build
freshness or compliance with every current Apple rule. `video-previews upload`
uses an App Store **version-localization resource ID**, not the locale string.
Both `screenshots upload --replace` and `video-previews upload --replace` delete
the target set's existing assets: do not add either to a routine upload without
exact replacement authority. A remote dry run still needs
the applicable account/read scope. Do not claim a local video validation command
exists without checking help.

Keep screenshot order, locale and display type distinct from preview order and
poster timecode. Confirm the target version is editable; do not overwrite an
approved listing implicitly. After upload, list the exact stored set, observe
processing and verify the preview/poster in App Store Connect. For an uncertain
response, read back before retrying to avoid duplicates or unnecessary deletion.

Sources: [ASC CLI](https://github.com/rorkai/App-Store-Connect-CLI),
[Apple upload workflow](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots/),
[poster frames](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-preview-poster-frame/),
[build association](https://developer.apple.com/help/app-store-connect/manage-builds/choose-a-build-to-submit).
