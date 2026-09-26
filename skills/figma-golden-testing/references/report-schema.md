# Report schema

An application report that wraps the comparator output should include:

```json
{
  "figma": {"url": "...", "fileKey": "...", "nodeId": "...", "frame": "..."},
  "source": {"path": "...", "symbol": "..."},
  "execution": {"status": "passed", "test": "...", "resultBundle": "..."},
  "capture": {"device": "...", "os": "...", "width": 375, "height": 812, "scale": 1},
  "comparison": {"status": "failed", "threshold": 16, "matchingPixels": 0, "pixelCount": 0, "matchPercentage": 0},
  "text": {"missing": [], "extra": [], "changed": [], "matches": []},
  "artifacts": {
    "overlay": "overlay.png",
    "diff": "diff.png",
    "sideBySide": "side-by-side.png",
    "textResults": "text-results.json",
    "metricsImage": "metrics.svg",
    "textResultsImage": "text-results.svg"
  }
}
```

Keep `text` results separate from pixel metrics. A frame with the wrong fixture
can have a low pixel score while still having correct geometry. Keep the
execution status separate from both: a test can pass while the Figma comparison
fails. The wrapper above is an application report, not the comparator's flat
`metrics.json` output. Preserve the original metrics and link it from the wrapper.
Pass the comparator's `metrics.json` to `render_report.swift --metrics` unchanged;
the renderer rejects a `matchPercentage` that disagrees with `matchingPixels` /
`pixelCount`, or a `status` that disagrees with `requiredMatchPercentage`.
The synthetic proof contains no app-runtime or live-design acceptance claim.

## `text-results.json`

Neither script produces this file. The agent writes it from the visible-text
check (SKILL.md step 5), and `render_report.swift --text` requires it. The
renderer exits 1 unless all four arrays exist (use `[]` when empty) and every
row carries its required string values:

| Array | Meaning | Required string keys per row |
| --- | --- | --- |
| `missing` | A Figma `TEXT` node with no visible app text | `field`, `figmaNodeId`, `expected` |
| `extra` | Visible app text with no Figma `TEXT` node | `field`, `figmaNodeId`, `actual` |
| `changed` | Both exist but the strings differ | `field`, `figmaNodeId`, `expected`, `actual` |
| `matches` | Both exist and the strings agree | `field`, `figmaNodeId`, `expected`, `actual` |

`field` is a short human label such as `time`. `figmaNodeId` is the `TEXT`
node ID; an `extra` row uses the containing frame or component node where the
text appears. Other keys, such as a top-level `provenance` or a per-row
`accessibilityIdentifier`, stay available to machine readers; the renderer
ignores them. Start from the [synthetic example](text-results.example.json)
and replace every value with the checked screen's results.
