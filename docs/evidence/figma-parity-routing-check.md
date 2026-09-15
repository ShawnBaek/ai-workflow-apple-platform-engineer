# Figma parity routing and verification check

Author replay of the instruction change against three synthetic requests. This
is a reading-based decision replay by the change author, not a fresh-agent run;
no app, Figma file, or Simulator was exercised for this record. The originating
report is a consuming-app session whose details stay private; the requests
below are rewritten with synthetic names.

| Request (synthetic) | Before this change | After this change | Expected by rubric |
|---|---|---|---|
| "Here is Figma node `12:34` for the edit screen. Make the SwiftUI view match it and add snapshot tests." | `figma-bridge` step 4 → `simulator-parity.md`; the snapshot part had no owner in `figma-bridge` or `apple-platform-testing`, so the agent selected `apple-platform-testing` and hand-rolled capture. | `figma-bridge` step 4, the lead routing table, `apple-platform-ui`'s Figma paragraph and `apple-platform-testing`'s intro all name `figma-golden-testing` for the snapshot/parity part. | `figma-golden-testing` for capture and comparison; `figma-bridge` remains the implementation entry. |
| Nearest confusing case: "Add snapshot tests for `SettingsView`" (no design source in the request or repository). | `apple-platform-testing`. | `apple-platform-testing` (the new sentence is conditioned on a Figma node being the contract). | Unchanged: `apple-platform-testing`; SnapshotTesting per project convention. |
| "The design shows a gear icon; the catalog already has `ic_settings`." | `generate-from-frame.md` table and the `apple-platform-ui` handoff list instructed SF Symbol substitution for `icon/...` layers; nothing required checking the existing asset's artwork. | New "Assets: exported artwork, not catalog names" section: add the Figma export, or render and compare an existing asset before reuse; SF Symbols only for system glyphs. | Use the exported asset; no substitution by name. |

Coupled non-routing guidance added in the same change and why:

- `figma-golden-testing` step 3 and its Swift Testing reference: `layer.render(in:)` blanks UIKit-bridged SwiftUI controls and `ImageRenderer` needs an explicit frame. Cause of a misdiagnosed "missing picker" in the report.
- `figma-golden-testing` step 4 and Report: identical dimensions must come from the source (same point size or same content node), not from stretching; verify color/size/position/hit area numerically. Cause of the report's ~82 % plateau being re-cropped repeatedly and of two black elements passing a visual glance.
- `generate-from-frame.md` step 4: measure node bounds first; small glyph → ≥44 pt frame via insets, then compensate spacing so the glyph stays on the Figma coordinate.
- `apple-platform-testing` XCTest reference: `xcodebuild test` does not forward shell-exported environment; baseline-directory gates skipped silently.
- `xcode-project-workflow` XcodeGen gate: delete/add globbed resources before an approved generation, not after.

Not covered by this record: a fresh lightweight agent selecting the route from
the raw request, a real Figma export vs. Simulator comparison, and a
fresh-installation replay. Those remain planned in the
[workflow test plan](../workflow-test-plan.md).
