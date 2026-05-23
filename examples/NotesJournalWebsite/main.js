// Entry point — wires the five sections in canonical order.
// Aesthetic: developer.apple.com/swiftui + airbnb.com.
// Rhythm: every spacing token in styles/tokens.css.

import { App, VStack } from 'swiftui-for-web';

// DEMO: cache-buster query strings force a fresh fetch of each section module.
// Useful while iterating on the demo locally; remove these `?v=...` suffixes
// before shipping to GitHub Pages.
import { HeroSection }     from './sections/HeroSection.js?v=demo3';
import { FeaturesSection } from './sections/FeaturesSection.js?v=demo3';
import { ParallaxShowcase } from './sections/ParallaxShowcase.js?v=demo3';
import { DownloadSection } from './sections/DownloadSection.js?v=demo3';
import { ShareSection }    from './sections/ShareSection.js?v=demo3';

App(() =>
  // Outermost stack — no spacing here; each section owns its own vertical padding.
  VStack({ spacing: 0 },
    HeroSection(),
    FeaturesSection(),
    ParallaxShowcase(),
    DownloadSection(),
    ShareSection()
  )
).mount('#root');
