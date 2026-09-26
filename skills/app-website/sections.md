# 5-section canonical spec + vertical rhythm

Scope: optional SwiftUI-For-Web recipe, used only when selected by the project.
Adapt example layout, tokens, sections and hosting to the accepted brief.


## Vertical rhythm — use these numbers

Generated from Gridlover at **base 20px / line-height 1.5 / scale 1.414 (√2)** — readable, snaps cleanly, gives a 30px baseline grid. These are the **desktop** values. The `responsive()` helper in `theme.js` regenerates the full scale per breakpoint (24px / 27px / 30px baseline at mobile/tablet/desktop).

### Type scale (desktop)

| Token | Font size | Line height | Use for |
|-------|-----------|-------------|---------|
| `--fs-body`    | 20px    | 30px  | Body paragraphs |
| `--fs-lead`    | 24px    | 30px  | Lead-in paragraphs under headlines |
| `--fs-h3`      | 28.28px | 30px  | Section subhead |
| `--fs-h2`      | 40px    | 60px  | Section title |
| `--fs-h1`      | 56.57px | 60px  | Hero subhead |
| `--fs-display` | 80px    | 120px | Hero headline |

### Spacing scale — multiples of 30 (one baseline unit)

| Token | Value | Use for |
|-------|-------|---------|
| `SPACING.s1` | 15px  | Tight intra-element (label → input) |
| `SPACING.s2` | 30px  | Between paragraphs, between related stack items |
| `SPACING.s3` | 60px  | Between sub-sections |
| `SPACING.s4` | 120px | Between top-level sections |
| `SPACING.s5` | 240px | Dramatic section breaks (parallax) |

For responsive sizing the values switch per breakpoint — see `responsive.md`.

You can regenerate the scale at https://www.gridlover.net/try if you want a different base — keep base/lh/scale documented so the developer can iterate without breaking the grid.

---

## Section 1 — About / Hero

**Goal:** in one screen, the visitor knows what the app does and decides whether to scroll.

- **Display headline** — one short sentence, the app's one-sentence pitch
- **Lead paragraph** — one sentence: who it's for, what changes for them
- **Primary CTA** — Apple's official App Store SVG badge ([download](https://tools.applemediaservices.com/app-store/))
- **Hero visual** — either:
  - a single iPhone-framed screenshot of the app's signature screen, **or**
  - a short autoplay-muted video loop (≤ 10s, ≤ 2MB), **or**
  - a 3D model via `<model-viewer>`, only after the device-imagery check in `3d-devices.md`

Layout: HStack with copy on the left, hero visual on the right (desktop); the `.row-wrap` class collapses both into a column on mobile. Section padding: `SPACING.s4` top and bottom.

**Default:** no top nav bar on a one-pager; in-page anchor links are optional. Add navigation when the brief has more pages or asks for it.

```javascript
import { HStack, VStack, Image, Spacer } from 'swiftui-for-web';
import { display, lead } from './typography.js';
import { SPACING } from './theme.js';
import { attrs, cls, externalLink } from './helpers.js';

export function HeroSection() {
  return HStack({ alignment: 'center', spacing: SPACING.s3 },
    VStack({ alignment: 'leading', spacing: SPACING.s2 },
      VStack({ alignment: 'leading', spacing: SPACING.s2 },
        display('A journal that disappears the moment you stop writing.'),
        lead('A quiet journaling app for iPhone, iPad, Mac, and Apple Watch.')
      ).modifier(cls('reveal')), // optional motion: the copy only
      AppStoreBadge()             // badge and bezel stay static (see Animation rules)
    ).modifier(cls('hero-copy')),

    Spacer(),

    Image('/assets/hero-iphone.png')
      .frame({ width: 320 })
      .modifier(attrs({ alt: 'Hero screenshot of the app.' }))
  ).padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx })
    .modifier(cls('row-wrap'));
}

// A real <a href>: Tab + Enter, middle-click and "open in new tab" all work.
function AppStoreBadge() {
  return HStack().modifier(externalLink('https://apps.apple.com/app/id...',
    { src: '/assets/app-store-badge.svg', alt: 'Download on the App Store', height: 54 }));
}
```

---

## Section 2 — Key Features

**Goal:** show, don't tell. Each feature is a screenshot + a one-sentence caption.

- **Start with about 3 features**, then fit the count to the brief. Each extra feature adds scroll, so keep only the ones the pitch needs.
- Each feature: iPhone-framed screenshot on one side, **short** title (one line, h2) + **short** description (one sentence, body) on the other.
- Alternate sides feature-to-feature: left / right / left.
- Vertical gap between features: `SPACING.s4`.

### iPhone framing — two paths

| Approach | Effort | When to use |
|----------|--------|-------------|
| **PNG bezel composite** | Low (~15 min) | First-version sites, fast iteration |
| **`<model-viewer>` 3D** | Medium (~30 min) | One place per page (the hero or the Section 3 showcase), after the device-imagery check in `3d-devices.md` |

For PNG bezels: download Apple's product bezels from [Apple Design Resources](https://developer.apple.com/design/resources/#product-bezels). Composite the screenshot inside the bezel in GIMP or Photopea; export PNG with transparent background. Use the bezel as is: Apple's [App Store marketing guidelines](https://developer.apple.com/app-store/marketing/guidelines/) rule out added shadows or reflections, tilting, cropping and animating product images.

```javascript
function FeatureRow({ title, body: bodyText, screenshot, alt, side }) {
  const screenView = Image(screenshot)
    .frame({ width: 320 })
    .modifier(attrs({ alt, loading: 'lazy' }));

  const textView = VStack({ alignment: 'leading', spacing: SPACING.s1 },
    h2(title),
    body(bodyText)
  ).modifier(cls('reveal')); // optional motion on the text; the bezel screenshot stays static

  const children = side === 'left'
    ? [screenView, Spacer(), textView]
    : [textView, Spacer(), screenView];

  return HStack({ alignment: 'center', spacing: SPACING.s3 }, ...children)
    .padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx })
    .modifier(cls('row-wrap'));
}
```

---

## Section 3 — Product showcase

**Goal:** explain the product with a key screen or feature graphic. Use a static visual by default. Add motion or an interactive model only when it serves the agreed design direction and fits the performance budget.

If motion is selected, these are optional implementation paths. For a static page, render the image without animation classes or an interactive model.

### Path A — Scroll-driven showcase (optional)

CSS scroll-driven animations (Chrome/Edge/Safari supported) declaratively:

```css
@keyframes parallax-zoom {
  from { transform: translateY(40vh) scale(0.85); opacity: 0.6; }
  to   { transform: translateY(0)    scale(1.00); opacity: 1.0; }
}

.parallax-figure {
  animation: parallax-zoom linear both;
  animation-timeline: view();
  animation-range: entry 0% cover 50%;
}
```

In SwiftUI-For-Web, attach the class via the `cls` helper:

```javascript
function ParallaxShowcase() {
  return VStack({ alignment: 'center', spacing: SPACING.s3 },
    h1('See your week, your month, your year.'),
    Image('/assets/timeline.png') // a screen or feature graphic, not a device bezel
      .modifier(cls('parallax-figure'))
      .modifier(attrs({ alt: '…', loading: 'lazy' }))
  ).padding({ vertical: SPACING.s5, horizontal: SPACING.containerPx });
}
```

### Path B — 3D `<model-viewer>` showcase

Replace the Image with an interactive 3D model. Start with the device-imagery check in `3d-devices.md`: Apple's marketing guidelines don't permit 3D renderings of Apple products.

Use at most one parallax section when selected. A no-motion direction uses a static showcase.

---

## Section 4 — Download

- **App Store badge** — Apple's official SVG from https://tools.applemediaservices.com/app-store/
- **System requirements** in one line, using the app's actual supported platforms and minimum OS versions from its project and store listing. Do not advertise unsupported platforms or replace the minimum with the current SDK version.
- Optional: **TestFlight beta link** if you have one ("Try the beta on TestFlight →")

Centered. Generous vertical padding (`SPACING.s4` top and bottom). **No form, no email capture** — those belong on a separate page.

```javascript
function DownloadSection() {
  return VStack({ alignment: 'center', spacing: SPACING.s2 },
    h2('Available now.'),
    HStack().modifier(externalLink(APP_STORE_URL,
      { src: '/assets/app-store-badge.svg', alt: 'Download on the App Store', height: 54 })),
    caption(SYSTEM_REQUIREMENTS) // Verified app-specific platforms and minimum OS versions.
  ).padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx }); // no reveal: it holds the badge
}
```

---

## Section 5 — Share + footer

- **Share links:** X, Threads, Mastodon — share-intent URLs as real `<a href>` links via `externalLink`, no SDK, no AddThis
- **Copy-link button** — a framework `Button` (a native `<button>`) running `navigator.clipboard.writeText(...)`
- **Footer line:** `© 2026 [Developer Name] · [Email] · [Privacy]`
- **Optional credit line:** include framework promotion only if the user selects it. Required license notices follow the dependency's actual license, independently of visible branding.

```javascript
// sections/ShareSection.js also imports Button from 'swiftui-for-web' (unlike the hero).
export function ShareSection() {
  const url = encodeURIComponent(SITE_URL);
  const text = encodeURIComponent('Just found this — a quiet journaling app.');
  const share = (href, label) => HStack().modifier(externalLink(href, label, 'share-link'));

  return VStack({ alignment: 'center', spacing: SPACING.s2 },
    h3('Tell a friend.'),

    HStack({ alignment: 'center', spacing: SPACING.s2 },
      share(`https://x.com/intent/post?text=${text}&url=${url}`, 'Share on X'),
      share(`https://www.threads.net/intent/post?text=${text}%20${url}`, 'Share on Threads'),
      share(`https://mastodon.social/share?text=${text}%20${url}`, 'Share on Mastodon'),
      Button('Copy link', () => navigator.clipboard.writeText(SITE_URL))
        .buttonStyle('plain') // drops the default inline blue so .share-link styles it
        .modifier(cls('share-link'))
    ).modifier(cls('row-wrap')),

    caption('© 2026 — Developer Name · hi@developer.com · Privacy'),

    // Optional example credit: remove unless requested by the user.
    HStack().modifier(externalLink('https://github.com/ShawnBaek/SwiftUI-For-Web',
      'Made with SwiftUI-For-Web ↗', 'made-with'))
  ).padding({ top: SPACING.s3, bottom: SPACING.s4, left: SPACING.containerPx, right: SPACING.containerPx });
}
```

---

## File layout this skill generates

```
my-app-website/
├── index.html                     # tiny shell, importmap, mounts #root
├── main.js                        # SwiftUI-For-Web entry; imports sections
├── sections/
│   ├── HeroSection.js
│   ├── FeaturesSection.js
│   ├── ParallaxShowcase.js
│   ├── DownloadSection.js
│   ├── ShareSection.js
│   ├── theme.js                   # cssColor, responsive, SPACING, TYPE
│   ├── typography.js              # display, h1, h2, h3, lead, body, caption
│   └── helpers.js                 # attrs, cls, externalLink (+ modelViewer if using 3D)
├── styles/
│   ├── reset.css                  # ~25 lines
│   └── tokens.css                 # ~100 lines — color vars, hover, scroll animations
└── assets/
    ├── hero-iphone.png
    ├── feature-{1,2,3}.png
    ├── app-store-badge.svg
    └── og.png                     # Open Graph share image
```

### `index.html` skeleton

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>App Name — one-sentence pitch</title>
  <meta name="description" content="One sentence that earns the click.">
  <meta property="og:image" content="https://myapp.com/assets/og.png">
  <link rel="stylesheet" href="./styles/reset.css">
  <link rel="stylesheet" href="./styles/tokens.css">
  <!-- Pinned SwiftUI-For-Web commit (2.0.0-alpha.1); @main changes on every upstream push.
       To update: review the upstream changes, take the new SHA from
       `gh api repos/ShawnBaek/SwiftUI-For-Web/commits/main --jq .sha`, swap it in,
       then rerun the browser verification. -->
  <script type="importmap">
  { "imports": { "swiftui-for-web": "https://cdn.jsdelivr.net/gh/ShawnBaek/SwiftUI-For-Web@19621bbe6be374c5060590c2cb5bdf5c7ee357e3/src/index.js" } }
  </script>
  <!-- Only include if you're using 3D models: -->
  <script type="module" src="https://ajax.googleapis.com/ajax/libs/model-viewer/3.5.0/model-viewer.min.js"></script>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="./main.js"></script>
</body>
</html>
```

## Performance budget

- **Total page weight ≤ 1.5 MB** including images (hero ≤ 400 KB, each feature ≤ 200 KB)
- **Images: WebP or AVIF**, never raw PNG > 200 KB
- **Lighthouse ≥ 95** before shipping
- **Lazy-load below the fold:** `loading="lazy"` on every `<img>` past the hero

## Typography rules

- **Typography follows the approved brand.** Default to a system stack when none is specified. For an approved web font, verify its license, loading cost, fallback metrics and layout stability.
- **Measure ≤ 38em** for body — never let paragraphs run the full viewport width
- **One weight per role**: display = 700, headings = 600, body = 400
- **Letter-spacing decreases as size increases:** display `-0.022em`, h1 `-0.020em`, h2 `-0.018em`, body 0
- **Contrast ≥ 4.5:1** for body (WCAG AA) — use the semantic color vars

## Animation rules

Motion is optional. A no-motion preference keeps content visible and static without reveal, parallax or scaling effects. When motion is selected:

- **Reveal on scroll** (`.reveal` class) may support section copy. Put it on the text stack, never on a container that holds the App Store badge or a bezel image; keep content visible if animation is unavailable
- **Parallax** belongs in Section 3 only, at most once, on a screen or feature graphic without a device bezel
- **Hover** may change a link's color or underline. Don't scale, angle or animate the App Store badge or device bezels; Apple's marketing guidelines ask for both as is
- **No looping decorative animations** — they distract and burn mobile battery
- **`prefers-reduced-motion: reduce`** removes reveals, parallax and scaling while keeping all content visible and usable
