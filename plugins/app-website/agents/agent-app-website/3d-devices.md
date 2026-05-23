# 3D Apple device showcases (`<model-viewer>` + USDZ/GLB)

For an Apple-platform marketing site, a 3D iPhone / iPad / MacBook / Apple Watch you can spin and zoom is more memorable than a flat PNG. Use it in **exactly one place** (the parallax showcase, Section 3) — the same restraint as the parallax rule.

**Tooling**: Google's [`<model-viewer>`](https://modelviewer.dev) web component. Drop in via a `<script type="module">` in `index.html`; works in every modern browser; supports both **GLB for the web** and **USDZ for iOS AR Quick Look** (tap-to-AR on iPhone visitors).

## Where to get the models

| Source | What's there | License | Format |
|---|---|---|---|
| **Internet Archive — Apple AR Products** ([archive.org/details/21-10-24-ar-products](https://archive.org/details/21-10-24-ar-products)) | **87 official Apple USDZ files**: MacBook 13/14/16 (silver + space gray), MacBook Air (all colors), Mac Mini, Mac Pro, iMac 24", Pro Display XDR, iPhone SE/12/13 (all colors + variants), iPad Pro 11/12.9, iPad Air, iPad 10.2, iPad Mini, Apple Watch S3/S7/SE, AirPods Gen 3/Pro/Max, Apple TV 4K, AirTag, HomePod Mini. **407 MB total** | Apple's originals, archived publicly | USDZ |
| **Apple AR Quick Look gallery** ([developer.apple.com/augmented-reality/quick-look](https://developer.apple.com/augmented-reality/quick-look/)) | Apple's current showcase models | Apple, demo use | USDZ |
| **Sketchfab** ([sketchfab.com/tags/iphone](https://sketchfab.com/tags/iphone), `/tags/macbook`, `/tags/ipad`, `/tags/apple-watch`) | Community GLBs, recent generations | Per-model (many CC; check before commercial use) | **GLB** (native web) |
| **3DModels.org** ([3dmodels.org/3d-models/apple-iphone-15-green](https://3dmodels.org/3d-models/apple-iphone-15-green/)) | Royalty-free iPhone 15, iPhone 13 with separated screen material | Royalty-free | GLB + glTF |

## Pick one path

- **iPhone visitor → AR Quick Look magic**: ship a `.usdz` from the Internet Archive, link via `<model-viewer ios-src>`. Tapping the AR badge opens AR Quick Look — the iPhone appears in the user's room.
- **Web rendering**: you need a `.glb`. Either grab one directly from Sketchfab / 3DModels.org, or convert a USDZ via [Apple's `usdzconvert`](https://developer.apple.com/download/all/?q=USDZ%20Tools) (CLI in USDZ Tools).
- **Best of both**: ship both. `<model-viewer src="iphone.glb" ios-src="iphone.usdz">` — desktop sees the GLB spin, iPhone visitors get AR.

## Add the web component to `index.html` once

```html
<script type="module"
  src="https://ajax.googleapis.com/ajax/libs/model-viewer/3.5.0/model-viewer.min.js">
</script>
```

Pin to a specific version (`3.5.0`), not `@latest` — protects you from a silent CDN update.

## The `modelViewer` helper for `sections/helpers.js`

```javascript
export const modelViewer = ({ src, iosSrc, alt, poster, height = 600 }) => ({
  apply(el) {
    el.style.width = '100%';
    el.style.height = height + 'px';
    el.style.display = 'block';
    const mv = document.createElement('model-viewer');
    mv.setAttribute('src', src);
    if (iosSrc) mv.setAttribute('ios-src', iosSrc);
    if (poster) mv.setAttribute('poster', poster);
    mv.setAttribute('alt', alt || '');
    mv.setAttribute('camera-controls', '');
    mv.setAttribute('auto-rotate', '');
    mv.setAttribute('ar', '');
    mv.setAttribute('ar-modes', 'webxr scene-viewer quick-look');
    mv.setAttribute('shadow-intensity', '1');
    mv.setAttribute('exposure', '1');
    mv.setAttribute('loading', 'lazy');
    mv.style.width = '100%';
    mv.style.height = '100%';
    el.appendChild(mv);
  }
});
```

## Usage in the parallax section

```javascript
import { VStack } from 'swiftui-for-web';
import { h1 } from './typography.js';
import { SPACING } from './theme.js';
import { modelViewer, cls } from './helpers.js';

export function ParallaxShowcase() {
  return VStack({ alignment: 'center', spacing: SPACING.s3 },
    h1('Made for every Apple device.'),
    VStack()
      .modifier(modelViewer({
        src: '/assets/iphone.glb',
        iosSrc: '/assets/iphone.usdz',
        alt: 'iPhone you can spin and view in AR',
        poster: '/assets/iphone-poster.webp',
        height: 720
      }))
      .modifier(cls('parallax-figure'))
  ).padding({ vertical: SPACING.s5, horizontal: SPACING.containerPx });
}
```

## Multi-device tableau (iPhone + iPad + Mac + Watch)

For an "Apple-ecosystem" hero, arrange four models in an HStack:

```javascript
HStack({ alignment: 'bottom', spacing: SPACING.s3 },
  VStack().modifier(modelViewer({ src: '/assets/iphone.glb',  height: 480 })),
  VStack().modifier(modelViewer({ src: '/assets/ipad.glb',    height: 480 })),
  VStack().modifier(modelViewer({ src: '/assets/macbook.glb', height: 480 })),
  VStack().modifier(modelViewer({ src: '/assets/watch.glb',   height: 240 }))
).modifier(cls('row-wrap'))
```

Four model-viewers on one page is heavy — see the performance budget below before shipping.

## Performance budget (real talk)

3D models blow the normal page budget if you're careless:

| Item | Typical weight | Notes |
|---|---|---|
| `<model-viewer>` web component | ~280 KB gzipped | Loaded once from CDN, cached |
| iPhone GLB (mid-poly) | 1–3 MB | Higher generations are heavier |
| MacBook GLB | 2–5 MB | Open-vs-closed states multiply |
| iPad GLB | 1–3 MB | |
| Apple Watch GLB | 0.5–1.5 MB | Smallest by far |
| Poster image (WebP) | 30–80 KB | Fallback users see during load |

### Rules

- **One 3D model per page max** for the parallax pattern. The 4-device tableau is the exception — budget for 8–15 MB total and accept it only when hardware-across-platforms is the message.
- **Always set `loading="lazy"` and a `poster=` attribute** so the first scroll doesn't stall waiting for the model.
- **Pin to a specific `<model-viewer>` version** in production.
- **Test on actual mobile data.** Run Lighthouse with throttling and verify the model doesn't push the LCP past 2.5s.

## When to skip 3D entirely

- The app is a utility / productivity tool where the device look isn't the point.
- The hero is a UX moment (a screen, a flow) rather than the hardware.
- Performance budget is tight (Lighthouse target ≥ 95).
- You don't have a designer or the patience to wrangle GLB lighting.

In those cases, stick with the PNG-bezel composite path from `sections.md` Section 2 — smaller, faster, and the screenshot is the message.
