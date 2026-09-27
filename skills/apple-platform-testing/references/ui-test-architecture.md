# UI and end-to-end test architecture

Read this before adding or restructuring UI tests, the app code that prepares a
UI-test launch, or end-to-end (E2E) tests, and when reviewing them. It covers
where test support lives, how a test chooses the app's state, permission
prompts, data isolation, and E2E scope. Selectors, waits, gestures and result
handling are in [XCTest and UI automation practice](xctest-and-ui-automation.md).

## Choose the layer

| Layer | Proves | Typical project CI cadence |
| --- | --- | --- |
| Unit (Swift Testing or XCTest) | logic, ViewModel inputs and outputs with mocks, edge cases | every change |
| UI test (XCUITest, hermetic) | a user-visible flow in the real app, with in-app fakes chosen at launch | pull request gate |
| E2E (XCUITest, real service) | a few journeys across a real, non-production service boundary | scheduled or before release |

Test each contract at the cheapest layer that can observe it. A UI test does
not re-verify every business rule the unit tests cover, and an E2E test does
not re-verify screen details the UI tests cover. The cadence column describes
how a project's CI runs each layer, not what an agent runs for a change: the
agent's own verification follows the
[minimum-evidence rules](../SKILL.md#choose-the-minimum-sufficient-evidence),
usually only the tests the change adds or affects. Build the structure below
only when a change needs a UI test; do not add a scenario seam or screen
objects for a change those rules settle without one.

If the project already has a test-launch mechanism, such as its own
`-uitesting` flags or a launch-environment key, extend and consolidate that
mechanism instead of adding a parallel one: keep its names, move its reads into
the composition root, and fold its flags into named scenarios as the tests that
use them change. The names below are examples.

## Keep test support out of the product

The app reads the launch contract in one place, its composition root, and
builds the dependency graph from it. Views, ViewModels and services receive
their dependencies; they never read `ProcessInfo`, launch arguments, or an
`isUITesting` flag. Swap leaves of the live graph (store, API client, clock,
permission provider, and protected resources such as the recorder or photo
library), not the whole graph, so UI tests exercise real feature code.

Compile the seam, its fakes and its fixture data only into the configuration
the UI test scheme builds, usually Debug: wrap them in `#if DEBUG`, and list
fixture resources in Development Assets (`DEVELOPMENT_ASSET_PATHS`), which
archives exclude; `#if DEBUG` does not remove copied resources. After adding or
moving the seam, build Release once to confirm the app compiles without it.

Share the scenario names through one small file that both the app and the UI
test target compile, so a rename breaks the build instead of a test run. That
file is `#if DEBUG`, so keep shared accessibility identifier constants out of
it: put them in a separate file that both targets compile in every
configuration, because Release views still set identifiers.

```swift
// UITestScenario.swift: compiled into the app and the UI test target.
#if DEBUG
  enum UITestScenario: String {
    case signedInInbox = "signed-in-inbox"
    case microphonePrompt = "microphone-prompt"

    static let launchArgument = "-UITestScenario"
  }
#endif
```

```swift
import SwiftUI

// App target: the composition root is the only code that reads the launch contract.
#if DEBUG
  extension UITestScenario {
    /// Returns nil for a normal launch and stops the app on a missing or unknown value.
    static func requested(in arguments: [String] = ProcessInfo.processInfo.arguments)
      -> UITestScenario?
    {
      guard let flag = arguments.firstIndex(of: launchArgument) else { return nil }
      guard flag + 1 < arguments.count, let scenario = UITestScenario(rawValue: arguments[flag + 1])
      else { fatalError("Unknown \(launchArgument) value in \(arguments)") }
      return scenario
    }
  }
#endif

@main
struct InboxApp: App {
  private let dependencies: AppDependencies

  init() {
    #if DEBUG
      if let scenario = UITestScenario.requested() {
        // In-memory store, fixture API client, fixed clock, permission answers, resource fakes.
        dependencies = .uiTest(scenario)
        return
      }
    #endif
    dependencies = .live()
  }

  var body: some Scene {
    WindowGroup { RootView(dependencies: dependencies) }
  }
}
```

Accessibility identifiers are not test pollution: they are the stable,
test-facing API the [selector contract](xctest-and-ui-automation.md#accessibility-tree-and-selector-contract)
asks for. Test-only buttons, hidden views, gestures or menu items; feature code
that branches on a test flag; sleeps or animation switches inside features; and
fixture files bundled into the shipped app are findings.

In the UI test target, give each screen one screen object that exposes intents
and element queries. A test then reads as a journey plus a postcondition, and a
tap sequence lives in one place instead of being copied between tests. Launch
every test, including a permission-prompt test, through one helper that
appends the scenario to the
[arguments Xcode passes](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/launcharguments);
avoid chains of base classes; and split test files by feature before they reach
about 1,000 lines.

```swift
import XCTest

@MainActor
final class InboxUITests: XCTestCase {
  func testArchivingANoteRemovesItsRow() {
    let inbox = InboxScreen.launch(.signedInInbox)
    let row = inbox.row(id: "note-1")
    XCTAssertTrue(row.waitForExistence(timeout: 5))

    inbox.archive(id: "note-1")

    XCTAssertTrue(row.waitForNonExistence(timeout: 5))
  }
}

extension XCUIApplication {
  /// The one launch path for every UI test, including the prompt tests that reset a service.
  static func launched(
    _ scenario: UITestScenario,
    resettingAuthorizationFor resources: [XCUIProtectedResource] = []
  ) -> XCUIApplication {
    let app = XCUIApplication()
    for resource in resources {
      app.resetAuthorizationStatus(for: resource)
    }
    // Append: keep the arguments Xcode passes, such as a test plan's language.
    app.launchArguments += [UITestScenario.launchArgument, scenario.rawValue]
    app.launch()
    return app
  }
}

/// One screen object per screen: intents and element queries the tests share.
@MainActor
struct InboxScreen {
  let app: XCUIApplication

  static func launch(_ scenario: UITestScenario) -> InboxScreen {
    InboxScreen(app: .launched(scenario))
  }

  func row(id: String) -> XCUIElement { app.cells["inbox.row.\(id)"] }

  func archive(id: String) { row(id: id).buttons["inbox.row.archive"].tap() }
}
```

## Govern the launch contract

- **Named scenarios, not flag combinations.** One namespaced argument selects a
  complete initial state: account, data set, feature flags, fixed clock,
  network fixture set, and permission answers. When a test needs another
  state, add a scenario; do not add a boolean flag for tests to combine ad hoc.
- **Strict parsing.** An unknown or malformed value stops the app with a clear
  message. A misspelled scenario must fail the test, never fall back to live
  services.
- **System settings stay orthogonal.** Language and region can accompany a
  scenario through the launch arguments
  `["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]` or a test plan
  configuration. Appearance can come from `XCUIDevice.shared.appearance`, which
  changes the whole device, so restore it when the test ends.
- **Arguments are defaults.** An argument pair `-name value` also becomes the
  `UserDefaults` value for `name` in the argument domain, so namespace the key
  so it cannot shadow a real preference. Never pass secrets as arguments.
- **Environment carries values, not switches**, such as an E2E base URL.
  `xcodebuild test` passes a shell variable to the test runner when its name
  is prefixed `TEST_RUNNER_`, with the prefix removed; do not rely on other
  exported variables reaching it. The app receives
  `XCUIApplication.launchEnvironment`, not the runner's environment; copy any
  runner value it needs into it.
- **One inventory.** The scenario type lists every supported state. Review a
  new scenario like an API change, and delete one with its last test.

## Keep permission prompts from blocking tests

A test that is not about a permission should never meet a system prompt. In
order of preference:

1. **Answer through the app's permission seam.** The scenario supplies a
   permission provider that reports granted, denied or not determined, so the
   feature never calls the system request in that test. For a granted answer,
   the scenario also replaces the protected resource the feature then uses,
   such as the recorder, a capture session or the photo library, with a fake,
   because the system prompts on its own the first time an app
   [records audio](https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)),
   [uses a capture device](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media)
   or [performs a photo library operation that needs authorization](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app),
   whatever the provider reports. The seam also works for camera,
   notifications, tracking, Bluetooth and HealthKit, which `simctl` cannot
   grant. A test that needs the real resource uses a pre-grant (option 2)
   where `simctl` supports the service, or answers the prompt as a prompt test
   (option 3).
2. **Pre-grant on the run's Simulator** from the host, not from the test,
   before the run launches the app:
   `xcrun simctl privacy <UDID> grant <service> <bundle-id>`. A change can
   terminate a running app. Xcode 27.2's `simctl` grants calendar, contacts,
   contacts-limited, location, location-always, photos, photos-add,
   media-library, microphone, motion, reminders and siri; check
   `xcrun simctl help privacy` for yours. Use the exact device the run owns
   under the [destination reuse](../../xcodebuild/SKILL.md#choose-and-reuse-a-simulator-destination)
   rules, never grant `all` on a shared device, and reset the grant when the
   run ends; `reset` returns the service to prompting, not to its earlier
   state. As `simctl` warns, a grant can hide a missing usage description.
3. **Test the prompt itself** only when the live request path (when the app
   asks, the usage string, allow or deny handling) is the contract at risk,
   at most once per permission. Its scenario keeps the live permission
   provider and the live resource for the service under test, while the seam
   still fakes everything else. Launch through the helper with the service's
   authorization reset (`resetAuthorizationStatus(for:)`), so the next access
   prompts whatever an earlier test answered; trigger it; answer the alert
   through Springboard; assert the app's outcome; and reset the service again
   when the test ends. System alert text and button order belong to the OS
   and follow the device language, so run this test only on a destination
   whose recorded language matches the expected text, and record the OS
   version.

```swift
import XCTest

@MainActor
final class RecorderPermissionUITests: XCTestCase {
  func testAllowingMicrophoneStartsRecording() {
    continueAfterFailure = false  // Stop at a missing alert instead of tapping a missing button.
    // Reset before launch, so the tap prompts whatever an earlier test answered.
    let app = XCUIApplication.launched(.microphonePrompt, resettingAuthorizationFor: [.microphone])
    // Leave the service prompting again, whether this test allows, denies or fails.
    addTeardownBlock { app.resetAuthorizationStatus(for: .microphone) }

    app.buttons["recorder.start"].tap()

    // The tap raises the alert directly, so it is an expected step, not an interruption.
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let alert = springboard.alerts.firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    alert.buttons["Allow"].tap()  // OS-owned text in the device language.

    XCTAssertTrue(app.staticTexts["recorder.state.recording"].waitForExistence(timeout: 5))
  }
}
```

A host pre-grant and a prompt test change the same device state, and a reset
returns a service to prompting, not to an earlier grant. A test that relies on
a pre-grant can therefore pass or fail depending on whether a prompt test for
that service ran before it, answered Deny, or failed before answering. Keep
results independent of test order:

- Give every test that is not about the prompt the seam's permission answer
  and resource fakes, so the device's state cannot change its outcome. A test
  that needs a real resource depends on that state: give it a pre-grant as the
  last bullet describes, or make it a prompt test.
- Let each prompt test reset its service before launch and again when it ends,
  as above, so it neither depends on an earlier answer nor leaves its own.
- When other tests rely on a host pre-grant for a service that a prompt test
  resets, run the prompt tests separately, in their own test plan or
  `-only-testing` run; exclude them from the main run, for example with
  `-skip-testing:<target>/<class>` or a main test plan that omits them; and
  apply the pre-grant before the run that relies on it.

Notifications cannot be reset from a test:
[`XCUIProtectedResource`](https://developer.apple.com/documentation/xcuiautomation/xcuiprotectedresource)
has no notifications case, `simctl privacy` has no notifications service, and
only the app's first
[authorization request](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:))
prompts; the system stores the answer. A notification-prompt test therefore
needs a fresh install: uninstall the app before the run with
`xcrun simctl uninstall <UDID> <bundle-id>`. Do that without asking only on a
device this task created, which is task-owned under
[destination reuse](../../xcodebuild/SKILL.md#choose-and-reuse-a-simulator-destination)
step 3. On any existing device, including the user's active run destination,
get the user's approval first, because uninstalling deletes the app's data.
Keep one such test per install, and let its wait for the alert confirm that the
fresh install prompts on that OS. If no alert appears, the OS may have kept
the earlier answer; Apple's archived
[TN2265](https://developer.apple.com/library/archive/technotes/tn2265/_index.html)
(last revised 2016) says iOS does not show that alert again unless the device
is restored or the app has been uninstalled for at least a day. Do not keep
uninstalling on an existing device, since each uninstall needs approval and
deletes data: run the test on a new device that destination reuse lets the
task create, or cover the flow through the seam. On macOS,
`XCUIProtectedResource` has no notifications case either, so macOS tests get
their notification answer through the seam.

Use `addUIInterruptionMonitor(withDescription:handler:)` only for alerts with
unpredictable timing, such as one raised by a background network response.
Apple's [Handling UI Interruptions](https://developer.apple.com/documentation/xctest/handling-ui-interruptions)
states that a test tries its monitors only when unrelated UI blocks an element
it must interact with, and that an alert which is an expected part of the
workflow needs no monitor. The `XCTestCase` interruption-monitoring header adds
that a monitor does not run just because an alert appears, and that an alert
shown in direct response to a test action is part of the UI, to find and
answer directly. The article also lists a permission request that an app
action may trigger, such as photos access, as a monitor case; this guide
removes that uncertainty with a seam that fakes both the answer and the
resource, or with a pre-grant, so each test knows whether a prompt appears.
A monitor that accepts every alert hides prompts the product should not show.

On macOS, `simctl` and Springboard do not apply. Use the permission seam, and
let a prompt test reset its resource through the launch helper;
`resetAuthorizationStatus(for:)` also covers macOS resources such as the
Desktop, Documents and Downloads folders and Apple Events. macOS UI tests also
need Automation Mode, and enabling it asks for user authentication unless the
Mac is configured otherwise. On a dedicated test or CI Mac, the user or an
administrator, not the agent (it is a security setting), runs
`automationmodetool enable-automationmode-without-authentication` once;
`automationmodetool` with no argument prints the current setting. On any
other Mac, start a macOS UI test run only while the user can answer that
authentication prompt.

## Isolate state and data

- Each test launches with a scenario that defines its whole state. No test
  depends on test order, data left by another test, or a session left on the
  device; use per-launch in-memory or temporary stores.
- Set up through the scenario, not the UI. Start signed in; only the sign-in
  test signs in through the screen. When a test needs a fresh process, call
  `launch()` again; it
  [terminates the running instance](https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/launch())
  first, so a separate `terminate()` adds nothing.
- Keep UI tests off the network. The scenario installs a fixture client at the
  API seam: with [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator),
  a type conforming to the generated `APIProtocol` that returns typed
  responses and failures, or a `URLProtocol` subclass in the scenario's
  `URLSessionConfiguration.protocolClasses` inside the app process.
- Tests stay order-independent even with parallel clones disabled. When a test
  plan enables parallel execution, clones must not share on-disk state.

## End-to-end tests

- **Scope.** Keep E2E to journeys whose risk is the real service boundary, such
  as sign-in, sync, or a purchase (route StoreKit sandbox work to
  [`storekit-sandbox-testing`](../../storekit-sandbox-testing/SKILL.md)).
  Everything else is a hermetic UI test.
- **Environment.** Use a dedicated non-production environment, passed through
  `launchEnvironment`. Under the E2E scenario the app accepts only that host and
  refuses production.
- **Data.** Create run-specific accounts and records through the environment's
  setup API or seeded fixtures, with unique names so concurrent runs cannot
  collide, and remove them afterward. Never share a mutable account between
  concurrent runs.
- **Secrets.** Provide credentials at run time from the project's secret store
  as `TEST_RUNNER_` variables that the test copies into `launchEnvironment`.
  Never commit, print, or attach them to results or screenshots.
- **Plans and schedule.** Put E2E tests in their own test plan. In the
  project's CI, run it on a schedule or before release, while the pull request
  gate runs the hermetic UI plan. That is CI cadence; an agent verifying a
  change runs only what the minimum-evidence rules call for.
- **Failures and retries.** Classify each failure as product, environment or
  test before rerunning. Use the `xcodebuild` flag `-retry-tests-on-failure` or
  the E2E plan's repetition setting only on E2E runs and record every retry; a
  test that passes on retry is flaky and gets an owner. Never add retries to
  the pull request gate to make it pass.

## Run

Run an iOS, iPadOS or watchOS UI test on the Simulator recorded under
[destination reuse](../../xcodebuild/SKILL.md#choose-and-reuse-a-simulator-destination),
with parallel-testing clones off unless the plan requires them. The Xcode MCP
server's `RunSomeTests` takes no UDID or parallel option: use it only when the
recorded UDID is the workspace's active run destination and the active test
plan does not run tests in parallel. Otherwise run
`xcodebuild test -scheme <scheme> -testPlan <plan> -destination id=<UDID> -parallel-testing-enabled NO -only-testing:<target>/<class>/<method>`.
`RunSomeTests` follows the active test plan, so running the E2E plan through it
means switching that plan, which needs the user's approval.

A macOS UI test runs on the Mac itself: pass `-destination 'platform=macOS'`,
or `'platform=macOS,variant=Mac Catalyst'` for a Mac Catalyst app, instead of
the UDID. It drives the Mac's foreground UI, so nothing else should drive that
UI during the run. When other Xcode projects are active on the same Mac, hold
the host-scoped `macos_gui_session` lease with `session_scope: foreground_ui`
for the whole run, as [lease boundaries](../../xcodebuild/references/concurrent-project-resources.md#lease-boundaries)
describe. Start the run only when Automation Mode is ready as described above.

Keep the `.xcresult` and report as the skill describes.

## Review smells

| Smell | Consequence | Fix |
| --- | --- | --- |
| Test flags or `ProcessInfo` checks in feature code | test-only paths ship and drift | one composition-root seam |
| A second launch mechanism beside the project's existing one | two contracts that drift apart | extend and consolidate the existing one |
| Test-only controls or views in the UI | shipped debug surface, accessibility noise | drive the real UI from a scenario |
| A boolean argument per behavior, combined per test | untracked combinations, dead flags | named scenarios in one type |
| Unknown arguments silently ignored | a typo runs against live services | strict parsing that stops the app |
| System prompts in unrelated tests, or a monitor that accepts everything | hangs, or hidden wrong prompts | permission seam, pre-grant, one prompt test |
| Sleeps and fixed delays | slow and flaky | wait for observable state |
| Signing in or seeding through the UI in every test | slow, unrelated failures | scenario state |
| Order-dependent tests or leftover device state, including a pre-grant a prompt test resets | flaky, unreproducible failures | state defined per launch, prompt tests that reset before and after, a separate prompt run |
| Live or production network in UI tests | flaky and unsafe | fixture client at the API seam |
| Copied tap sequences or oversized test files | brittle, hard to change | screen objects, files split by feature |
| Retries in the pull request gate | hidden flakiness | owned flaky tests, retries only in E2E |
