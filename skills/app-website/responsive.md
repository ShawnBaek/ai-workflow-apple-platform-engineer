# Responsive design — mobile / tablet / desktop

The site must look right at **375px (iPhone), 768px (iPad), 1024px+ (laptop/desktop), and 1440px+ (wide)**. Enforced with **breakpoint-stepped rhythm tokens**, not fluid `clamp()`.

## Breakpoints

| Name | Range | Trigger |
|------|-------|---------|
| mobile  | < 768px       | default (mobile-first) |
| tablet  | 768 – 1023px  | `@media (min-width: 768px)` |
| desktop | ≥ 1024px      | `@media (min-width: 1024px)` |

## Stepped rhythm — the whole point of Gridlover at every viewport

Fluid `clamp()`-based typography breaks the baseline grid — line-heights stop being multiples of a single baseline. So you regenerate the full Gridlover scale per breakpoint and switch via the `responsive()` helper. Each breakpoint has its own consistent rhythm.

| | mobile | tablet | desktop |
|---|---|---|---|
| **Base size**       | 16px      | 18px      | 20px      |
| **Line-height ratio** | 1.5     | 1.5       | 1.5       |
| **Scale factor**    | 1.333     | 1.414 (√2) | 1.414 (√2) |
| **Baseline grid**   | **24px**  | **27px**  | **30px**  |
| `TYPE.body.size`    | 16px      | 18px      | 20px      |
| `TYPE.h2.size`      | 28.43px   | 36px      | 40px      |
| `TYPE.display.size` | 50.52px   | 72px      | 80px      |
| `SPACING.s2`        | 24px      | 27px      | 30px      |
| `SPACING.s4`        | 72px      | 81px      | 120px     |
| `SPACING.containerPx` | 20px    | 40px      | 60px      |
| iPhone frame width  | min(85vw, 280px) | 280px | 320px |

All values come from `theme.js` via the `responsive(mobile, tablet, desktop)` helper. Read once at render time per visitor.

## Stack behavior across breakpoints

SwiftUI-For-Web's `HStack` does not accept `wrap: true`. Add `.row-wrap` via the `cls` helper — CSS handles `flex-wrap: wrap`. When the children no longer fit, they wrap to the next line. On mobile this gives you a column; on desktop a row.

```javascript
HStack({ alignment: 'center', spacing: SPACING.s3 },
  TextColumn(),
  Spacer(),
  ScreenshotColumn()
).modifier(cls('row-wrap'))
```

No `if (isMobile)` branching — layout adapts via wrap + responsive tokens.

## Where responsive padding lives

Outer section padding pulls from `SPACING.s4` / `SPACING.containerPx` via the `responsive()` helper — same JS call works at every breakpoint:

```javascript
.padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx })
```

`SPACING.s4` returns 72 / 81 / 120 px depending on viewport.

## Image sizing across breakpoints

`Image('/hero.png').frame({ width: 320 })` emits `width: 320px` inline, which wins over CSS classes. For images that must respond to viewport, either:

1. Use `.frame({ width: responsive(280, 280, 320) })` to switch sizes per breakpoint.
2. Drop `.frame(...)` and use a CSS class — `.iphone-frame { width: var(--iphone-w); }` updates via media queries. Inline styles win over CSS, so omit `.frame()` if going this route.

## Parallax intensity per breakpoint

The 40vh parallax distance that feels cinematic on a 1440px display is **disorienting on a 375px phone**. Override the `@keyframes` per breakpoint in CSS:

```css
/* mobile default — gentle */
@keyframes parallax-zoom {
  from { transform: translateY(20vh) scale(0.92); opacity: 0.7; }
  to   { transform: translateY(0)    scale(1.00); opacity: 1.0; }
}

@media (min-width: 1024px) {
  @keyframes parallax-zoom {
    from { transform: translateY(40vh) scale(0.85); opacity: 0.6; }
    to   { transform: translateY(0)    scale(1.00); opacity: 1.0; }
  }
}
```

## `prefers-reduced-motion` — disable animations entirely

Required for accessibility. iOS users with "Reduce Motion" in Settings expect no parallax, no fade-up:

```css
@media (prefers-reduced-motion: reduce) {
  .reveal,
  .parallax-figure {
    animation: none !important;
    opacity: 1;
    transform: none;
  }
}
```

## Viewport meta in `index.html` — non-negotiable

```html
<meta name="viewport" content="width=device-width, initial-scale=1" />
```

Without this, mobile Safari renders the page at desktop width and zooms out. Every "broken on mobile" site you've ever seen missed this tag.

## Visibility helpers (use sparingly)

For chunks of UI that only make sense on one breakpoint:

```css
.mobile-only  { display: block; }
.tablet-up    { display: none; }
.desktop-only { display: none; }
@media (min-width: 768px)  { .mobile-only { display: none; } .tablet-up { display: block; } }
@media (min-width: 1024px) { .desktop-only { display: block; } }
```

Apply with `.modifier(cls('desktop-only'))`. Every duplicated UI doubles your maintenance burden — use rarely.

## Test viewports for self-review

Before suggesting `npm run serve`, mentally walk through:

| Viewport | What to verify |
|----------|----------------|
| **iPhone SE (375 × 667)** — smallest current device | Headline doesn't overflow; iPhone fits with margin; CTAs tappable (≥ 44pt); body reads naturally |
| **iPhone 16 Pro Max (430 × 932)** — common phone | Hero stacks cleanly; features stack; parallax gentle |
| **iPad Mini (768 × 1024)** — smallest tablet | Tablet rhythm; features as 2 columns; iPhone screenshots at 280px |
| **MacBook 14" (1512 × 982)** — common laptop | Desktop rhythm; features alternate L/R; parallax cinematic |
| **Wide (1920 × 1080)** | Body doesn't run wider than `--measure`; nothing centers awkwardly |

In dev: Safari's **Responsive Design Mode** (⌥⌘R) and Chrome DevTools device emulation catch ~90%. The last 10% only show on a real device — test on your actual phone before shipping.
