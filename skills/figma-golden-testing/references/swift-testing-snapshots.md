# Swift Testing snapshot guide

Use this reference when the app's UI is written in SwiftUI or UIKit and the
Figma frame is the visual contract. The test is responsible for rendering a
known state and comparing it with a reviewed baseline. The separate comparator
then compares that captured PNG with the Figma export so the Figma source is
never silently replaced by a runtime screenshot.

## Add the dependency to the test target

Add Point-Free's package to the test target only:

```swift
// Package.swift
dependencies: [
  .package(
    url: "https://github.com/pointfreeco/swift-snapshot-testing",
    from: "1.19.0"
  )
]

// In the test target's dependencies:
.product(name: "SnapshotTesting", package: "swift-snapshot-testing")
```

The exact version should follow the app's existing dependency policy. Do not
add a second snapshot framework when the project already has one.

## Write a Swift Testing test

The current Point-Free API works from a Swift Testing suite. Keep the fixture
deterministic and use a fixed layout equal to the Figma frame. Replace the view
and fixture names with the real route under test:

```swift
import SnapshotTesting
import SwiftUI
import Testing

@MainActor
@Suite("Figma golden screens")
struct AddItemFigmaSnapshotTests {
  @Test("renders the reviewed Add Item state")
  func rendersAddItem() {
    let view = ExampleItemView(viewModel: .figmaExpenseFixture)
      .environment(\.locale, Locale(identifier: "en_US"))
      .preferredColorScheme(.light)

    assertSnapshot(
      of: view,
      as: .image(
        layout: .fixed(width: 375, height: 812),
        traits: .init(displayScale: 1)
      ),
      named: "Example_Item_Detail"
    )
  }
}
```

Use this strategy as written for SwiftUI. Do not substitute a hand-rolled
`UIGraphicsImageRenderer` + `view.layer.render(in:)` capture even when a
neighboring UIKit test already uses one: it renders UIKit-bridged SwiftUI
controls such as `Picker(.segmented)` blank, and `ImageRenderer(content:)`
yields a zero-size image unless the content carries an explicit `.frame`.
`displayScale: 1` keeps the capture at the Figma frame's 1x pixel dimensions.
The first run records the baseline and fails with "No reference was found";
that is the expected recording path, not a regression.

For a UIKit controller, snapshot the controller with the same explicit device
configuration or snapshot its view at a fixed size:

```swift
@MainActor
@Suite("UIKit Figma golden screens")
struct ItemEditSnapshotTests {
  @Test func rendersItemEdit() {
    let controller = ItemEditViewController(fixture: .figmaExpense)

    assertSnapshot(
      of: controller,
      as: .image(
        size: CGSize(width: 375, height: 812),
        traits: .init(displayScale: 1)
      ),
      named: "Example_Item_Detail"
    )
  }
}
```

The fixture must set every visible value that appears in the Figma frame,
including date, time, place, address, price, currency, note, and selected tab.
It must also fix locale, calendar, time zone, color scheme, dynamic type,
network responses, permission state, and status-bar treatment. A screenshot of
the wrong route or empty state is a valid capture but a failed parity result.

## Baselines and recording policy

The first run may write a baseline and fail with a message containing the new
file path. Do not accept that file automatically: compare it with the Figma PNG
and review the overlay first. Keep `record` disabled in normal CI runs. Record
only an intentional, reviewed design change:

```swift
// One-time local update after reviewing the Figma diff.
assertSnapshot(
  of: view,
  as: .image(
    layout: .fixed(width: 375, height: 812),
    traits: .init(displayScale: 1)
  ),
  record: .all,
  named: "Example_Item_Detail"
)
```

If the package version supports suite recording, scope it to the affected
Swift Testing suite (`@Suite(.snapshots(record: .failed))`) rather than making
all tests record. Never use a newly recorded baseline as proof that the app
matches Figma.

## Run one test and inspect the result

Use the repository's existing project or workspace and a named simulator. Keep
the result bundle so the test attachments and failure diff remain reviewable:

```sh
xcodebuild test \
  -workspace App.xcworkspace \
  -scheme App \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -disableAutomaticPackageResolution \
  -only-testing:AppTests/AddItemFigmaSnapshotTests/rendersAddItem \
  CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath .build/figma/add-item.xcresult

xcrun xcresulttool get test-results summary \
  --path .build/figma/add-item.xcresult
```

Use `-project App.xcodeproj` instead of `-workspace` when that is the
authoritative project container. A successful test reports `TEST SUCCEEDED`,
the selected test count, and the result-bundle path. A mismatch reports the
snapshot name plus reference and failure-diff file URLs in Xcode's Report
Navigator/result bundle. A missing baseline reports that it was recorded and
fails intentionally; inspect it, then rerun with recording disabled.

When the Figma comparison fails, add a human-readable failure record alongside
the library's assertion output. Use this shape so a reviewer can see the cause
without opening an image first:

```text
❌ Figma pixel comparison failed
Figma node: 12:34 (Example_Item_Detail)
Source: ExampleItemView
Expected: 375×812 Figma export
Actual: 375×812 simulator capture
Threshold: max RGB delta ≤ 16
Matching pixels: 224,269 / 304,500 (73.6516%)
Mismatched fields:
  - time: expected "9:30 AM", actual "8:00 PM"
  - expense: expected "$0", actual "₩0"
  - currency: expected "USD", actual ""
  - note: expected "The best coffee place", actual "Add note"
Artifacts: report/side-by-side.png, report/overlay.png, report/diff.png,
           report/metrics.json, report/text-results.json
```

Do not turn a low percentage into a generic “snapshot failed” message. Include
the node, source symbol, dimensions, threshold, numerator/denominator,
percentage, and the first actionable text or geometry mismatches. If the Swift
Testing assertion itself fails, preserve its reference and failure-diff paths
in the same report.

Set `FIGMA_GOLDEN_ROOT` to the absolute installed folder of this loaded skill.
Extract or copy the actual PNG from the test attachment and compare it with the
Figma export:

```sh
swift "$FIGMA_GOLDEN_ROOT/scripts/overlay_diff.swift" \
  --figma evidence/figma.png \
  --actual evidence/actual.png \
  --out evidence/report \
  --threshold 16 --minimum-match 99
```

The command must finish with identical input dimensions and creates
`overlay.png`, `diff.png`, `side-by-side.png`, and `metrics.json`. The JSON's
`matchingPixels` and `matchPercentage` use the configured raw RGB threshold;
they are not perceptual similarity. Report the threshold, dimensions, exact
and threshold-matching percentages, and the maximum/mean RGB delta.

Choose the threshold and minimum percentage from the accepted project criteria;
16 and 99 above are examples. Exit 2 means pixel comparison failed and retains
the artifacts. Exit 1 means an input/tool error. Without `--minimum-match`, exit
0 only means the report was generated, with `status: not_evaluated`. The renderer
uses the explicit minimum and never invents a 99% acceptance criterion. Continue
rendering the failure report after exit 2; do not hide it behind a success-only
command chain. Semantic assertions remain separate from the pixel exit code.

To show the JSON results as images in a pull request, run the Swift report
renderer after the comparator:

```sh
swift "$FIGMA_GOLDEN_ROOT/scripts/render_report.swift" \
  --metrics evidence/report/metrics.json \
  --text evidence/report/text-results.json \
  --out evidence/report
```

It creates `metrics.svg` and `text-results.svg`. Embed those SVGs in the PR
alongside `overlay.png` and `diff.png`; keep the JSON files linked as the
machine-readable source.

## Validate visible text separately

Snapshot pixels do not prove that a label contains the correct string. Export
visible Figma `TEXT` nodes and compare them with accessibility identifiers or
the UI hierarchy. Keep semantic checks in the Swift test (or a companion JSON
comparison) so a wrong date/place cannot be hidden by a high pixel score:

```swift
@Test func visibleTextMatchesFigma() throws {
  let actual = try renderedAccessibilityText(for: .figmaExpense)

  #expect(actual["time"] == "12:30")
  #expect(actual["date"] == "SEP 11, 2025")
  #expect(actual["place"] == "Example Cafe")
  #expect(actual["address"] == "1 Example Street")
}
```

If a check fails, name the Figma node ID, expected string, actual string, and
source accessibility identifier in the report. Keep the test green only after
both the semantic checks and the image comparison have been reviewed.

## Result record

Record these independent outcomes in the PR or evidence directory:

| Check | Evidence | Meaning |
| --- | --- | --- |
| Swift Testing execution | `TEST SUCCEEDED` or failure output and `.xcresult` | The fixture rendered and the test ran |
| Snapshot baseline | reference comparison result | The implementation stayed stable against the reviewed code baseline |
| Figma pixel comparison | `metrics.json`, `overlay.png`, `diff.png`, `side-by-side.png` | Raw image agreement with the node export |
| Visible text | missing/extra/changed arrays | Date, time, place, buttons, and text views match semantically |

The failure message above is illustrative synthetic data, not an executed app
result. The checked-in collection proof uses synthetic images only. App testing
requires the consumer's real view, fixture, reviewed baseline and toolchain.

Reference: [Point-Free SnapshotTesting usage and recording behavior](https://github.com/pointfreeco/swift-snapshot-testing#usage).
