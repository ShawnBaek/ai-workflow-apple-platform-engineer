# TravelCrumb Figma golden comparison

This proof uses the requested Figma node:

- Frame: `TC_AddItem_Expense_Detail`
- URL: <https://www.figma.com/design/6vbnqI4BVkNA52jqJNSNjh/travelcrumb_Design-System---USE-THIS-?node-id=419-31291&m=dev>
- Node: `419:31291`
- Frame size: `375 × 812`
- Source: `TravelCrumbs/Timeline/View/TimelineItemAddView.swift` (`TimelineItemAddView`)

## Attachments

- [Figma export](figma.png)
- [Development capture](actual.png)
- [Side-by-side](side-by-side.png)
- [50% overlay](overlay.png)
- [Difference heatmap](diff.png)
- [Raw pixel metrics](metrics.json)
- [Figma visible-text inventory](figma-visible-text.json)
- [Semantic text results](text-results.json)
- [Sanitized Figma tree summary](figma-tree-summary.json)

## Execution result

The Swift Testing capture suite rendered one test successfully on an iPhone 17
Pro simulator running iOS 27.0 (build `24A5423a`). The result bundle was
`/tmp/figma-golden-active-snapshot.xcresult`. The capture assertion checked the
375×812 output, non-empty pixels, and the deterministic English/light fixture.

The run used this focused command from the TravelCrumb test worktree:

```sh
xcodebuild test -project Travelcrumb.xcodeproj -scheme TravelCrumb \
  -destination 'platform=iOS Simulator,id=2292BF53-B0F9-48FE-9209-D9A89F904F2A' \
  -disableAutomaticPackageResolution \
  -only-testing:TravelcrumbTests/TimelineExpenseFigmaCaptureTests \
  CODE_SIGNING_ALLOWED=NO \
  -resultBundlePath /tmp/figma-golden-active-snapshot.xcresult
```

The Figma comparison is **FAIL**. The comparator used identical 375×812 inputs,
no scaling, cropping, or masking, and a max RGB delta threshold of `16`:

```text
❌ Figma pixel comparison failed
Figma node: 419:31291 (TC_AddItem_Expense_Detail)
Source: TimelineItemAddView
Expected: 375×812 Figma export
Actual: 375×812 simulator capture
Threshold: max RGB delta ≤ 16
matchingPixels: 5,222 / 304,500
matchPercentage: 1.7149%
meanMaxRGBDelta: 44.5564
maxRGBDelta: 221
Mismatched fields: time, expense, currency, category labels, note, Items/share
```

The largest semantic gaps are the time (`9:30 AM` → `8:00 PM`), currency
(`USD` → empty), expense value (`$0` → `₩0`), category labels, note value, and
the missing Items/share content. The address and date match after whitespace
normalization. The mismatch is therefore a real route/fixture parity issue,
not a missing screenshot artifact; keep the test running and repair the owning
view or fixture before accepting a baseline.
