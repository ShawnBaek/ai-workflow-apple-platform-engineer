# App launch screen — Apple's #1 misunderstood UI

The launch screen is the first frame the user sees while iOS loads your app's process. It is **not** a splash screen, **not** an ad, **not** a place for your logo.

**Apple's HIG rule (paraphrased):** the launch screen should look like the first frame of your app. Empty navigation bar, empty tab bar, empty content area — the user feels the app loaded instantly because the chrome was "already there."

## What does NOT belong on a launch screen

- Your logo or brand mark
- Text ("Welcome to MyApp", version numbers, taglines)
- A splash illustration that disappears
- A loading spinner
- Any animation
- Anything that suggests work is happening

## What does belong

- The same background color as your app's main screen
- The same navigation bar / tab bar skeleton (without titles, without buttons)
- An empty list / grid placeholder area

This makes launch feel instant — the user perceives the launch screen *as* the first screen.

## How to wire it

Use the **`UILaunchScreen` Info.plist dictionary**. No storyboard, no nib, no code.

Add to `Info.plist`:

```xml
<key>UILaunchScreen</key>
<dict>
    <key>UIColorName</key>
    <string>LaunchBackground</string>
    <key>UINavigationBar</key>
    <dict/>
    <key>UITabBar</key>
    <dict/>
</dict>
```

Define `LaunchBackground` in your asset catalog with **Any Appearance + Dark Appearance** colors so the launch screen matches the user's mode. Use the same color as your app's main background (`Color(.systemBackground)` equivalent).

For SwiftUI multiplatform projects, the `UILaunchScreen` dict lives in target build settings under **Info → Custom iOS Target Properties**.

### Optional: a single centered brand image (`UIImageName`)

HIG-strict reading: don't. The launch screen should *feel like* the first frame, not a splash.

Real-world: many shipped apps include a small centered logo via the `UIImageName` key, and App Review accepts it as long as it isn't a full-screen splash with text. The `UILaunchScreen` API supports exactly one image — no text, no animation.

```xml
<key>UILaunchScreen</key>
<dict>
    <key>UIColorName</key><string>LaunchBackground</string>
    <key>UIImageName</key><string>LaunchLogo</string>
    <key>UIImageRespectsSafeAreaInsets</key><true/>
    <key>UINavigationBar</key><dict/>
    <key>UITabBar</key><dict/>
</dict>
```

The image asset lives in `Assets.xcassets/LaunchLogo.imageset/` with `@1x`, `@2x`, `@3x` PNGs. Typical centered-logo sizes: 120 / 240 / 360 px (≈ 120 pt square). Downscale from the existing 1024 marketing icon with `sips -Z 120 marketing/AppIcon-1024.png --out ...`. Use a flat PNG without iOS's rounded-corner mask — iOS does not apply the icon mask to launch images.

When to use the image variant:
- The developer asks for it explicitly ("isn't there usually a logo?").
- The app's first real frame still takes > 200ms to be useful (download-gated apps, big ML model load) — the logo gives the user something to look at instead of a blank colored rectangle.

When to skip it:
- The app's first frame paints instantly (cached UI, no required network/ML on first frame). The HIG-strict version feels faster.

### What you can't do with `UILaunchScreen`

- Custom text labels.
- Multiple images.
- Vector / SVG sources (use PNG).
- Any layout other than "image centered with safe-area respect."

For any of those, you have to switch to a `LaunchScreen.storyboard` (older approach). Don't — the constraints above are the cost of the simpler API and almost every indie app accepts them.

## macOS / watchOS

- **macOS:** no launch screen concept. The window appears when ready; keep `App.init()` fast (see the `apple-platform-performance` skill, Item 18).
- **watchOS:** uses an "Asset Catalog Launch Image" — typically a solid color matching the app. No text, no logo.

## Self-review checklist

- [ ] No logo, no text, no spinner.
- [ ] Background matches first-screen color in both Light and Dark mode (asset catalog with both appearances).
- [ ] Empty chrome (nav bar, tab bar) matches the structure of the first real screen.
- [ ] Doesn't depend on assets that take time to decode (no large images).
- [ ] Tested by force-quitting the app and relaunching cold — no perceptible difference between launch screen and first frame.

## Why this matters

Apple's HIG (https://developer.apple.com/design/human-interface-guidelines/launching) is explicit, and App Review has historically rejected apps that use the launch screen as a splash / branding moment. Treat it as part of the *first frame*, not as marketing real estate.

## References

- Apple HIG — Launching → https://developer.apple.com/design/human-interface-guidelines/launching
- `UILaunchScreen` Info.plist key → https://developer.apple.com/documentation/bundleresources/information-property-list/uilaunchscreen
