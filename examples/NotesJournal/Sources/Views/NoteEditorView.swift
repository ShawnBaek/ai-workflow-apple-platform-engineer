import SwiftUI

struct NoteEditorView: View {
    @Binding var note: Note
    let useCase: NotesUseCase
    @FocusState private var focus: Field?

    enum Field: Hashable { case title, body }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Title", text: $note.title, axis: .vertical)
                    .font(.largeTitle.weight(.semibold))
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .title)
                    .submitLabel(.next)
                    .onSubmit { focus = .body }

                HStack(spacing: 8) {
                    Image(systemName: "clock")
                        .imageScale(.small)
                    Text(note.updatedAt, format: .relative(presentation: .named))
                    if !note.tags.isEmpty {
                        Text("·")
                        ForEach(note.tags, id: \.self) { tag in
                            TagChip(text: tag)
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                Divider()

                TextEditor(text: $note.body)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .frame(minHeight: 240, alignment: .topLeading)
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
        .navigationTitle(note.title.isEmpty ? "Untitled" : note.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus = nil }
            }
            #endif
        }
        .onChange(of: note) { _, newValue in
            Task { await useCase.save(newValue) }
        }
    }
}

private struct TagChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.tint.opacity(0.15), in: Capsule())
            .foregroundStyle(.tint)
    }
}

#Preview("Light") {
    NavigationStack {
        NoteEditorView(note: .constant(.sample), useCase: MockNotesUseCase())
    }
}

#Preview("Dark") {
    NavigationStack {
        NoteEditorView(note: .constant(.sample), useCase: MockNotesUseCase())
    }
    .preferredColorScheme(.dark)
}

#Preview("XXL") {
    NavigationStack {
        NoteEditorView(note: .constant(.sample), useCase: MockNotesUseCase())
    }
    .dynamicTypeSize(.accessibility3)
}
