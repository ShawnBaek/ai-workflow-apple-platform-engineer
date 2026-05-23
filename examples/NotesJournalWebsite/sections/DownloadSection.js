// Section 4 — Download
// All real modifiers — onTapGesture, padding, frame.

import { VStack, Image } from 'swiftui-for-web';
import { h2, caption } from './typography.js';
import { SPACING } from './theme.js';
import { attrs, cls } from './helpers.js';

const APP_STORE_URL = 'https://apps.apple.com/app/idXXXXXXXXX';

export function DownloadSection() {
  return VStack({ alignment: 'center', spacing: SPACING.s2 },
    h2('Available now.'),

    Image('https://placehold.co/200x54/000000/ffffff/png?text=Download+on+the+App+Store&font=source-sans-pro')
      .frame({ height: 54 })
      .onTapGesture(() => window.open(APP_STORE_URL, '_blank', 'noopener,noreferrer'))
      .modifier(attrs({ alt: 'Download on the App Store', role: 'link', tabindex: '0' })),

    caption('Requires iOS 26, iPadOS 26, macOS 26, or watchOS 26 or later.')
  )
    .padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx })
    .modifier(cls('reveal'));
}
