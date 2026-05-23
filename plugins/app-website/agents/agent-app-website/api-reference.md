# SwiftUI-For-Web API — verified surface

What actually exists, what doesn't, and the canonical helper modules. Verified by reading https://github.com/ShawnBaek/SwiftUI-For-Web/blob/main/src/Core/View.js and the framework's own [AGENTS.md](https://github.com/ShawnBaek/SwiftUI-For-Web/blob/main/AGENTS.md).

## Real chainable modifiers

Use these freely:

- `.padding(value)` — number, or `{ top, right, bottom, left, horizontal, vertical }`. **Numbers in pixels**, not CSS var strings.
- `.frame(options)` — `{ width, height, minWidth, maxWidth, minHeight, maxHeight }`. Numbers, not strings.
- `.foregroundColor(color)` — requires a `Color.*` instance. `Color.blue`, `Color.primary`, `Color.rgb(0,0,0)`, `Color.hex('#FF0000')`. To use CSS variables (for dark mode), wrap with `cssColor('--var-name')` from `theme.js`.
- `.background(color)` — same shape.
- `.font(font)` — requires a `Font.*` instance. `Font.system(80, '700')`. Font.system does NOT set line-height — apply via the typography.js factories below.
- `.opacity(value)`, `.cornerRadius(radius)`, `.border(color, width)`, `.shadow(options)`.
  - `.shadow({ color, radius, x, y })` — note SwiftUI-style: `radius` = blur radius.
- `.onTapGesture(handler)` — real click handler via event delegation. **Use this for external links** — no `Link` component exists.
- `.onAppear(handler)`, `.onDisappear(handler)`.
- `.clipShape(shape)`, `.id(key)`, `.tabItem(builder)`, `.tag(value)`.
- `.modifier(mod)` — the escape hatch. Accepts `{ apply(element) { … } }`. Use for HTML attributes (alt, aria, loading) and CSS class names.

## Things that DO NOT exist (do not invent them)

| Tempting fake | Why you'd reach for it | Real solution |
|--------------|------------------------|---------------|
| `Link({ href }, child)` | external URLs | `.onTapGesture(() => window.open(url, '_blank', 'noopener,noreferrer'))` |
| `.className('foo')` | apply CSS classes | `.modifier(cls('foo'))` (only for hover / animation hooks) |
| `.style({ ... })` | inline CSS | mostly unnecessary — use `.padding`, `.frame`, `.foregroundColor` etc. For line-height + letter-spacing only, see typography.js |
| `.ariaLabel('...')` / `.alt('...')` | a11y attributes | `.modifier(attrs({ 'aria-label': '...', alt: '...' }))` |
| `.loading('lazy')` | image lazy-load attr | `.modifier(attrs({ loading: 'lazy' }))` |
| `HStack({ wrap: true })` | row wraps on mobile | `.modifier(cls('row-wrap'))`; CSS has `flex-wrap: wrap` |
| Plain pixel numbers in `.padding(120)` | responsive spacing | use `SPACING.s4` from `theme.js` — returns the right pixel value per viewport |
| `Font.custom('size/line-height')` | inline font + line-height | `Font.system(size, weight)` for size+weight; line-height via the `extra({ lineHeight: ... })` modifier in typography.js |
| `Color.label` reacts to dark mode | dark mode color | `Color.label` is static `rgb(0,0,0)`. Use `cssColor('--color-label')` so CSS variables cascade |

## Prefer real modifiers — but CSS3 is officially in the stack

The framework's own [AGENTS.md](https://github.com/ShawnBaek/SwiftUI-For-Web/blob/main/AGENTS.md) declares the stack as **"Pure ES modules + CSS3 + HTML5"** — CSS is a first-class citizen, not a fallback. Don't feel bad reaching for it.

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
    "swiftui-for-web": "https://cdn.jsdelivr.net/gh/ShawnBaek/SwiftUI-For-Web@main/src/index.js"
  }
}
</script>
```

For production, pin to a specific commit SHA instead of `@main` so you don't get surprised by upstream changes:

```json
"swiftui-for-web": "https://cdn.jsdelivr.net/gh/ShawnBaek/SwiftUI-For-Web@<sha>/src/index.js"
```

`file://` blocks ES modules entirely. The page **will be blank** if the developer opens `index.html` directly. Always use `python3 -m http.server 8000` or `npx serve`.

## The mandatory module set you ship in every project

Three files. Together they keep the SwiftUI-For-Web API natural without losing CSS-only features.

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

Narrow escape hatch — only for HTML attrs + animation/hover class hooks + the `modelViewer` 3D embed.

```javascript
export const attrs = (map) => ({
  apply(el) { for (const [k, v] of Object.entries(map)) if (v != null) el.setAttribute(k, String(v)); }
});

export const cls = (...names) => ({
  apply(el) { for (const n of names) if (n) el.classList.add(n); }
});

// See 3d-devices.md for the modelViewer helper.
```

## Trade-off: click-handler "links" vs real `<a href>`

`.onTapGesture(() => window.open(url))` is a click handler, not a real `<a href>`. Search bots that don't run JS won't see the destination. For an App Store badge or share button, that's fine — bots index the page itself, not its outbound links. For an SEO-critical destination (a "Pricing" page, "Read the docs" CTA), drop into a raw `<a>` in `index.html` instead. State the trade-off when the developer asks why their landing page doesn't rank for the page it links to.
