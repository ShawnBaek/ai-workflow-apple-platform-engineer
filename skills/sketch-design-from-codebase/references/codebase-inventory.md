# Inventory the codebase before drawing

Read this once per project. The goal is a written inventory the screen scripts
consume, so that no label, color, size or asset is invented.

## 1. Screen inventory per platform

Search each target's view folder and list top-level screens, the shell that
presents them, and every reachable sub-state:

| Look for | Yields |
| --- | --- |
| `TabView` / `AppTabView` | tab order and labels (iPhone); `.sidebarAdaptable` → sidebar on iPad |
| `NavigationStack` + `.navigationTitle` / `.navigationBarTitleDisplayMode` | large-title vs inline toolbar per screen |
| `NavigationSplitView` | iPad two-column screens and their empty detail state (`ContentUnavailableView`) |
| `HSplitView`, `List(...).listStyle(.sidebar)` | macOS sidebar sections and list+detail panes |
| `TabView(...).tabViewStyle(.verticalPage)` | watchOS page order |
| `.sheet`, `.popover`, `.confirmationDialog`, `.alert` | modal screens; note title and Cancel/Done placements |
| `NavigationLink { ... }` inside a `List` | child pickers (companies, region, sort, status) |
| `Form` / `.formStyle(.grouped)`, `GroupBox`, `List(...).listStyle(.plain)` | grouped vs plain list presentation |
| `ContentUnavailableView(...)` | empty and unauthenticated states with their exact copy |

Record, per screen: platform, frame name (`NN Screen`), shell, toolbar kind
(large / title / sheet / none), trailing actions, tab index, and the
components it renders. Reused views (a detail view shared by iOS and macOS)
count once per platform frame that shows them.

## 2. Tokens

- Theme type: font sizes and weights (`navTitle 34/bold`, `cardTitle
  17/semibold` …), spacing and corner radii.
- Asset catalog colors: parse every `*.colorset/Contents.json`; the
  `appearances` entry with `luminosity: dark` gives the dark value. Emit a
  table of name → light hex, dark hex.
- Hard-coded colors in platform-specific targets (for example a watch target
  using `Color(hex:)`): list them separately; they are part of the current
  system too.
- Add the current tokens to the Sketch document as swatches named by their
  source (`Theme/Primary`) so a designer can trace them. For redesign, add the
  new system's tokens beside them (`<Reference>/Gray/100`).

## 3. Labels, prices, formats and content

- Enum raw values for filters, statuses and segments (`RoleFilter`,
  `CountryFilter`, `SortByFilter`, status strings) — these are the exact chip
  and row labels.
- StoreKit configuration (`*.storekit`): product display names, prices,
  periods.
- Formatter output shapes (salary, dates): read the formatter; when the shape
  depends on stored data, take the string from a real capture and say it is
  data-dependent.
- Sample content: prefer real captures in the repository (`docs/**/*.png`,
  snapshot tests under `__Snapshots__/`) and the developer's screenshots over
  invented data. Keep private identifiers (emails, record IDs) out of the file
  unless the developer supplies them for their own file.

## 4. Assets

- Logos and illustrations: `Assets.xcassets/**/*.imageset/*.{png,svg,pdf}`.
  Rasterize to a fixed point height (`rasterize-logos.swift <out> 3 24 files…`);
  NSImage reads SVG, so no extra tools are needed.
- App icon and marketing art only when a screen shows them.
- SF Symbols used by the views (`Image(systemName:)`): collect the names and
  the sizes/weights/colors they appear in; render them with
  `render-sf-symbols.swift`. Render white and black variants for anything that
  sits on a black or white control.

## 5. Sizes and ground truth

- Device points = capture pixels ÷ scale. Verify with `sips -g pixelWidth -g
  pixelHeight`. Typical current values: iPhone 402×874 @3×, iPad 11" landscape
  1210×834 @2×, macOS window 1312×912 @2×, Apple Watch 49 mm 205×251 @2×.
- For reproduction, capture the running build:

  ```sh
  xcrun simctl list devices booted
  xcrun simctl install <udid> <path/to/App.app> && xcrun simctl launch <udid> <bundle-id>
  xcrun simctl io <udid> screenshot <out.png>
  ```

  Drive navigation with the Xcode device-interaction tools or the app's UI
  tests. Data-backed screens need signed-in or seeded state; when the
  Simulator shows an empty state, use repository captures for those screens and
  label the difference.
- Keep captures and rendered assets in the session scratch directory, not in
  the app repository, unless the developer wants them versioned.
