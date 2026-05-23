// Section 3 — Parallax showcase
//
// Current implementation: scroll-driven flat image (.parallax-figure CSS class).
//
// 3D upgrade path: swap the Image() for VStack().modifier(modelViewer({...}))
// once you have a .glb (and optionally a .usdz for iOS AR Quick Look). Sources:
//   - archive.org/details/21-10-24-ar-products  (87 official Apple USDZ)
//   - sketchfab.com/tags/iphone                  (community GLB, recent generations)
// See the commented block at the bottom of this file.
//
// VERIFIED: the modelViewer helper was tested in Chrome with
// https://modelviewer.dev/shared-assets/models/Astronaut.glb — the 3D model
// rendered correctly inside the .parallax-figure animation container with
// camera-controls + auto-rotate + AR badge. Console clean.

import { VStack } from 'swiftui-for-web';
import { h1 } from './typography.js';
import { SPACING } from './theme.js';
import { cls, modelViewer } from './helpers.js';

const extra = (s) => ({ apply(el) { Object.assign(el.style, s); } });

// LOCAL DEMO: uses model-viewer's public Astronaut.glb so the parallax
// section has real content even without binary assets in the repo. For
// production, swap to a local /assets/iphone.glb (see commented variants
// at the bottom of this file).
export function ParallaxShowcase() {
  return VStack({ alignment: 'center', spacing: SPACING.s3 },
    h1('See your week, your month, your year.')
      .modifier(extra({ textAlign: 'center', maxWidth: '20ch' })),

    VStack()
      .modifier(modelViewer({
        src: 'https://modelviewer.dev/shared-assets/models/Astronaut.glb',
        alt: 'A 3D astronaut you can spin (demo placeholder; swap for iphone.glb in prod)',
        height: 600
      }))
      .modifier(cls('parallax-figure'))
  ).padding({ vertical: SPACING.s5, horizontal: SPACING.containerPx });
}

/*
// 3D variant — uncomment and replace the Image() block above when you have a model.
// Drops one iPhone you can spin (auto-rotate). Tapping the AR badge on iOS
// opens AR Quick Look so visitors can place the iPhone in their room.
//
// VStack().modifier(modelViewer({
//   src:    '/assets/iphone.glb',          // ~1–3 MB; from Sketchfab or 3dmodels.org
//   iosSrc: '/assets/iphone.usdz',         // optional; from archive.org Apple AR Products
//   poster: '/assets/iphone-poster.webp',  // shown during load (~30–80 KB)
//   alt:    'iPhone you can spin and view in AR',
//   height: 720
// })).modifier(cls('parallax-figure'))

// Ecosystem tableau — iPhone + iPad + MacBook + Watch in one row.
// Heavy (~8–15 MB total). Only ship if hardware-across-platforms is the message.
//
//   HStack({ alignment: 'bottom', spacing: SPACING.s3 },
//     VStack().modifier(modelViewer({ src: '/assets/iphone.glb',  height: 480 })),
//     VStack().modifier(modelViewer({ src: '/assets/ipad.glb',    height: 480 })),
//     VStack().modifier(modelViewer({ src: '/assets/macbook.glb', height: 480 })),
//     VStack().modifier(modelViewer({ src: '/assets/watch.glb',   height: 240 }))
//   ).modifier(cls('row-wrap'))
*/
