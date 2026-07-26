# Apple Platform Handoff

Read this file before installing an icon in Xcode, generating fallback assets,
or validating a release archive.

## Icon Composer source specifications

| Platform | Layout canvas | System mask | Icon Composer appearances |
|---|---:|---|---|
| iOS and iPadOS | 1024 x 1024 px | Rounded rectangle | Default, Dark, and Mono; Mono produces Clear and Tinted variants |
| macOS | 1024 x 1024 px | Rounded rectangle | Default, Dark, and Mono; Mono produces Clear and Tinted variants |
| watchOS | 1088 x 1088 px | Circle | No appearance variants |

Use one layered `.icon` document for iPhone, iPad, Mac, and Apple Watch when the
project and deployment targets support the current Icon Composer workflow.
Xcode renders the required platform sizes from that file at build time.

## Install the `.icon` package

1. Name the approved package after the product, such as `AppName.icon`.
2. Add it to the existing Xcode project or workspace and include it in each
   applicable app target.
3. Select each app target, open **General > App Icons and Launch Screen**, and
   set **App Icon** to `AppName`, without the `.icon` extension.
4. Build each platform target and confirm that Xcode generates and bundles the
   icon without asset-catalog conflicts.

Adding an Icon Composer file replaces the asset catalog previously used to
represent that target's primary app icon. If exact legacy artwork must remain on
older releases, follow Apple's guidance and continue using the asset catalog
instead of assuming both sources will be combined.

## Asset-catalog fallback

Use an `AppIcon.appiconset` only when the project or supported release requires
the asset-catalog workflow. Inspect its `Contents.json` and populate every slot
it declares; do not guess the set from filenames alone.

For a modern iOS or iPadOS universal icon slot, provide a fully opaque 1024 x
1024 px image and let Xcode derive smaller representations. Preserve explicitly
declared legacy slots when the existing catalog requires them.

For a legacy macOS `AppIcon.appiconset`, provide the complete representation
ladder:

| Logical slot | Scale | Pixel output |
|---|---:|---:|
| 16 x 16 | 1x | 16 x 16 |
| 16 x 16 | 2x | 32 x 32 |
| 32 x 32 | 1x | 32 x 32 |
| 32 x 32 | 2x | 64 x 64 |
| 128 x 128 | 1x | 128 x 128 |
| 128 x 128 | 2x | 256 x 256 |
| 256 x 256 | 1x | 256 x 256 |
| 256 x 256 | 2x | 512 x 512 |
| 512 x 512 | 1x | 512 x 512 |
| 512 x 512 | 2x | 1024 x 1024 |

Generate a matching `.icns` from the same approved artwork when the project
uses `CFBundleIconFile`, a copy script, or another explicit `.icns` handoff.

## Opaque export checks

- Flatten App Store and asset-catalog fallback PNGs onto the intended background.
- Export in RGB/sRGB with no alpha channel.
- Keep the 1024 x 1024 marketing image square and do not bake in Apple's mask.
- Verify dimensions and image mode programmatically before handoff.

## Project and release verification

1. Inspect `ASSETCATALOG_COMPILER_APPICON_NAME`, `CFBundleIconName`,
   `CFBundleIconFile`, target membership, and any icon-copy build scripts.
2. Build every supported platform target through the repository's Xcode build
   workflow.
3. Inspect the built bundle for generated icon assets or the expected `.icns`.
4. Check the icon on a simulator or device at Home Screen, Settings, Spotlight,
   notification, Dock, and App Store-like sizes where applicable.
5. For macOS release work, create and inspect a fresh archive. Confirm its icon
   includes representations through 1024 px and do not submit an old archive.

## Apple references

- [Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)
- [Configuring your app icon using an asset catalog](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)
- [Human Interface Guidelines: App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)
- [Apple Design Resources](https://developer.apple.com/design/resources/)
