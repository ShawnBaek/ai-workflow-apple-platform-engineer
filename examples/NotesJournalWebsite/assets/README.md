# assets/

This folder is intentionally empty in the repo. Drop your real assets here before running the site.

## Required files

| File | What | Size guidance |
|------|------|---------------|
| `hero-iphone.png` | iPhone-framed hero screenshot | 640 × 1380 (2x), ≤ 400 KB |
| `feature-1-write.png` | Feature 1 screenshot, iPhone-framed | 640 × 1380 (2x), ≤ 200 KB |
| `feature-2-quiet.png` | Feature 2 screenshot, iPhone-framed | 640 × 1380 (2x), ≤ 200 KB |
| `feature-3-everywhere.png` | Feature 3 screenshot, iPhone-framed | 640 × 1380 (2x), ≤ 200 KB |
| `parallax-timeline.png` | Parallax showcase image | 2400 × 1500 (2x), ≤ 400 KB |
| `app-store-badge.svg` | Apple's official App Store badge | from https://tools.applemediaservices.com/app-store/ |
| `og.png` | Open Graph share image | 1200 × 630, ≤ 200 KB |

## Total budget

≤ 1.5 MB across all images. The agent enforces this — if you blow the budget, Lighthouse will tank.

## Where to get iPhone bezel PNGs

Apple's official device frames live at https://developer.apple.com/design/resources/ in the "Product Marketing" section. Composite your screenshots inside the bezel in GIMP or Photopea, export as PNG with transparent background (or matching background color).

## 3D models (optional — for the parallax showcase)

If you want a spinnable iPhone / iPad / MacBook / Apple Watch in the parallax section instead of a flat PNG, drop the model files here:

| File | Size guidance | Source |
|------|---------------|--------|
| `iphone.glb` | 1–3 MB | [Sketchfab](https://sketchfab.com/tags/iphone) or [3DModels.org](https://3dmodels.org/3d-models/apple-iphone-15-green/) |
| `iphone.usdz` | 1–3 MB | [archive.org Apple AR Products](https://archive.org/details/21-10-24-ar-products) — enables iOS AR Quick Look |
| `iphone-poster.webp` | 30–80 KB | render of the model, shown during load |
| `ipad.glb` / `ipad.usdz` | 1–3 MB / 1–3 MB | same sources |
| `macbook.glb` / `macbook.usdz` | 2–5 MB / 2–5 MB | same sources |
| `watch.glb` / `watch.usdz` | 0.5–1.5 MB | same sources |

Then uncomment the 3D variant block in [`../sections/ParallaxShowcase.js`](../sections/ParallaxShowcase.js).

**Conversion note:** if you only have USDZ but need GLB for web rendering, use Apple's [usdzconvert](https://developer.apple.com/download/all/?q=USDZ%20Tools) CLI.

## How screenshots get here

Use the [`screenshot`](../../../plugins/screenshot/README.md) agent in this marketplace — it captures, frames, and (if you ask) uploads. Then copy the framed PNGs from its output directory into this folder.

## Don't commit binaries to the agent-design repo

These are placeholder docs. In your actual website repo, you'd commit the real PNG/SVG files here.
