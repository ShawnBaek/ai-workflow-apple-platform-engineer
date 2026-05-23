import Foundation

actor MockNotesUseCase: NotesUseCase {
    private var store: [Note] = Note.samples

    func loadNotes() async -> [Note] {
        store.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ note: Note) async {
        var updated = note
        updated.updatedAt = Date()
        if let index = store.firstIndex(where: { $0.id == note.id }) {
            store[index] = updated
        } else {
            store.append(updated)
        }
    }

    func delete(_ id: Note.ID) async {
        store.removeAll { $0.id == id }
    }
}
