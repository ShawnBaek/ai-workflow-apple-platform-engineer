# Report schema

`metrics.json` should include:

```json
{
  "figma": {"url": "...", "fileKey": "...", "nodeId": "...", "frame": "..."},
  "source": {"path": "...", "symbol": "..."},
  "capture": {"device": "...", "os": "...", "width": 375, "height": 812},
  "comparison": {"threshold": 16, "matchingPixels": 0, "pixelCount": 0, "matchPercentage": 0},
  "text": {"missing": [], "extra": [], "changed": []},
  "artifacts": {"overlay": "overlay.png", "diff": "diff.png", "sideBySide": "side-by-side.png"}
}
```

Keep `text` results separate from pixel metrics. A frame with the wrong fixture
can have a low pixel score while still having correct geometry.

