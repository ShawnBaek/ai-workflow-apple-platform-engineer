import SwiftUI

struct EmptyStateView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Select a note", systemImage: "doc.text")
        } description: {
            Text("Choose a note from the list, or create a new one.")
        }
    }
}

#Preview("Light") { EmptyStateView() }
#Preview("Dark") { EmptyStateView().preferredColorScheme(.dark) }
#Preview("XXL") { EmptyStateView().dynamicTypeSize(.accessibility3) }
