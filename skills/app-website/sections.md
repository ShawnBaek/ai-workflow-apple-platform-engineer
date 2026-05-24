# 5-section canonical spec + vertical rhythm

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
  - a 3D model via `<model-viewer>` (see `3d-devices.md`)

Layout: HStack with copy on the left, hero visual on the right (desktop); the `.row-wrap` class collapses both into a column on mobile. Section padding: `SPACING.s4` top and bottom.

**Do not** put nav links across the top. This is a one-pager — anchor links are optional, hamburger nav is not.

```javascript
import { HStack, VStack, Image, Spacer } from 'swiftui-for-web';
import { display, lead } from './typography.js';
import { SPACING, cssColor } from './theme.js';
import { attrs, cls } from './helpers.js';

export function HeroSection() {
  return HStack({ alignment: 'center', spacing: SPACING.s3 },
    VStack({ alignment: 'leading', spacing: SPACING.s2 },
      display('A journal that disappears the moment you stop writing.'),
      lead('A quiet journaling app for iPhone, iPad, Mac, and Apple Watch.'),
      AppStoreBadge()
    ).modifier(cls('hero-copy')),

    Spacer(),

    Image('/assets/hero-iphone.png')
      .frame({ width: 320 })
      .shadow({ y: 40, radius: 80, color: cssColor('--color-shadow') })
      .modifier(attrs({ alt: 'Hero screenshot of the app.' }))
  ).padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx })
    .modifier(cls('row-wrap', 'reveal'));
}

function AppStoreBadge() {
  return Image('/assets/app-store-badge.svg')
    .frame({ height: 54 })
    .onTapGesture(() => window.open('https://apps.apple.com/app/id...', '_blank', 'noopener,noreferrer'))
    .modifier(attrs({ alt: 'Download on the App Store', role: 'link', tabindex: '0' }));
}
```

---

## Section 2 — Key Features

**Goal:** show, don't tell. Each feature is a screenshot + a one-sentence caption.

- **Exactly 3 features.** More = more scroll = lower conversion. No 4th.
- Each feature: iPhone-framed screenshot on one side, **short** title (one line, h2) + **short** description (one sentence, body) on the other.
- Alternate sides feature-to-feature: left / right / left.
- Vertical gap between features: `SPACING.s4`.

### iPhone framing — two paths

| Approach | Effort | When to use |
|----------|--------|-------------|
| **PNG bezel composite** | Low (~15 min) | First-version sites, fast iteration |
| **`<model-viewer>` 3D** | Medium (~30 min) | Hero feature only — see `3d-devices.md` |

For PNG bezels: download Apple's official device frames from https://developer.apple.com/design/resources/ ("Product Marketing" section). Composite the screenshot inside the bezel in GIMP or Photopea; export PNG with transparent background.

```javascript
function FeatureRow({ title, body: bodyText, screenshot, alt, side }) {
  const screenView = Image(screenshot)
    .frame({ width: 320 })
    .shadow({ y: 40, radius: 80, color: cssColor('--color-shadow') })
    .modifier(attrs({ alt, loading: 'lazy' }));

  const textView = VStack({ alignment: 'leading', spacing: SPACING.s1 },
    h2(title),
    body(bodyText)
  );

  const children = side === 'left'
    ? [screenView, Spacer(), textView]
    : [textView, Spacer(), screenView];

  return HStack({ alignment: 'center', spacing: SPACING.s3 }, ...children)
    .padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx })
    .modifier(cls('row-wrap', 'reveal'));
}
```

---

## Section 3 — Parallax product showcase

**Goal:** one cinematic moment that earns scroll attention. Apple does this with the MacBook on the product page; you do it with your app's hero artifact (a key screen, a feature graphic, or a 3D model).

Two implementation paths:

### Path A — Scroll-driven sticky section (recommended)

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
    Image('/assets/timeline.png')
      .modifier(cls('parallax-figure'))
      .modifier(attrs({ alt: '…', loading: 'lazy' }))
  ).padding({ vertical: SPACING.s5, horizontal: SPACING.containerPx });
}
```

### Path B — 3D `<model-viewer>` showcase

Replace the Image with a spinnable iPhone/iPad/Mac/Watch model. See `3d-devices.md` for the full guide.

**One parallax moment per page. Never two.** Visitors who scroll past two parallax sections leave.

---

## Section 4 — Download

- **App Store badge** — Apple's official SVG from https://tools.applemediaservices.com/app-store/
- **System requirements** in one line: "Requires iOS 26, iPadOS 26, macOS 26, or watchOS 26 or later."
- Optional: **TestFlight beta link** if you have one ("Try the beta on TestFlight →")
- Future: Google Play badge when the planned `android-ui` skill ships

Centered. Generous vertical padding (`SPACING.s4` top and bottom). **No form, no email capture** — those belong on a separate page.

```javascript
function DownloadSection() {
  return VStack({ alignment: 'center', spacing: SPACING.s2 },
    h2('Available now.'),
    Image('/assets/app-store-badge.svg')
      .frame({ height: 54 })
      .onTapGesture(() => window.open(APP_STORE_URL, '_blank', 'noopener,noreferrer'))
      .modifier(attrs({ alt: 'Download on the App Store', role: 'link', tabindex: '0' })),
    caption('Requires iOS 26, iPadOS 26, macOS 26, or watchOS 26 or later.')
  ).padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx })
    .modifier(cls('reveal'));
}
```

---

## Section 5 — Share + footer

- **Share buttons:** X, Threads, Mastodon — use share-intent URLs, no SDK, no AddThis
- **Copy-link button** — `navigator.clipboard.writeText(window.location.href)`
- **Footer line:** `© 2026 [Developer Name] · [Email] · [Privacy]`
- **Mandatory credit line:** `Made with SwiftUI-For-Web ↗` linking to `https://github.com/ShawnBaek/SwiftUI-For-Web`. Small, tertiary-label color, low-key — same convention as "Hosted on GitHub" on GitHub Pages sites or Cloudflare-Pages credit. Pays back the framework you used and helps other indie devs discover it.

```javascript
export function ShareSection() {
  const url = encodeURIComponent(SITE_URL);
  const text = encodeURIComponent('Just found this — a quiet journaling app.');

  return VStack({ alignment: 'center', spacing: SPACING.s2 },
    h3('Tell a friend.'),

    HStack({ alignment: 'center', spacing: SPACING.s2 },
      body('Share on X')
        .onTapGesture(() => window.open(`https://x.com/intent/post?text=${text}&url=${url}`, '_blank'))
        .modifier(cls('share-link'))
        .modifier(attrs({ role: 'link', tabindex: '0' })),
      body('Share on Threads')
        .onTapGesture(() => window.open(`https://www.threads.net/intent/post?text=${text}%20${url}`, '_blank'))
        .modifier(cls('share-link')),
      body('Share on Mastodon')
        .onTapGesture(() => window.open(`https://mastodon.social/share?text=${text}%20${url}`, '_blank'))
        .modifier(cls('share-link')),
      body('Copy link')
        .onTapGesture(() => navigator.clipboard.writeText(SITE_URL))
        .modifier(cls('share-link'))
    ).modifier(cls('row-wrap')),

    caption('© 2026 — Developer Name · hi@developer.com · Privacy'),

    // Mandatory framework credit
    caption('Made with SwiftUI-For-Web ↗')
      .onTapGesture(() => window.open('https://github.com/ShawnBaek/SwiftUI-For-Web', '_blank'))
      .modifier(cls('made-with'))
      .modifier(attrs({ role: 'link', tabindex: '0' }))
  ).padding({ top: SPACING.s3, bottom: SPACING.s4, left: SPACING.containerPx, right: SPACING.containerPx });
}
```

---

## File layout this skill generates

```
my-app-website/
├── index.html                     # tiny shell, importmap, mounts #root
├── main.js                        # SwiftUI-For-Web entry; imports sections
├── package.json                   # SwiftUI-For-Web dependency
├── sections/
│   ├── HeroSection.js
│   ├── FeaturesSection.js
│   ├── ParallaxShowcase.js
│   ├── DownloadSection.js
│   ├── ShareSection.js
│   ├── theme.js                   # cssColor, responsive, SPACING, TYPE
│   ├── typography.js              # display, h1, h2, h3, lead, body, caption
│   └── helpers.js                 # attrs, cls (+ modelViewer if using 3D)
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
  <script type="importmap">
  { "imports": { "swiftui-for-web": "https://cdn.jsdelivr.net/gh/ShawnBaek/SwiftUI-For-Web@main/src/index.js" } }
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

- **One typeface.** System font stack — feels native, zero CLS, zero web font HTTP requests
- **Measure ≤ 38em** for body — never let paragraphs run the full viewport width
- **One weight per role**: display = 700, headings = 600, body = 400
- **Letter-spacing decreases as size increases:** display `-0.022em`, h1 `-0.020em`, h2 `-0.018em`, body 0
- **Contrast ≥ 4.5:1** for body (WCAG AA) — use the semantic color vars

## Animation rules

- **Reveal on scroll** for each top-level section (`.reveal` class, fade up 30px, 600ms ease-out)
- **Parallax** in Section 3 only — never two
- **Hover** on the App Store badge: subtle scale (1 → 1.03) over 200ms
- **No looping decorative animations** — they distract and burn mobile battery
- **`prefers-reduced-motion: reduce`** disables `.reveal` and `.parallax-figure` entirely
