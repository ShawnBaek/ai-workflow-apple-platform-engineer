import SwiftUI

struct NotesListView: View {
    @Binding var notes: [Note]
    @Binding var selection: Note.ID?
    let onCreate: () -> Void
    let onDelete: (Note.ID) -> Void

    var body: some View {
        Group {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "note.text")
                } description: {
                    Text("Tap the compose button to write your first.")
                } actions: {
                    Button(action: onCreate) {
                        Label("New Note", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $selection) {
                    ForEach(notes) { note in
                        NoteRowView(note: note).tag(note.id)
                    }
                    .onDelete { offsets in
                        for index in offsets { onDelete(notes[index].id) }
                    }
                }
            }
        }
        .navigationTitle("Journal")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: onCreate) {
                    Label("New Note", systemImage: "square.and.pencil")
                }
            }
        }
    }
}

#Preview("Light — populated") {
    NavigationSplitView {
        NotesListView(
            notes: .constant(Note.samples),
            selection: .constant(nil),
            onCreate: {},
            onDelete: { _ in }
        )
    } detail: { EmptyStateView() }
}

#Preview("Dark — populated") {
    NavigationSplitView {
        NotesListView(
            notes: .constant(Note.samples),
            selection: .constant(nil),
            onCreate: {},
            onDelete: { _ in }
        )
    } detail: { EmptyStateView() }
    .preferredColorScheme(.dark)
}

#Preview("XXL — empty") {
    NavigationSplitView {
        NotesListView(
            notes: .constant([]),
            selection: .constant(nil),
            onCreate: {},
            onDelete: { _ in }
        )
    } detail: { EmptyStateView() }
    .dynamicTypeSize(.accessibility3)
}
