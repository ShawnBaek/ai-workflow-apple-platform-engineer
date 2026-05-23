// Section 1 — About / Hero
// All visual modifiers are real SwiftUI-For-Web (Font/Color/padding/frame/
// shadow/onTapGesture). CSS classes only for the .reveal scroll animation.

import { HStack, VStack, Image, Spacer } from 'swiftui-for-web';
import { display, lead } from './typography.js';
import { SPACING, cssColor } from './theme.js';
import { attrs, cls } from './helpers.js';

const APP_STORE_URL = 'https://apps.apple.com/app/idXXXXXXXXX';

export function HeroSection() {
  return HStack({ alignment: 'center', spacing: SPACING.s3 },
    VStack({ alignment: 'leading', spacing: SPACING.s2 },
      display('A journal that disappears the moment you stop writing.'),
      lead('A quiet journaling app for iPhone, iPad, Mac, and Apple Watch. No notifications, no streaks, no folders. Just write.'),
      AppStoreBadge()
    ).modifier(cls('hero-copy')),

    Spacer(),

    Image('https://placehold.co/640x1380/0a84ff/ffffff/png?text=Hero+iPhone&font=source-sans-pro')
      .frame({ width: 320 })
      .shadow({ y: 40, radius: 80, color: cssColor('--color-shadow') })
      .modifier(attrs({ alt: 'Notes Journal app open on the Today screen.' }))
  )
    .padding({ vertical: SPACING.s4, horizontal: SPACING.containerPx })
    .modifier(cls('row-wrap', 'reveal'));
}

function AppStoreBadge() {
  return Image('https://placehold.co/200x54/000000/ffffff/png?text=Download+on+the+App+Store&font=source-sans-pro')
    .frame({ height: 54 })
    .onTapGesture(() => window.open(APP_STORE_URL, '_blank', 'noopener,noreferrer'))
    .modifier(attrs({ alt: 'Download on the App Store', role: 'link', tabindex: '0' }));
}
