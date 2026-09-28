# Render previews through the Xcode MCP server

Apple's Xcode MCP server (`xcrun mcpbridge`) exposes a `RenderPreview` tool that
builds one `#Preview` or `PreviewProvider` in the open Xcode and returns a
snapshot. Claude Code and Codex call it the same way, through the server
registered as `xcode`. This page was checked against Xcode 27.2 beta
(27B5019j), server `xcode-tools` 25434.2. Tool names, parameters and outputs can
change between Xcode releases: use the schema in this session's tool list where
it differs from this page.

Use it when the person works in an open Xcode and you need a specific preview
rendered without driving their canvas: to render a preview matrix, to reproduce
and fix a render failure, or to attach a snapshot to a review. It is canvas
evidence only; see the [evidence ladder](../SKILL.md#evidence-ladder).

## Preconditions

1. **The server is connected to the right Xcode.** `RenderPreview` is in this
   session's tool list and the bridge answers from the Xcode that owns the
   person's window; see [bind the bridge to the selected Xcode](../../xcodebuild/references/xcode-mcp-provider-preflight.md#bind-the-bridge-to-the-selected-xcode),
   [Register the Xcode MCP server per project](../../xcodebuild/references/xcode-mcp-project-setup.md)
   and [Xcode selection](../../xcode-project-workflow/references/xcode-selection.md).
   Do not start another bridge to find out, and never run
   `xcrun mcpbridge run-agent`.
2. **The workspace is open there.** `XcodeListWorkspaces` lists it. Pass its
   identifier or absolute path as `workspaceIdentifier` on every call, as
   `open-xcode-handoff` does. If it is not open, ask the person; opening or
   closing a workspace changes their Xcode.
3. **Xcode sees the change.** `RenderPreview` renders the project as the open
   Xcode has it, not your checkout. `sourceFilePath` is the file's path in the
   Xcode project organization (for example `ProjectName/Sources/MyFile.swift`,
   as `XcodeGlob` or `XcodeLS` shows it), not a filesystem path.
   - **Same checkout.** When you edit files on disk behind the open Xcode, ask
     the person to save or close editors for those files first, as
     [`open-xcode-handoff`](../../open-xcode-handoff/SKILL.md#4-check-project-membership-before-applying)
     does before an apply. Apple does not document how Xcode reloads a file
     changed on disk, so an editor left open may not show your edit, and a
     render may not use it.
   - **Separate worktree, clone or sandbox.** Tell the person. Apply the change
     with [`open-xcode-handoff`](../../open-xcode-handoff/SKILL.md) only when
     they ask to see it in their Xcode; otherwise record the preview as not
     rendered, or render it after they apply the change.
4. **The person's selection stays.** Rendering uses the active scheme and a
   destination usually derived from the workspace's run destination;
   `renderedDestination` reports the one used, which can differ from it.
   Choose another destination with `preferredRenderDestination`; never call
   `XcodeSwitchScheme` or `XcodeSwitchRunDestination` to render. Ask the person
   when the active scheme does not build the preview's target.

## Render a preview matrix

1. Call `RenderPreview` with `sourceFilePath` and
   `previewDefinitionIndexInFile`, the zero-based position of the `#Preview` or
   `PreviewProvider` definition in the file, counted from the top (default 0).
   Each separate definition, including a dark or extra-large-text variant
   written as its own `#Preview`, is chosen by its index, not by an override.
   `timeout` defaults to 120 seconds; raise it only when the first preview build
   is known to take longer.
2. Read the result: `displayName` and `sourceLineNumber` identify the rendered
   preview; `renderedDestination`, `previewSnapshotPath` and `errors` describe
   the render; `availableRenderDestinations`, `supportedPreviewVariantOverrides`,
   `supportedLocalizations` and `supportedCanvasControlOverrides` list what a
   later call may request.
3. Render each remaining configuration of a definition with values that an
   earlier call returned, never guessed ones: `preferredRenderDestination`
   (prefer its `identifier`), `previewVariantOverrides` (variant group to
   variant), `previewLocalizationOverride`, and `previewCanvasControlOverrides`
   (`groupItemIndex` for a preview that varies over its `arguments:`,
   `timelineIndex` for a widget or Live Activity timeline, `toggleState`).
   Variant and canvas-control values hold only for the scheme and destination
   that returned them; read them again after changing
   `preferredRenderDestination`.
4. Check the configuration you got. Compare `renderedDestination` with the
   request: when no destination matches, the tool renders on the automatic one
   and adds a message to `errors`. That snapshot is not the requested
   configuration; do not record it as one.
5. Render one preview at a time per workspace. This is this page's rule; the
   schema itself forbids parallel calls only when `previewLocalizationOverride`
   is set.

## Record the evidence

`previewSnapshotPath` names an image that Xcode writes; screen areas that the
destination device does not show are transparent. Copy it into the task's
evidence location, record its SHA-256, and privacy-scan it like any canvas
capture. For an aligned comparison, composite it over a stated background
first. Record the Xcode version and build; the MCP server version when the
client shows it (otherwise the Xcode build identifies the server); the
workspace, `sourceFilePath`, definition index, `displayName`,
`sourceLineNumber`, `renderedDestination`, overrides, fixture, and source or
diff identity.

## When the render fails

1. Read `errors` first; each message includes its underlying errors.
2. For a compile problem, read `XcodeRefreshCodeIssuesInFile` for the preview's
   file, then `GetBuildLog` with `severity: error`. `GetBuildLog` returns the
   current or most recently finished build, which may not be this render's:
   trust it only when `buildIsRunning` is false and `buildResult` and its full
   log (`fullLogPath`) show a build that ran after your change, or run
   `BuildProject` for a current one. That build runs in the person's Xcode:
   hold the build lease when coordinated and do not start it while they are
   building, as
   [`open-xcode-handoff`](../../open-xcode-handoff/SKILL.md#6-verify-in-the-open-xcode-without-changing-its-selection)
   describes. Read its errors unfiltered first and narrow by `glob` to the
   preview's file only afterwards: the preview builds with the active scheme,
   so a failure elsewhere in that scheme can also block it.
3. Fix the cause in code or fixture, such as a live dependency reached from the
   preview, a missing environment value, a crashing fixture, or an unsupported
   destination. Do not delete, stub out, or narrow the preview to make it pass.
   Apply one focused correction and render again; repeated failure goes back to
   the [ten-lens review](preview-and-motion-contract.md#ten-review-lenses),
   not into a retry loop.
4. When the failure is the tool or environment rather than the code, such as a
   timeout on the first build or no usable destination, record it and use the
   canvas with the person (its error banner's Diagnostics button shows the
   preview diagnostics) or a build.

Without the server, render in the person's canvas and capture a labeled
screenshot. A Simulator run of the app is runtime evidence, not a preview
render; label each for what it is.
