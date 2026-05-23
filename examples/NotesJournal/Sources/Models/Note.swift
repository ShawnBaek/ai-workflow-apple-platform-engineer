import Foundation

struct Note: Identifiable, Hashable {
    let id: UUID
    var title: String
    var body: String
    var updatedAt: Date
    var tags: [String]

    var preview: String {
        body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
            .description
    }
}

extension Note {
    static let sample = Note(
        id: UUID(),
        title: "Morning pages",
        body: "Three things I'm grateful for:\n1. Quiet coffee\n2. The cat's stretch\n3. Sunlight through the blinds",
        updatedAt: Date(),
        tags: ["journal", "morning"]
    )

    static let samples: [Note] = [
        .sample,
        Note(
            id: UUID(),
            title: "App ideas",
            body: "A habit tracker that texts your friends when you skip. Probably terrible. Worth a weekend.",
            updatedAt: Date().addingTimeInterval(-3600),
            tags: ["ideas", "indie"]
        ),
        Note(
            id: UUID(),
            title: "Read later",
            body: "— HIG: Layout\n— Designing for Apple Watch\n— Materials and depth",
            updatedAt: Date().addingTimeInterval(-86_400),
            tags: ["links"]
        )
    ]
}
