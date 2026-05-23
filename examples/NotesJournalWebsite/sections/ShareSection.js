// Section 5 — Share + footer
// Real .onTapGesture for every link/button. Hover underline via .share-link
// CSS class (the framework has no :hover modifier — that's CSS-only).

import { VStack, HStack } from 'swiftui-for-web';
import { h3, body, caption } from './typography.js';
import { SPACING } from './theme.js';
import { attrs, cls } from './helpers.js';

const SITE_URL = 'https://notesjournal.app';
const SHARE_TEXT = 'Just found this — a journal that disappears the moment you stop writing.';

export function ShareSection() {
  const url = encodeURIComponent(SITE_URL);
  const text = encodeURIComponent(SHARE_TEXT);

  return VStack({ alignment: 'center', spacing: SPACING.s2 },
    h3('Tell a friend.'),

    HStack({ alignment: 'center', spacing: SPACING.s2 },
      body('Share on X')
        .onTapGesture(() => window.open(`https://x.com/intent/post?text=${text}&url=${url}`, '_blank', 'noopener,noreferrer'))
        .modifier(cls('share-link'))
        .modifier(attrs({ role: 'link', tabindex: '0' })),
      body('Share on Threads')
        .onTapGesture(() => window.open(`https://www.threads.net/intent/post?text=${text}%20${url}`, '_blank', 'noopener,noreferrer'))
        .modifier(cls('share-link'))
        .modifier(attrs({ role: 'link', tabindex: '0' })),
      body('Share on Mastodon')
        .onTapGesture(() => window.open(`https://mastodon.social/share?text=${text}%20${url}`, '_blank', 'noopener,noreferrer'))
        .modifier(cls('share-link'))
        .modifier(attrs({ role: 'link', tabindex: '0' })),
      body('Copy link')
        .onTapGesture(() => navigator.clipboard.writeText(SITE_URL))
        .modifier(cls('share-link'))
        .modifier(attrs({ role: 'button', tabindex: '0' }))
    ).modifier(cls('row-wrap')),

    caption('© 2026 Shawn Baek · hi@notesjournal.app · Privacy'),

    // Mandatory framework credit. .onTapGesture is real SwiftUI-For-Web.
    caption('Made with SwiftUI-For-Web ↗')
      .onTapGesture(() => window.open('https://github.com/ShawnBaek/SwiftUI-For-Web', '_blank', 'noopener,noreferrer'))
      .modifier(cls('made-with'))
      .modifier(attrs({ role: 'link', tabindex: '0' }))
  ).padding({ top: SPACING.s3, bottom: SPACING.s4, left: SPACING.containerPx, right: SPACING.containerPx });
}
