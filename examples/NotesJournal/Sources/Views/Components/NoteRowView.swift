import SwiftUI

struct NoteRowView: View {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.title.isEmpty ? "Untitled" : note.title)
                .font(.headline)
                .foregroundStyle(note.title.isEmpty ? .secondary : .primary)
                .lineLimit(1)

            if !note.preview.isEmpty {
                Text(note.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Label {
                    Text(note.updatedAt, format: .relative(presentation: .named))
                } icon: {
                    Image(systemName: "clock")
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.tertiary)

                ForEach(note.tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .foregroundStyle(.tint)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview("Light") {
    List { ForEach(Note.samples) { NoteRowView(note: $0) } }
}

#Preview("Dark") {
    List { ForEach(Note.samples) { NoteRowView(note: $0) } }
        .preferredColorScheme(.dark)
}

#Preview("XXL") {
    List { ForEach(Note.samples) { NoteRowView(note: $0) } }
        .dynamicTypeSize(.accessibility3)
}
