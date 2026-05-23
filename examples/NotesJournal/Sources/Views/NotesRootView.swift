import SwiftUI

struct NotesRootView: View {
    let useCase: NotesUseCase
    @State private var notes: [Note] = []
    @State private var selection: Note.ID?

    var body: some View {
        #if os(watchOS)
        WatchNotesListView(notes: $notes)
            .task { notes = await useCase.loadNotes() }
        #else
        NavigationSplitView {
            NotesListView(
                notes: $notes,
                selection: $selection,
                onCreate: createNote,
                onDelete: deleteNote
            )
        } detail: {
            if let id = selection, let binding = bindingForNote(id) {
                NoteEditorView(note: binding, useCase: useCase)
            } else {
                EmptyStateView()
            }
        }
        .task { notes = await useCase.loadNotes() }
        #endif
    }

    private func createNote() {
        let new = Note(
            id: UUID(),
            title: "",
            body: "",
            updatedAt: Date(),
            tags: []
        )
        notes.insert(new, at: 0)
        selection = new.id
        Task { await useCase.save(new) }
    }

    private func deleteNote(_ id: Note.ID) {
        notes.removeAll { $0.id == id }
        if selection == id { selection = nil }
        Task { await useCase.delete(id) }
    }

    private func bindingForNote(_ id: Note.ID) -> Binding<Note>? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        return $notes[index]
    }
}
