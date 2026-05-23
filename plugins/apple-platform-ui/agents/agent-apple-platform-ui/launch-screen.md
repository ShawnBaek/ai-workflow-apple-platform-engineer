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

## macOS / watchOS

- **macOS:** no launch screen concept. The window appears when ready; keep `App.init()` fast (see the `apple-platform-performance` agent, Item 18).
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
