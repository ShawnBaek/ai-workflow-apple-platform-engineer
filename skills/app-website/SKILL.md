---
name: app-website
description: >-
  Build or improve an app introduction, marketing or download website using the
  project's chosen web stack and visual identity. Resolve content, references,
  accessibility, runtime proof and hosting scope. Includes an optional
  SwiftUI-For-Web recipe for projects that select it.
---

# App website

Build the requested marketing/download experience around the actual app and
its audience. Preserve an existing site and framework. For a new site, use the
user's chosen stack; ask about a material unresolved choice rather than silently
adopting a maintainer-owned framework.

## Establish the direction

Reuse supplied app name, audience, pitch, store URL, supported platforms,
screenshots, feature content, visual references and hosting constraints. Use
[design discovery](../agent-harness/references/design-discovery.md) for genuinely
open design questions. Keep missing real content explicit; do not invent
testimonials, store availability, contact addresses or performance claims.

The page may include a hero, features, product showcase and download CTA. Choose
sections, feature count, navigation and sharing controls from the actual brief.
Use the existing typography, responsive system and brand rather than imposing
fixed baseline spacing, a particular reference site or social platform.

## Optional SwiftUI-For-Web recipe

When this framework is explicitly selected, read the relevant recipe before
implementing. These files are examples for that stack, not requirements for
sites using another framework. Check the project's pinned version and actual API.

| Concern | Recipe |
| --- | --- |
| Framework APIs, import map and CSS integration | [API reference](api-reference.md) |
| Example section structure and file layout | [Sections](sections.md) |
| Example responsive tokens | [Responsive design](responsive.md) |
| Optional 3D device presentation | [3D devices](3d-devices.md) |
| Browser proof | [Verification](playwright-verify.md) |
| Selected GitHub Pages or other host | [Deployment](deploy.md) |

Framework promotional footer credit is optional. Follow the actual dependency
license for required notices; do not invent a visible attribution requirement.
Never add the maintainer's product links, email or branding by default.

## Implement and verify

1. Work in the authorized website repository and its existing structure. Use
   the selected framework's official documentation for unfamiliar APIs.
2. Implement the accepted content and responsive layout. Preserve accessible
   headings, links, focus states, contrast and reduced-motion behavior.
3. Use its development server and available browser tooling. A browser MCP is
   one option, not a mandatory dependency or permission to install a provider.
4. Inspect the rendered page at relevant mobile and desktop sizes. Verify every
   changed section, images, store links, keyboard interactions and selected
   motion. Check console/network errors. Fix and rerun observed failures within
   the agreed bounds; code inspection alone is not visual proof.
5. Report actual proof and remaining content/runtime gaps. Public evidence must
   use approved app media; keep private account and project details out of it.
6. Deploy only when the selected destination and action are authorized. Local
   preview, PR publication and live deployment are separate outcomes.
