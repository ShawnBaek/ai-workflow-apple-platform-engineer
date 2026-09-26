# 3D Apple device showcases (`<model-viewer>` + USDZ/GLB)

Scope: optional SwiftUI-For-Web recipe, used only when selected by the project.
Adapt example layout, tokens, sections and hosting to the accepted brief.


**Check the device-imagery rules first.** Apple's [App Store marketing guidelines](https://developer.apple.com/app-store/marketing/guidelines/) list rendering an Apple product in 3D, or simulating one, among the uses not permitted in marketing materials. They also ask for Apple product images as is: no spinning, animating or added shadows. For device imagery on an app's marketing site, default to Apple's [product bezels](https://developer.apple.com/design/resources/#product-bezels) as static images (see `sections.md`). Don't build a 3D model of an Apple device for app marketing unless the user explicitly chooses it after reviewing those guidelines, for example with Apple's permission. A marketplace license covers the model file; it doesn't change Apple's guidelines. The `<model-viewer>` mechanics below also fit models the project owns, such as its own hardware accessory.

When 3D is chosen, use it in **exactly one place per page**: the Section 3 showcase, or the hero visual in its place — the same restraint as the parallax rule.

**Tooling**: Google's [`<model-viewer>`](https://modelviewer.dev) web component. Drop in via a `<script type="module">` in `index.html`; works in every modern browser; supports both **GLB for the web** and **USDZ for iOS AR Quick Look** (tap-to-AR on iPhone visitors).

## Where to get the models

| Source | What's there | License | Format |
|---|---|---|---|
| **Internet Archive — Apple AR Products** ([archive.org/details/21-10-24-ar-products](https://archive.org/details/21-10-24-ar-products)) | **83 USDZ files depicting Apple products**: MacBook 13/14/16 (silver + space gray), MacBook Air (all colors), Mac Mini, Mac Pro, iMac 24", Pro Display XDR, iPhone SE/12/13 (all colors + variants), iPad Pro 11/12.9, iPad Air, iPad 10.2, iPad Mini, Apple Watch S3/S7/SE, AirPods Gen 3/Pro/Max, Apple TV 4K, AirTag, HomePod Mini. **~400 MB total** | **None granted.** A public archive copy is not permission; don't ship these on a commercial site without Apple's permission | USDZ |
| **Apple AR Quick Look gallery** ([developer.apple.com/quick-look-gallery](https://developer.apple.com/quick-look-gallery/)) | Sample objects (toys, instruments, food); no Apple devices. Useful for testing `ios-src` / AR Quick Look wiring | Apple site terms; no redistribution. Local wiring tests only | USDZ |
| **Sketchfab** ([sketchfab.com/tags/iphone](https://sketchfab.com/tags/iphone), `/tags/macbook`, `/tags/ipad`, `/tags/apple-watch`) | Community GLBs, recent generations | Per-model (many CC; check before commercial use) | **GLB** (native web) |
| **3DModels.org** ([3dmodels.org/3d-models/apple-iphone-15-green](https://3dmodels.org/3d-models/apple-iphone-15-green/)) | Royalty-free iPhone 15, iPhone 13 with separated screen material | Royalty-free | GLB + glTF |

## Pick one path

- **iPhone visitor → AR Quick Look magic**: ship a `.usdz` you have the rights to, linked via `<model-viewer ios-src>`. Tapping the AR badge opens AR Quick Look — the model appears in the user's room.
- **Web rendering**: you need a `.glb`. Either get one directly from a source whose license covers your use, or convert a USDZ you have the rights to: import it with [Blender's USD importer](https://docs.blender.org/manual/en/latest/files/import_export/usd.html) (it reads `.usdz`; review its texture-import option) and export **glTF Binary (`.glb`)** with Blender's bundled [glTF 2.0 add-on](https://docs.blender.org/manual/en/latest/addons/scene_gltf2.html). Check materials and scale in `<model-viewer>` afterwards. Apple's `usdzconvert` goes the other way (glTF/OBJ/FBX/USD → USDZ) and can't produce a GLB.
- **Best of both**: ship both. `<model-viewer src="model.glb" ios-src="model.usdz">` — desktop sees the GLB, iPhone visitors get AR.

## Add the web component to `index.html` once

```html
<script type="module"
  src="https://ajax.googleapis.com/ajax/libs/model-viewer/3.5.0/model-viewer.min.js">
</script>
```

Pin to a specific version (`3.5.0`), not `@latest` — protects you from a silent CDN update.

## The `modelViewer` helper for `sections/helpers.js`

```javascript
// still: true for an approved Apple product model (see the device-imagery check):
// no auto-rotate and no added shadow.
export const modelViewer = ({ src, iosSrc, alt, poster, height = 600, still = false }) => ({
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
    if (!still) {
      mv.setAttribute('auto-rotate', '');
      mv.setAttribute('shadow-intensity', '1');
    }
    mv.setAttribute('ar', '');
    mv.setAttribute('ar-modes', 'webxr scene-viewer quick-look');
    mv.setAttribute('exposure', '1');
    mv.setAttribute('loading', 'lazy');
    mv.style.width = '100%';
    mv.style.height = '100%';
    el.appendChild(mv);
  }
});
```

## Usage in the parallax section

The worked example is a model the project owns (here, the app's companion tag), so motion is a design choice:

```javascript
import { VStack } from 'swiftui-for-web';
import { h1 } from './typography.js';
import { SPACING } from './theme.js';
import { modelViewer, cls } from './helpers.js';

export function ParallaxShowcase() {
  return VStack({ alignment: 'center', spacing: SPACING.s3 },
    h1('Clip it on. Find it in the app.'),
    VStack()
      .modifier(modelViewer({
        src: '/assets/tag.glb',
        iosSrc: '/assets/tag.usdz',
        alt: 'The companion tag, which you can rotate and view in AR',
        poster: '/assets/tag-poster.webp',
        height: 720
      }))
      .modifier(cls('parallax-figure'))
  ).padding({ vertical: SPACING.s5, horizontal: SPACING.containerPx });
}
```

**Apple product model (only after the device-imagery check, with Apple's permission):** pass `still: true`, leave off `cls('parallax-figure')` and any other animation class, and use neutral alt text that names the device and screen, for example `'iPhone 13 showing the journal screen'`. Keep to what the permission covers.

## Multi-device tableau (iPhone + iPad + Mac + Watch)

For an "Apple-ecosystem" hero, arrange four models in an HStack. This renders four Apple products in 3D, so it needs the same permission as above; without it, place static product-bezel images side by side instead.

```javascript
HStack({ alignment: 'bottom', spacing: SPACING.s3 },
  VStack().modifier(modelViewer({ src: '/assets/iphone.glb',  alt: 'iPhone',      still: true, height: 480 })),
  VStack().modifier(modelViewer({ src: '/assets/ipad.glb',    alt: 'iPad',        still: true, height: 480 })),
  VStack().modifier(modelViewer({ src: '/assets/macbook.glb', alt: 'MacBook',     still: true, height: 480 })),
  VStack().modifier(modelViewer({ src: '/assets/watch.glb',   alt: 'Apple Watch', still: true, height: 240 }))
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

- The model depicts an Apple product and the device-imagery decision at the top hasn't been made.
- The app is a utility / productivity tool where the device look isn't the point.
- The hero is a UX moment (a screen, a flow) rather than the hardware.
- Performance budget is tight (Lighthouse target ≥ 95).
- You don't have a designer or the patience to wrangle GLB lighting.

In those cases, stick with the PNG-bezel composite path from `sections.md` Section 2 — smaller, faster, and the screenshot is the message.
