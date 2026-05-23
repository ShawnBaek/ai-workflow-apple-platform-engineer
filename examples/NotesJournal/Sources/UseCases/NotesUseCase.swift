import Foundation

protocol NotesUseCase: Sendable {
    func loadNotes() async -> [Note]
    func save(_ note: Note) async
    func delete(_ id: Note.ID) async
}
