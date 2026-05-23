#if os(watchOS)
import SwiftUI

struct WatchNotesListView: View {
    @Binding var notes: [Note]

    var body: some View {
        NavigationStack {
            List(notes) { note in
                NavigationLink(value: note) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(note.title.isEmpty ? "Untitled" : note.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(note.updatedAt, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Journal")
            .navigationDestination(for: Note.self) { note in
                ScrollView {
                    Text(note.body)
                        .font(.body)
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle(note.title.isEmpty ? "Untitled" : note.title)
            }
        }
    }
}

#Preview {
    WatchNotesListView(notes: .constant(Note.samples))
}
#endif
