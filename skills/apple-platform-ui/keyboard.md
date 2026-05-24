# Keyboard handling — stop the keyboard from covering your fields

The single most common indie-dev complaint after shipping: "the keyboard covers my Save button." Apple gives you everything you need; the trick is knowing which APIs do what.

**Default SwiftUI behavior:** SwiftUI automatically inset the safe area for the keyboard. Most `ScrollView`, `Form`, `List`, and `VStack`-in-`ScrollView` layouts adjust themselves. **You usually don't need to do anything.**

When you *do* need to do something:
- You have a fixed-position button (`.bottom` overlay) that gets covered.
- You're using a `ZStack` or a non-scrolling layout that doesn't auto-adjust.
- You want explicit focus control (Next / Done flow).
- You want to dismiss the keyboard on scroll, on tap, or on a button.

## The 7 keyboard patterns you actually need

### 1. Manage focus with `@FocusState`

The modern, correct way. Don't use `becomeFirstResponder` from UIKit bridges.

```swift
struct LoginForm: View {
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    enum Field: Hashable { case email, password }

    var body: some View {
        Form {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }

            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit { signIn() }
        }
        .onAppear { focus = .email }   // autofocus first field
    }
}
```

### 2. Always set `.keyboardType`, `.textContentType`, `.submitLabel`

Every text field. Free wins:
- `.keyboardType(.emailAddress)` / `.numberPad` / `.URL` / `.phonePad`
- `.textContentType(.emailAddress)` / `.password` / `.oneTimeCode` (enables AutoFill)
- `.textInputAutocapitalization(.never)` for emails / usernames
- `.submitLabel(.next)` / `.go` / `.done` / `.search` / `.send`

### 3. Add a `Done` button to the keyboard toolbar

For forms that don't have a natural submit:

```swift
.toolbar {
    ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { focus = nil }   // dismisses the keyboard
    }
}
```

`focus = nil` (where `focus` is your `@FocusState`) is the canonical way to dismiss the keyboard in SwiftUI. **Don't** call `UIApplication.shared.sendAction(#selector(...), to: nil, from: nil, for: nil)` — that's the old UIKit hack.

### 4. Dismiss on scroll for long content

```swift
ScrollView {
    // …form content
}
.scrollDismissesKeyboard(.interactively)   // or .immediately, or .never
```

### 5. Dismiss on tap-outside

Not built-in but two lines:

```swift
struct ContentView: View {
    @FocusState private var keyboardFocused: Bool
    var body: some View {
        VStack { /* … */ }
            .focused($keyboardFocused)
            .onTapGesture { keyboardFocused = false }
    }
}
```

Or for a whole form, attach `.onTapGesture` to the background and `focus = nil`.

### 6. Opt OUT of keyboard avoidance

When SwiftUI's automatic adjust fights your layout:

```swift
VStack {
    Spacer()
    BigImageBanner()  // pin this, don't move it
    Spacer()
    TextField("Comment", text: $comment)
}
.ignoresSafeArea(.keyboard, edges: .bottom)
```

Use when you've designed for the keyboard explicitly (e.g., the text field is *meant* to be at the bottom and the rest of the layout shouldn't compress).

### 7. Pin a button above the keyboard

The "Save" button that has to stay visible:

```swift
ScrollView {
    Form { /* fields */ }
}
.safeAreaInset(edge: .bottom) {
    Button("Save", action: save)
        .buttonStyle(.borderedProminent)
        .padding()
        .background(.bar)
}
```

`safeAreaInset(edge: .bottom)` puts the button in a region the keyboard pushes up too — sits just above the keyboard automatically, and just above the home indicator when the keyboard is hidden.

## UIKit pattern (when you must)

For a UIKit screen with a `UIScrollView` (e.g., a legacy form), use `keyboardLayoutGuide` — the modern, declarative way:

```swift
scrollView.contentLayoutGuide.bottomAnchor
    .constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
```

`keyboardLayoutGuide` tracks the keyboard frame automatically — no `NotificationCenter` observers, no `keyboardWillShow` handlers, no manual `contentInset` math. Pin whatever you want to it.

For a UIKit screen wrapped in SwiftUI via `UIViewControllerRepresentable`, **the SwiftUI side already handles keyboard avoidance** — don't double-implement.

## Platform divergence

- **iOS / iPadOS:** everything above applies.
- **macOS:** no software keyboard; `focus` still works (Tab key cycles fields) but you don't need avoidance.
- **watchOS:** dictation / scribble keyboards open as separate screens — no overlap problem to solve.

## Self-review checklist for keyboard handling

- [ ] Every `TextField` / `SecureField` has `.keyboardType`, `.textContentType`, `.submitLabel`.
- [ ] Focus flows naturally (Next → Next → Go) via `@FocusState` + `.onSubmit`.
- [ ] If there's no natural submit, the keyboard has a `Done` button in the toolbar.
- [ ] On a screen with a primary action button, the button stays visible above the keyboard (`safeAreaInset(edge: .bottom)` or scrolls into view).
- [ ] On a long form: `.scrollDismissesKeyboard(.interactively)` is set.
- [ ] You verified by running on a small device (iPhone SE / iPhone mini) — those expose keyboard cover bugs that 6.9" devices hide.
