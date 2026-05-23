// helpers.js — narrow escape hatches for things SwiftUI-For-Web genuinely
// can't model: HTML attributes (alt, aria-*, loading) and CSS class names
// for scroll-driven animations + hover behavior.
//
// Everything visual (color, font, spacing, shadow, frame, tap) should go
// through real SwiftUI-For-Web modifiers (see theme.js / typography.js).

/** Add HTML attributes (alt, aria-label, loading, role, etc.). */
export const attrs = (map) => ({
  apply(el) {
    for (const [k, v] of Object.entries(map)) {
      if (v != null) el.setAttribute(k, String(v));
    }
  }
});

/** Add CSS class names — used only for animation hooks (.reveal, .parallax-figure) and hover (.share-link). */
export const cls = (...names) => ({
  apply(el) { for (const n of names) if (n) el.classList.add(n); }
});

/**
 * Embed a <model-viewer> 3D model inside any SwiftUI-For-Web view.
 * Requires <script type="module" src=".../model-viewer.min.js"></script> in index.html.
 *
 * Usage:
 *   VStack().modifier(modelViewer({
 *     src: '/assets/iphone.glb',          // GLB for web rendering
 *     iosSrc: '/assets/iphone.usdz',      // USDZ for iOS AR Quick Look (optional)
 *     poster: '/assets/iphone-poster.webp', // shown during load
 *     alt: 'iPhone in 3D',
 *     height: 720
 *   }))
 *
 * Sources for Apple device 3D models:
 *   - https://archive.org/details/21-10-24-ar-products  (87 official Apple USDZ)
 *   - https://sketchfab.com/tags/iphone                  (community GLB, more recent)
 *   - https://3dmodels.org/3d-models/apple-iphone-15-green/  (royalty-free GLB)
 */
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
