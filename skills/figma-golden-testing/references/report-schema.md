# Report schema

`metrics.json` should include:

```json
{
  "figma": {"url": "...", "fileKey": "...", "nodeId": "...", "frame": "..."},
  "source": {"path": "...", "symbol": "..."},
  "execution": {"status": "passed", "test": "...", "resultBundle": "..."},
  "capture": {"device": "...", "os": "...", "width": 375, "height": 812},
  "comparison": {"status": "failed", "threshold": 16, "matchingPixels": 0, "pixelCount": 0, "matchPercentage": 0},
  "text": {"missing": [], "extra": [], "changed": []},
  "artifacts": {
    "overlay": "overlay.png",
    "diff": "diff.png",
    "sideBySide": "side-by-side.png",
    "metricsImage": "metrics.svg",
    "textResultsImage": "text-results.svg"
  }
}
```

Keep `text` results separate from pixel metrics. A frame with the wrong fixture
can have a low pixel score while still having correct geometry. Keep the
execution status separate from both: a test can pass while the Figma comparison
fails, as it did for the TravelCrumb evidence in this PR.
