// theme.js — bridges SwiftUI-For-Web's value-based modifiers to the things
// the framework doesn't model: CSS-variable colors (for dark mode) and
// viewport-dependent values (for responsive type / spacing).
//
// Goal: real SwiftUI-For-Web modifiers everywhere. CSS only for behavior
// the framework can't express (hover, scroll-driven animation, dark-mode
// color cascading).

/**
 * Returns a Color-shaped object whose .rgba() emits `var(--name)`.
 * Lets you use `.foregroundColor(cssColor('--color-label'))` and still get
 * dark-mode + theming via CSS variables.
 *
 * `.foregroundColor()` calls `color.rgba()` and assigns the result to
 * `element.style.color`. A CSS variable string works perfectly.
 */
export const cssColor = (cssVarName) => ({
  rgba: () => `var(${cssVarName})`
});

/**
 * Pick a value based on the current viewport at render time.
 *   responsive(16, 18, 20)  →  16 below 768px, 18 from 768-1023, 20 from 1024+
 *
 * Snapshot at mount time. Mobile users get mobile values; desktop users
 * get desktop values. Not reactive on window resize — re-rendering on
 * resize is out of scope for a static one-pager.
 */
export const responsive = (mobile, tablet, desktop) => {
  const w = typeof window !== 'undefined' ? window.innerWidth : 1280;
  return w >= 1024 ? desktop : w >= 768 ? tablet : mobile;
};

// ─── Vertical rhythm constants (Gridlover-generated per breakpoint) ────────
// Use directly with the .padding({ vertical, horizontal }) modifier.

export const SPACING = {
  // 1 baseline unit (intra-element spacing)
  s1: responsive(12, 13.5, 15),
  // 2 baselines (paragraph gap)
  s2: responsive(24, 27, 30),
  // 4 baselines (sub-section gap)
  s3: responsive(48, 54, 60),
  // 8 baselines (top-level section vertical pad)
  s4: responsive(72, 81, 120),
  // 16 baselines (dramatic break, parallax)
  s5: responsive(144, 162, 240),
  // horizontal container padding
  containerPx: responsive(20, 40, 60),
};

// ─── Typography size + line-height pairs (Gridlover, per breakpoint) ──────
// Use with the typography factory functions in typography.js.

export const TYPE = {
  body:    { size: responsive(16,    18,    20),   lh: responsive(24,  27,  30)  },
  lead:    { size: responsive(18.96, 21.49, 24),   lh: responsive(24,  27,  30)  },
  h3:      { size: responsive(22.78, 25.46, 28.28),lh: responsive(24,  27,  30)  },
  h2:      { size: responsive(28.43, 36,    40),   lh: responsive(48,  54,  60)  },
  h1:      { size: responsive(37.90, 50.91, 56.57),lh: responsive(48,  54,  60)  },
  display: { size: responsive(50.52, 72,    80),   lh: responsive(72, 108, 120)  },
};
