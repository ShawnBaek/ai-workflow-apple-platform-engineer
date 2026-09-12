# Storyboards, programmatic UIKit, and hybrid interfaces

Proposed reference for `apple-platform-ui`. Load it when the affected screen uses a storyboard/XIB, UIKit construction in code, or a UIKit/SwiftUI boundary. This file is a workspace draft, not an installed skill.

## Identify how this screen is built

Trace the selected target's actual launch/navigation path and view construction before editing. Inspect the relevant `.storyboard`, `.xib`, Swift or Objective-C controller/view, project resource membership, and existing factory or navigation call. Check AppDelegate/SceneDelegate, scene configuration and storyboard settings when they own entry into the affected flow. A launch storyboard alone does not establish how the app's content screens are built. File counts and the presence of SwiftUI elsewhere are insufficient.

| Approach | Extend the existing construction path |
| --- | --- |
| Storyboard/XIB UIKit | Edit the affected scene/resource and its connected controller or view |
| Programmatic UIKit | Use the existing initializer, view hierarchy, Auto Layout, and navigation patterns |
| Storyboard plus programmatic UIKit | Keep the scene and connected container; add the scoped view or behavior in code |
| UIKit plus SwiftUI | Preserve each framework's ownership and use a narrow integration boundary |
| SwiftUI | Follow the existing view, state, and navigation structure |

Choose the approach for the affected feature, not the age of the app. Preserve deployment targets, Objective-C interoperability, and established architecture. A storyboard screen does not need conversion to SwiftUI, programmatic layout, MVVM, or a coordinator framework to receive a small improvement.

## Understand Interface Builder connections

An `@IBOutlet` declaration exposes a property to Interface Builder; the resource's saved connection supplies its object. An `@IBAction` exposes an action; its saved target, selector, and event determine how the control invokes it. Read both source and resource. Renaming or deleting a declaration requires checking the saved connections too. Apple's [target/action and outlet fundamentals](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaFundamentals/CommunicatingWithObjects/CommunicateWithObjects.html) explain the mechanism; this archived reference is not a guide to current Xcode menus.

For the changed scene, check the details relevant to the edit:

- Custom class, module, resource bundle, target membership, and storyboard identifier. A storyboard identifier, an internal XML object ID, a cell reuse identifier, and an accessibility identifier have different purposes.
- Outlet names, destinations, types, constraint outlets, and outlet collections. Preserve meaningful collection ordering explicitly rather than assuming its connection order is a contract.
- Action selector, target, control event, and any equivalent target/action added in code. Avoid registering the same interaction twice.
- Delegates/data sources, gesture connections, prototype cells, reusable headers, and their actual registration/dequeue path. Registering a plain class in place of a storyboard or nib cell can bypass its connected subviews.
- XIB File's Owner versus top-level objects. Load using the existing owner/bundle contract and retain objects according to their actual ownership. Do not impose `weak` on every outlet; detached or top-level objects may require an owning reference.
- Referenced `IBInspectable` values, `IBDesignable` behavior, user-defined runtime attributes, localized strings, and trait-specific settings when the changed element uses them.

Fix stale connections, incorrect classes, or the wrong loading path at their source. Changing a required outlet to optional and silently skipping configuration can hide the defect. Keep unrelated XML IDs and localization associations stable; inspect the diff for whole-file rewrites or tool-version churn.

## Preserve loading and lifecycle

Instantiate a storyboard controller through its storyboard or the app's existing creator/factory, using the real identifier and bundle. Calling `SomeViewController()` can bypass the scene and its connections. Storyboard decoding uses `init(coder:)`; preserve that path, including any existing custom creator used for dependency injection. Nib-backed controllers use their established nib loading path. [Apple controller initialization](https://developer.apple.com/documentation/uikit/uiviewcontroller/init(nibname:bundle:)).

Do not access view outlets during initialization. Configure connected views in `viewDidLoad()` or after the view has loaded. Use `loadViewIfNeeded()` when a focused check needs the real loaded hierarchy; do not call `viewDidLoad()` manually. Apple establishes the connections before that lifecycle callback. [Managing a controller's views](https://developer.apple.com/documentation/uikit/displaying-and-managing-views-with-a-view-controller).

Keep Interface Builder's loading behavior for storyboard/nib-backed views. For a fully programmatic controller that owns `loadView()`, construct and assign its root view there; preserve an existing valid `viewDidLoad()`-based subview setup when that is the project's approach. Avoid creating views or registering actions repeatedly during layout/appearance callbacks. [Apple loadView guidance](https://developer.apple.com/documentation/uikit/uiviewcontroller/loadview()).

## Preserve layout and navigation

Inspect existing constraints, priorities, intrinsic sizes, hugging/compression resistance, safe-area/layout-margin anchors, and size-class variations before adding constraints. Update the constraint that owns a relationship rather than overlaying a competing one. Set autoresizing-mask translation appropriately for new views constrained in code. A frame visible in Interface Builder does not prove runtime Auto Layout is correct.

Trace initial controllers, storyboard references, relationship/embed segues, navigation/tab containers, presentation style, segue identifiers, `prepare(for:sender:)`, and unwind actions when navigation changes. The destination may be a container whose child receives the data. Preserve the established transition and data handoff; do not add a second programmatic push for a control that already triggers a segue. [Apple segue behavior](https://developer.apple.com/documentation/uikit/uistoryboardsegue).

For a child controller added in code, use UIKit containment as well as inserting its view: establish parentage, add and constrain the view, then notify completion. Remove the child through the matching lifecycle. A view alone is not a controller relationship. [Apple container guidance](https://developer.apple.com/documentation/uikit/creating-a-custom-container-view-controller).

## Keep hybrid boundaries small

Storyboard plus programmatic UIKit is already a valid hybrid approach. A connected container can host one programmatic component without adding another framework or application layer.

When SwiftUI is part of the accepted change, use `UIHostingController` to host it in UIKit, or `UIViewRepresentable`/`UIViewControllerRepresentable` for the other direction. Preserve containment, sizing, navigation, and lifecycle. Pass only the needed values and callbacks across the boundary, with one clear owner for shared state. Avoid duplicate navigation containers, repeated hosting-controller creation, and update feedback loops. [Apple UIKit/SwiftUI integration](https://developer.apple.com/documentation/swiftui/uikit-integration).

Use a representable's `Coordinator` only when communication such as delegate or target/action bridging needs it. It is not a requirement to introduce an app-wide coordinator architecture. Respect SwiftUI's control of the represented root view's layout. [UIViewControllerRepresentable](https://developer.apple.com/documentation/swiftui/uiviewcontrollerrepresentable).

## Preview and verify the real construction path

For a storyboard-backed preview, load the actual scene through its existing construction path and provide finite data at the current seam. Preserve any navigation/container context needed for correct appearance. A freshly constructed controller that bypasses its storyboard is not a preview of that scene. Do not convert the screen or raise deployment requirements just to enable `#Preview`; use Interface Builder and a focused runtime capture if the selected toolchain or dependencies make a faithful preview impractical.

Build the affected target when resource or source changes warrant it, and inspect Interface Builder compilation errors. A successful build or XML parse does not prove runtime connections and actions work. Load the affected scene, exercise the changed control/segue, and inspect relevant constraint diagnostics and appearance. Capture the actual screen for comparison, using shared horizontal/vertical guides when alignment is under review.

Use an existing hosted Swift XCTest to load the scene and check a meaningful connection/behavior when a regression test is justified. Exercise navigation through the real flow when a view-load check cannot prove it. A small manual recorded interaction or an existing focused UI test can suffice; do not add a new XCUITest target or test every storyboard scene for a one-screen edit. Keep custom verification code in Swift and preserve existing Objective-C production code where appropriate.

Report the approach, affected scene/code, observed check, and evidence. No storyboard project was built or run while drafting this reference.
