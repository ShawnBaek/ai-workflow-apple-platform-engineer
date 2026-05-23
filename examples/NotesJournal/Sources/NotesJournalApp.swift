import SwiftUI

@main
struct NotesJournalApp: App {
    private let useCase: NotesUseCase = MockNotesUseCase()

    var body: some Scene {
        WindowGroup {
            NotesRootView(useCase: useCase)
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}
