# SwiftUI-For-Web API — verified surface

Scope: optional SwiftUI-For-Web recipe, used only when selected by the project.
Adapt example layout, tokens, sections and hosting to the accepted brief.


What actually exists, what doesn't, and the canonical helper modules. Verified by reading https://github.com/ShawnBaek/SwiftUI-For-Web/blob/19621bbe6be374c5060590c2cb5bdf5c7ee357e3/src/Core/View.js and the framework's own [AGENTS.md](https://github.com/ShawnBaek/SwiftUI-For-Web/blob/19621bbe6be374c5060590c2cb5bdf5c7ee357e3/AGENTS.md) at the pinned commit (see the importmap below).

## Real chainable modifiers

Use these freely:

- `.padding(value)` — number, or `{ top, right, bottom, left, horizontal, vertical }`. **Numbers in pixels**, not CSS var strings.
- `.frame(options)` — `{ width, height, minWidth, maxWidth, minHeight, maxHeight }`. Numbers, not strings.
- `.foregroundColor(color)` — requires a `Color.*` instance. `Color.blue`, `Color.primary`, `Color.rgb(0,0,0)`, `Color.hex('#FF0000')`. To use CSS variables (for dark mode), wrap with `cssColor('--var-name')` from `theme.js`.
- `.background(color)` — same shape.
- `.font(font)` — requires a `Font.*` instance. `Font.system(80, '700')`. Font.system does NOT set line-height — apply via the typography.js factories below.
- `.opacity(value)`, `.cornerRadius(radius)`, `.border(color, width)`, `.shadow(options)`.
  - `.shadow({ color, radius, x, y })` — note SwiftUI-style: `radius` = blur radius.
- `.onTapGesture(handler)` — a delegated `click` listener only; it adds no role, focus or Enter/Space handling. **Don't use it for links or buttons**: use `externalLink` from `helpers.js` for external URLs and `Button(label, action)` (a native `<button>`) for actions.
- `.onAppear(handler)`, `.onDisappear(handler)`.
- `.clipShape(shape)`, `.id(key)`, `.tabItem(builder)`, `.tag(value)`.
- `.modifier(mod)` — the escape hatch. Accepts `{ apply(element) { … } }`. Use for HTML attributes (alt, aria, loading) and CSS class names.

## Things that DO NOT exist (do not invent them)

| Tempting fake | Why you'd reach for it | Real solution |
|--------------|------------------------|---------------|
| `Link({ href }, child)` | external URLs | `HStack().modifier(externalLink(url, content))` — a real `<a target="_blank" rel="noopener noreferrer">`. `NavigationLink` is in-app navigation, not an anchor |
| `.className('foo')` | apply CSS classes | `.modifier(cls('foo'))` (only for hover / animation hooks) |
| `.style({ ... })` | inline CSS | mostly unnecessary — use `.padding`, `.frame`, `.foregroundColor` etc. For line-height + letter-spacing only, see typography.js |
| `.ariaLabel('...')` / `.alt('...')` | a11y attributes | `.modifier(attrs({ 'aria-label': '...', alt: '...' }))`, or the real `.accessibilityLabel('...')` (sets `aria-label`; on `Image` it sets `alt`) |
| `.loading('lazy')` | image lazy-load attr | `.modifier(attrs({ loading: 'lazy' }))` |
| `HStack({ wrap: true })` | row wraps on mobile | `.modifier(cls('row-wrap'))`; CSS has `flex-wrap: wrap` |
| Plain pixel numbers in `.padding(120)` | responsive spacing | use `SPACING.s4` from `theme.js` — returns the right pixel value per viewport |
| `Font.custom('size/line-height')` | inline font + line-height | `Font.system(size, weight)` for size+weight; line-height via the `extra({ lineHeight: ... })` modifier in typography.js |
| `Color.label` reacts to dark mode | dark mode color | `Color.label` is static `rgb(0,0,0)`. Use `cssColor('--color-label')` so CSS variables cascade |

## Prefer real modifiers — but CSS3 is officially in the stack

The framework's own [AGENTS.md](https://github.com/ShawnBaek/SwiftUI-For-Web/blob/19621bbe6be374c5060590c2cb5bdf5c7ee357e3/AGENTS.md) declares the stack as **"Pure ES modules + CSS3 + HTML5"** — CSS is a first-class citizen, not a fallback. Don't feel bad reaching for it.

That said: when SwiftUI-For-Web *does* expose a modifier for what you want — prefer it over `.modifier(cls('foo'))` + a CSS class. The code reads more naturally for someone fluent in SwiftUI, which is the framework's whole reason to exist.

**Real modifiers cover:** typography, spacing, colors, shadows, frame sizes, tap actions.

**CSS earns its keep for:**
- Dark mode color tokens via `prefers-color-scheme` cascading
- `:hover` and `:focus` states (no `.onHover` modifier)
- Scroll-driven animations (`animation-timeline: view()` is CSS-only)
- `.row-wrap` helper (HStack has no `wrap` prop)
- `prefers-reduced-motion` override

## Loading SwiftUI-For-Web — the importmap requirement

Bare specifiers like `import { App } from 'swiftui-for-web'` do not resolve in a browser without an importmap or a bundler. SwiftUI-For-Web's README example uses `./src/index.js` because it runs inside the repo. External sites need this in `index.html`, **before any module script**:

```html
<script type="importmap">
{
  "imports": {
    "swiftui-for-web": "https://cdn.jsdelivr.net/gh/ShawnBaek/SwiftUI-For-Web@19621bbe6be374c5060590c2cb5bdf5c7ee357e3/src/index.js"
  }
}
</script>
```

Pin a commit SHA, never `@main`: a branch URL serves whatever upstream pushes next. The SHA above is `main` on 2026-08-03 (2.0.0-alpha.1), the version this recipe's link and button behavior was checked against. To update, review the upstream changes, get the new SHA with `gh api repos/ShawnBaek/SwiftUI-For-Web/commits/main --jq .sha`, and rerun the browser verification.

`file://` blocks ES modules entirely. The page **will be blank** if the developer opens `index.html` directly. Use the project's existing development server or `npx serve` over HTTP.

## Suggested helper modules

Three files. Together they keep the SwiftUI-For-Web API natural without losing CSS-only features. Adapt or replace them to fit the project.

### `sections/theme.js`

```javascript
export const cssColor = (cssVarName) => ({
  rgba: () => `var(${cssVarName})`
});

export const responsive = (mobile, tablet, desktop) => {
  const w = typeof window !== 'undefined' ? window.innerWidth : 1280;
  return w >= 1024 ? desktop : w >= 768 ? tablet : mobile;
};

export const SPACING = {
  s1: responsive(12, 13.5, 15),
  s2: responsive(24, 27, 30),
  s3: responsive(48, 54, 60),
  s4: responsive(72, 81, 120),
  s5: responsive(144, 162, 240),
  containerPx: responsive(20, 40, 60),
};

export const TYPE = {
  body:    { size: responsive(16,    18,    20),    lh: responsive(24,  27,  30)  },
  lead:    { size: responsive(18.96, 21.49, 24),    lh: responsive(24,  27,  30)  },
  h3:      { size: responsive(22.78, 25.46, 28.28), lh: responsive(24,  27,  30)  },
  h2:      { size: responsive(28.43, 36,    40),    lh: responsive(48,  54,  60)  },
  h1:      { size: responsive(37.90, 50.91, 56.57), lh: responsive(48,  54,  60)  },
  display: { size: responsive(50.52, 72,    80),    lh: responsive(72, 108, 120)  },
};
```

### `sections/typography.js`

```javascript
import { Text, Font } from 'swiftui-for-web';
import { cssColor, TYPE } from './theme.js';

const extra = (s) => ({ apply(el) { Object.assign(el.style, s); } });

export const display = (text) =>
  Text(text)
    .font(Font.system(TYPE.display.size, '700'))
    .foregroundColor(cssColor('--color-label'))
    .modifier(extra({
      lineHeight: TYPE.display.lh + 'px',
      letterSpacing: '-0.022em'
    }));

// h1, h2, h3, lead, body, caption follow the same shape — see
// the reference site for the full file.
```

### `sections/helpers.js`

Narrow escape hatch — only for HTML attrs + animation/hover class hooks + `externalLink` anchors + the `modelViewer` 3D embed.

```javascript
export const attrs = (map) => ({
  apply(el) { for (const [k, v] of Object.entries(map)) if (v != null) el.setAttribute(k, String(v)); }
});

export const cls = (...names) => ({
  apply(el) { for (const n of names) if (n) el.classList.add(n); }
});

// Real <a> for external destinations: Tab + Enter, middle-click, "open in new
// tab" and crawlers work. `content` is link text, or { src, alt, height } for an
// image link whose alt is its accessible name. Attach to an empty stack.
export const externalLink = (href, content, className) => ({
  apply(el) {
    const a = document.createElement('a');
    a.href = href;
    a.target = '_blank';
    a.rel = 'noopener noreferrer';
    if (className) a.className = className;
    if (typeof content === 'string') {
      a.textContent = content;
    } else {
      const img = document.createElement('img');
      img.src = content.src;
      img.alt = content.alt;
      // Inline style, so a reset's img { height: auto } can't shrink it.
      if (content.height) img.style.height = content.height + 'px';
      a.appendChild(img);
    }
    el.appendChild(a);
  }
});

// See 3d-devices.md for the modelViewer helper.
```

## External links are real `<a href>` elements

A click handler that calls `window.open(url)` is not a link. Enter doesn't activate it, middle-click and "open in new tab" do nothing, and crawlers don't see the destination. Adding `role="link"` and `tabindex="0"` only makes it focusable; the page would still need its own Enter handling ([MDN: ARIA link role](https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/link_role)). Use `externalLink` for the App Store badge, share links and credits. `externalLink` builds its anchor in JavaScript, so put a destination that must exist without JS, such as an SEO-critical "Pricing" or "Read the docs" link, as static `<a>` markup in `index.html`.
