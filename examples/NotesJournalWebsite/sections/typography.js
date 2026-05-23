// typography.js — factory functions that return Text with the right
// font, color, line-height, and letter-spacing for each role.
//
// Each factory uses real SwiftUI-For-Web modifiers (.font, .foregroundColor)
// + one tiny `.modifier()` escape for line-height + letter-spacing (which
// Font.system() doesn't model).

import { Text, Font } from 'swiftui-for-web';
import { cssColor, TYPE } from './theme.js';

// Inline style helper — the only escape hatch we still need, for line-height
// and letter-spacing (Font doesn't model either).
const extra = (styles) => ({
  apply(el) { Object.assign(el.style, styles); }
});

export const display = (text) =>
  Text(text)
    .font(Font.system(TYPE.display.size, '700'))
    .foregroundColor(cssColor('--color-label'))
    .modifier(extra({
      lineHeight: TYPE.display.lh + 'px',
      letterSpacing: '-0.022em'
    }));

export const h1 = (text) =>
  Text(text)
    .font(Font.system(TYPE.h1.size, '600'))
    .foregroundColor(cssColor('--color-label'))
    .modifier(extra({
      lineHeight: TYPE.h1.lh + 'px',
      letterSpacing: '-0.020em'
    }));

export const h2 = (text) =>
  Text(text)
    .font(Font.system(TYPE.h2.size, '600'))
    .foregroundColor(cssColor('--color-label'))
    .modifier(extra({
      lineHeight: TYPE.h2.lh + 'px',
      letterSpacing: '-0.018em'
    }));

export const h3 = (text) =>
  Text(text)
    .font(Font.system(TYPE.h3.size, '600'))
    .foregroundColor(cssColor('--color-label'))
    .modifier(extra({
      lineHeight: TYPE.h3.lh + 'px',
      letterSpacing: '-0.015em'
    }));

export const lead = (text) =>
  Text(text)
    .font(Font.system(TYPE.lead.size, '400'))
    .foregroundColor(cssColor('--color-secondary-label'))
    .modifier(extra({
      lineHeight: TYPE.lead.lh + 'px',
      maxWidth: '38em'
    }));

export const body = (text) =>
  Text(text)
    .font(Font.system(TYPE.body.size, '400'))
    .foregroundColor(cssColor('--color-label'))
    .modifier(extra({
      lineHeight: TYPE.body.lh + 'px',
      maxWidth: '38em'
    }));

export const caption = (text) =>
  Text(text)
    .font(Font.system(TYPE.body.size, '400'))
    .foregroundColor(cssColor('--color-tertiary-label'))
    .modifier(extra({ lineHeight: TYPE.body.lh + 'px' }));
