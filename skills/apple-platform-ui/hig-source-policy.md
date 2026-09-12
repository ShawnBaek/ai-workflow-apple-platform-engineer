# Apple Human Interface Guidelines source policy

Read this reference before making a non-obvious visual, navigation,
interaction, accessibility, or platform-adaptation decision.

## Authority and freshness

1. Use the live [Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
   for the selected platform and OS generation as the normative design source.
2. Prefer an Apple-authored Xcode skill or Documentation Search result when it
   exposes the exact HIG topic. Record the provider, page URL, retrieval date,
   selected platform, and Xcode/SDK build when the decision depends on a new or
   beta behavior.
3. Use this skill as implementation guidance, not as a frozen mirror of the
   full HIG. Do not RAG-index or republish Apple's complete design corpus.
4. Treat third-party articles, screenshots, Figma files, and existing app code
   as product/design evidence. They do not silently override a current Apple
   requirement or an explicit user decision.
5. When a Figma or product request intentionally diverges from HIG, state the
   exact tradeoff and preserve the user-approved decision in the task evidence.

## Decision checklist

Check only the dimensions affected by the work:

| Dimension | Evidence to resolve |
| --- | --- |
| hierarchy and layout | current HIG layout guidance, safe areas, window/size-class behavior |
| navigation | platform-native container and back/sidebar/tab behavior |
| controls and input | native control semantics, hit targets, keyboard, pointer, Crown, focus |
| feedback and motion | system feedback, Reduce Motion, interruption and progress states |
| typography and color | semantic text styles/colors, Dynamic Type, contrast, Dark Mode |
| accessibility | VoiceOver labels/order, focus, text scaling, non-color cues |
| privacy and permissions | purpose strings, just-in-time prompts, sensitive visual evidence |
| platform conventions | iPhone, iPad, watchOS, and macOS are verified separately |
| identity and launch | app icon and launch guidance through their owning focused skills |

Do not turn this list into a blanket test matrix. Tie each chosen check to an
acceptance criterion or material regression risk.

## Evidence

For a non-obvious HIG decision, record:

- the exact Apple page or Apple-authored skill result;
- platform, OS/SDK, form factor or window state;
- the product constraint and selected behavior;
- the smallest runtime, accessibility, screenshot, or video observation that
  proves the implementation rather than merely the source file.

Use the focused `screenshot`, `device-interaction`, and
`apple-platform-testing` skills for runtime evidence. A preview is useful design
evidence but is not a replacement for the required app flow.

## Primary Apple entry points

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Designing for iOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ios)
- [Designing for iPadOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-ipados)
- [Designing for watchOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-watchos)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
