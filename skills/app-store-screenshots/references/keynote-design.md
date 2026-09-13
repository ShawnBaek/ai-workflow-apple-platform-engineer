# Editable Keynote listing designs

Use this workflow for a Keynote screenshot source, not app-preview video. The
approved deck is the design source; exported PNGs are derivatives. Keep copy,
shapes and screenshots as separate editable objects. Do not insert a finished
poster as one image and call that an editable design.

## 1. Select the canvas before laying out objects

Record platform, Apple display slot, orientation, locale, final pixel width and
height, and the date the current Apple specification was checked. One platform
can require several slots. Do not infer the slot from the raw capture size alone.

The following are example accepted screenshot sizes checked on 2026-09-13, not
an exhaustive or permanent requirements table. Recheck the linked Apple table
for the actual destination, including new displays and fallback requirements.

| Destination example | Export pixels (width × height) | Layout starting point |
|---|---|---|
| iPhone 6.9-inch portrait | 1320 × 2868 | Short headline above a tall app capture |
| iPad 13-inch portrait | 2064 × 2752 | Show real tablet navigation and content |
| iPad 13-inch landscape | 2752 × 2064 | Wide workspace with adjacent copy |
| Mac | 2880 × 1800 | 16:10; workspace and copy side by side |
| Apple TV | 3840 × 2160 | Wide composition with readable television UI |
| Apple Vision Pro | 3840 × 2160 | Use a real spatial-app capture |
| Apple Watch Ultra 3 | 422 × 514 | Prioritize the watch UI; minimal copy |

For Watch, keep the selected accepted size consistent across locales. For any
display absent here, look it up rather than substituting the nearest aspect ratio.
Apple currently accepts 1–10 screenshots per set, PNG/JPEG, without alpha or
transparency. Video has a separate specification.

In Keynote on Mac, open **Document → Slide Size → Custom Slide Size**, enter the
selected width and height, and confirm the displayed values. A deck has one slide
size: use separate files for different canvas sizes/orientations. Do not resize a
finished Mac deck to make an iPhone set; duplicate the source and reflow objects.
Name files by platform/slot, orientation and locale in the app's design directory.

Use a blank layout and remove unused placeholders. Set an opaque background.
Export one pilot slide and inspect its decoded pixel dimensions before producing
the full deck. Do not assume Keynote canvas units, Retina scale, or a “high quality”
setting guarantee the intended PNG size. Fix canvas/export settings at the source
if dimensions differ; do not stretch the output to pass validation.

## 2. Build a small, distinct story

Before styling, map each slide to one benefit, one implemented feature and one
real capture. Start with the strongest product value. Include requested features
such as browsing, sharing or feedback explicitly; do not let a generic editor
slide stand in for all of them. Combine slides when their benefit and UI are
substantially identical. Do not force a fixed six-slide set.

References such as Uber or Snapchat can inform headline weight, spacing, rhythm
and image dominance. Keep the product's own identity. Do not copy a reference's
signature color, logo or distinctive composition without a user request. If the
feedback is “improve typography,” do not silently change the palette.

Use meaningful fictional app content: a useful feedback sentence rather than
“Test,” realistic document names rather than automation/acceptance-test labels.
Change demo data through the actual app/fixture, then recapture; do not paint over
UI text. Show an expanded sidebar when it explains navigation or role management.
Do not add social-network logos or claim direct posting when only a system share
sheet or PDF export exists.

## 3. Make typography work at listing size

Choose one available, appropriately licensed family with a strong display weight
and readable body weight. Keep a consistent left edge and baseline rhythm.
Use one short benefit headline, generally 3–8 words over 1–3 deliberate lines;
supporting copy is optional and should add information rather than repeat it.
Avoid forced uppercase for long copy and avoid isolated one-word last lines.

These are design starting points, not Apple requirements. Let S be the shorter
canvas edge. Start with outer margins 4–6% of S, headline size 7–10% of S,
supporting copy 2.5–3.5% of S and a clear gutter around 3–5% of S. Use the actual
font's appearance and wrapping to adjust. For a 2880 × 1800 canvas this suggests
126–180 headline units and 45–63 supporting units when the canvas/export scale
is 1:1. On Watch-size canvases prioritize the UI instead of applying this recipe.

For a landscape split, try 60–70% of usable width for the capture and the rest
for copy. For portrait, reserve roughly the top quarter for the headline and
use the remaining space for the capture. These are alternatives, not layouts to
apply blindly. Keep the screenshot's aspect ratio locked and the evidence for
the claimed feature visible. Prefer a better capture/window size over shrinking
the entire app until its content becomes illegible.

Review a single export at about 360 pixels wide as well as full resolution.
If the headline or supporting message cannot be read comfortably at that width,
shorten it, enlarge it or rebalance the split. Do not solve overflow by repeatedly
reducing all text. At full resolution check clipping, awkward wraps, font
substitution, screenshot sharpness and alignment. Inspect every locale after
translation; never assume English line breaks still work.

## 4. Export the owner's final order

1. Save the exact approved `.key` file; verify its path and that current edits
   are saved. Use Keynote's supported controls or inspected scripting dictionary,
   not guessed scripting properties or binary edits to its internal files.
2. Read the slide navigator, including skipped/hidden slides. Record the intended
   export order by headline. Resolve unexpected skipped slides instead of silently
   including/excluding them. After owner reordering, the navigator wins over old
   filenames and earlier manifests.
3. Export images through Keynote to a new empty output directory. Select the
   intended slides and PNG/appropriate quality. Never mix exports from two orders.
4. Decode every image. Check count, exact accepted pixels, image format and alpha
   channel. An opaque-looking preview can still carry alpha; if needed, flatten
   the derivative onto its intended background using ImageIO/CoreGraphics and
   verify again. Preserve the native deck and raw captures.
5. Compare an ordered contact sheet to the saved navigator and inspect every
   image individually. Filenames such as `001` through `006` describe order only
   after this comparison; numerical sorting alone does not prove correct content.
6. Record the saved deck hash, ordered export filenames/hashes, platform, locale
   and build provenance in the existing delivery record. A later deck edit
   invalidates this export receipt until affected exports are regenerated.

## 5. Commit and upload are separate receipts

When the task includes source control, commit the final saved `.key` after the
owner's last edits. Include final exports and a compact order record only when
the project's artifact policy calls for them. Stage exact design paths; keep
temporary CLI reports and credentials out of Git. After authorized merge, compare
the local deck blob/hash with the file on remote main. An earlier design PR does
not prove a later reorder was committed. Do not move an existing release tag
unless specifically authorized.

For authorized upload, use the capture-and-verification reference. Match the
uploaded set against the same export receipt and wait for processing. Report
saved source, merged source, uploaded assets and review submission independently.
If Keynote automation or native editing is unavailable, say the editable-source
step is blocked; do not substitute a flat PNG or PPTX while claiming `.key` delivery.

Sources: [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/),
[Keynote custom slide size](https://support.apple.com/guide/keynote/change-the-slide-size-tan929f13a1f/mac).
