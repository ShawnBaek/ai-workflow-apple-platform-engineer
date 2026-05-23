// Section 2 — Key Features
// Real .padding, .frame, .shadow modifiers. CSS only for .reveal + .row-wrap.

import { VStack, HStack, Image, Spacer } from 'swiftui-for-web';
import { h2, body } from './typography.js';
import { SPACING, cssColor } from './theme.js';
import { attrs, cls } from './helpers.js';

const features = [
  {
    title: 'Just write.',
    body: 'Open the app, type. No format menus, no folders, no organization theater.',
    screenshot: 'https://placehold.co/640x1380/1d1d1f/ffffff/png?text=Just+write&font=source-sans-pro',
    alt: 'A blank note ready for writing.'
  },
  {
    title: 'Quiet by default.',
    body: 'No notifications, no badges, no streaks. The app exists for the 90 seconds you use it.',
    screenshot: 'https://placehold.co/640x1380/f5f5f7/1d1d1f/png?text=Quiet+by+default&font=source-sans-pro',
    alt: 'Settings screen showing notifications turned off.'
  },
  {
    title: 'Everywhere you are.',
    body: 'iPhone, iPad, Mac, Apple Watch. Same journal, same words, instantly synced.',
    screenshot: 'https://placehold.co/640x1380/34c759/ffffff/png?text=Everywhere+you+are&font=source-sans-pro',
    alt: 'The journal mirrored across four Apple devices.'
  }
];

export function FeaturesSection() {
  return VStack(
    ...features.map((feature, index) =>
      FeatureRow({ ...feature, side: index % 2 === 0 ? 'left' : 'right' })
    )
  );
}

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
