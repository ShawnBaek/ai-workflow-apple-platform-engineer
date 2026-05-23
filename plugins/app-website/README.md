# app-website

Builds the **one-page app introduction website** for an indie native app — the marketing/download page you link from the App Store, social posts, and TestFlight invites.

Forces use of [SwiftUI-For-Web](https://github.com/ShawnBaek/SwiftUI-For-Web) so the website code reads like the app's SwiftUI codebase. Applies [Gridlover](https://www.gridlover.net/)-style vertical rhythm so every spacing decision snaps to a baseline grid.

Aesthetic anchored on **[developer.apple.com/swiftui](https://developer.apple.com/swiftui/)** and **[airbnb.com](https://www.airbnb.com)** — typography-first, generous whitespace, iPhone-framed screenshots, one parallax moment that earns its scroll.

## What it does

**Verifies its own output in a real browser — visually AND functionally.** Web changes are never declared "done" without:

1. Loading the page via Playwright / Chrome MCP in a fresh tab.
2. Reading the console for errors.
3. **Confirming every `<img>` actually loaded** (`naturalWidth > 0` via `javascript_tool`) — a 200 + clean console isn't enough; an image with a 404 src is silently broken.
4. **Scrolling through every section** (not stopping at the hero — section 4 might be missing).
5. **Exercising every interactive element** (App Store badge click, copy-link, share buttons).
6. **Only then** showing the developer the URL.

Module resolution errors, missing exports, 404s, CSS specificity, and aggressive browser caching all bite at runtime — the agent ships with patterns for each (no-cache dev server, cache-buster on `<script src="./main.js?v=N">`, importmap-before-modules, close-and-reopen-tab when modules don't update).

Generates a complete one-page site with 5 sections in canonical order:

1. **About / Hero** — display headline, lead paragraph, App Store badge, hero visual (iPhone-framed screenshot or short autoplay video)
2. **Key Features** — exactly 3 features, each as an iPhone-framed screenshot + tight title + one-sentence body, alternating left/right
3. **Parallax showcase** — one cinematic moment (sticky section, scroll-driven transform, or `<model-viewer>` 3D), Apple-style
4. **Download** — Apple's official App Store SVG badge + system requirements line, no email capture
5. **Share** — X / Threads / Mastodon share-intent links + copy-link button, no third-party widgets

Plus:
- **Vertical rhythm tokens** in `:root` CSS variables — Gridlover-generated at base 20px / line-height 1.5 / scale √2, with a 30px baseline grid
- **Typography rules** — one typeface (system stack), one weight per role, max measure 60–80 chars
- **Animation rules** — reveal-on-scroll per section, hover scale on the badge, no looping decorative motion
- **Performance budget** — ≤ 1.5 MB total, Lighthouse ≥ 95, lazy-load below the fold
- **Responsive design** — mobile / tablet / desktop via three breakpoint-stepped rhythm scales (24px / 27px / 30px baseline), not fluid `clamp()`. Each breakpoint keeps Gridlover's rhythm intact. `HStack({ wrap: true })` collapses to columns on narrow viewports. Parallax intensity reduces on mobile. `prefers-reduced-motion` disables all motion. Self-review against 375px / 768px / 1024px / 1920px viewports before shipping.
- **Deploy to GitHub Pages** — push to main → live in a minute. Custom domain (`yourapp.com`) with the exact `CNAME` file + DNS A/AAAA/CNAME records to set at your registrar. HTTPS via Let's Encrypt, automatic. Common deploy gotchas table (relative paths, DNS propagation, HTTPS toggle locked, SPA-route 404s).
- **Real SwiftUI-For-Web API knowledge.** The agent knows which modifiers actually exist (`.padding`, `.frame`, `.foregroundColor`, `.background`, `.font`, `.shadow`, `.onTapGesture`, `.modifier`) and which are tempting fakes (`Link`, `.className`, `.style`, `.ariaLabel`, `HStack({wrap: true})`). Ships a `helpers.js` with escape-hatch utilities (`cls`, `attrs`, `inlineStyle`, `openOnTap`, `copyOnTap`) so section code stays readable.
- **Importmap setup** — knows bare specifiers won't resolve without it; ships the jsdelivr/GitHub CDN line in `index.html`.
- **Playwright MCP install per host** — `claude mcp add playwright npx @playwright/mcp@latest` for Claude Code, `code --add-mcp '{…}'` for VS Code, MCP JSON snippet for Codex. Plus the `npx playwright init-agents --loop=<host>` test-agent bootstrap.
- **"Made with SwiftUI-For-Web ↗" footer credit** — small, low-key, links back to the framework repo. The agent adds it to every site automatically (the same way GitHub-Pages or Cloudflare-Pages sites credit the platform). Pays back the framework and helps other indie devs discover it.
- **3D Apple device showcases via `<model-viewer>`** — optional path for the parallax section. Spinnable iPhone / iPad / MacBook / Apple Watch with iOS AR Quick Look on tap. Sourced from the [archive.org Apple AR Products collection](https://archive.org/details/21-10-24-ar-products) (87 official Apple USDZ files), Sketchfab (GLB), and 3DModels.org. Ships a `modelViewer()` helper, performance budget per device, and "skip 3D" criteria.
- **Reads the framework's own [AGENTS.md](https://github.com/ShawnBaek/SwiftUI-For-Web/blob/main/AGENTS.md)** — respects SwiftUI-For-Web's own contract: zero dependencies, SwiftUI API parity, no invented components, CSS3 + HTML5 + ES modules as the official stack.

## What it deliberately doesn't do

- Use plain HTML, JSX, Svelte, or any framework other than SwiftUI-For-Web.
- Use Bootstrap or Tailwind utility soup.
- Add nav bars, hamburger menus, or anything that hints at a multi-page site.
- Add email capture, chat widgets, or cookie banners (unless EU forces one).
- Include more than 3 features or more than one parallax section.
- Use a custom display font the developer hasn't licensed.
- Skip the rhythm tokens — every spacing decision goes through them.

## When to use

- "Build me a landing page for my app."
- "I need a download page — App Store link, three screenshots, share buttons."
- "Make me a one-pager like Apple's SwiftUI page but for my app."
- "Build the marketing site I'll link from my TestFlight invite."
- "Deploy the site to GitHub Pages and wire up `myapp.com`."
- "The site looks broken on mobile — fix the responsive layout."

## See it in action

[`examples/NotesJournalWebsite/`](../../examples/NotesJournalWebsite/) — a complete buildable one-pager generated by this agent, marketing the [`NotesJournal`](../../examples/NotesJournal/) example app. All 5 sections, Gridlover-style `tokens.css`, system font stack, declarative scroll-driven reveal + parallax. No binaries shipped (see its [assets/README](../../examples/NotesJournalWebsite/assets/README.md) for what files to drop in).

## Prerequisites

- **Node.js** for `npm install swiftui-for-web` (or use the GitHub install).
- **iPhone-framed screenshots** — get the bezel PNGs from https://developer.apple.com/design/resources/ and composite in GIMP/Photopea. Or pipe captures from the `screenshot` agent through framing.
- **App Store badge SVG** from https://tools.applemediaservices.com/app-store/.
- Optional: **GLB/USDZ model** for the parallax 3D path (via `<model-viewer>`).

## The hard constraints

Three things the agent never compromises on, because you (the developer) chose them:

| Constraint | What | Where |
|------------|------|-------|
| **Stack** | SwiftUI-For-Web only | https://github.com/ShawnBaek/SwiftUI-For-Web |
| **Rhythm** | Gridlover-style vertical rhythm via `--space-*` and `--fs-*` tokens | https://www.gridlover.net |
| **Aesthetic** | Apple SwiftUI page + Airbnb | https://developer.apple.com/swiftui · https://airbnb.com |

If you ask the agent for a Bootstrap-style SaaS landing page, it will redirect you to the references first.

## File layout it generates

```
my-app-website/
├── index.html                # tiny shell, mounts #root
├── main.js                   # SwiftUI-For-Web entry, imports sections
├── sections/
│   ├── HeroSection.js
│   ├── FeaturesSection.js
│   ├── ParallaxShowcase.js
│   ├── DownloadSection.js
│   └── ShareSection.js
├── styles/
│   ├── tokens.css            # :root vertical-rhythm variables
│   └── reset.css
├── assets/
│   ├── hero-iphone.png
│   ├── feature-1.png
│   ├── feature-2.png
│   ├── feature-3.png
│   ├── timeline.png          # parallax showcase image
│   └── app-store-badge.svg
└── package.json
```

## Install

```bash
npx claude-plugins install @shawnbaek/agent-design/app-website
```

Requires Claude Code v2.0.12+. Or interactively inside Claude Code:

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install app-website@indie-native-app
```

## References

- **SwiftUI-For-Web** → https://github.com/ShawnBaek/SwiftUI-For-Web (the mandatory stack)
- **Gridlover** → https://www.gridlover.net (vertical rhythm generator)
- **shawnbaek-WPTheme** → https://github.com/ShawnBaek/shawnbaek-WPTheme (the rhythm approach reference)
- **Apple SwiftUI page** → https://developer.apple.com/swiftui/ (aesthetic anchor)
- **Apple Design Resources** → https://developer.apple.com/design/resources/ (iPhone bezel PNGs)
- **App Store badges** → https://tools.applemediaservices.com/app-store/
- **`<model-viewer>`** → https://modelviewer.dev (3D embed for parallax)

## Companion agents in this marketplace

- [`apple-platform-ui`](../apple-platform-ui/README.md) — builds the app the website markets.
- [`screenshot`](../screenshot/README.md) — captures the screens you'll iPhone-frame for the Features section.
- [`app-store-connect`](../app-store-connect/README.md) — owns the App Store URL you link from the Download badge.
- [`commit-message`](../commit-message/README.md) — for the inevitable "fix(website): tighten hero copy" commits.
