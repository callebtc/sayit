import SwiftUI

struct HistoryView: View {
    @Environment(AppState.self) private var state
    @State private var searchText = ""
    @State private var selection: UUID?
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationSplitView {
            List(filteredItems, selection: $selection) { item in
                HistoryRowView(item: item)
                    .tag(item.id)
            }
            .searchable(text: $searchText, prompt: "Search history")
            .overlay {
                if filteredItems.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "No history yet",
                            systemImage: "waveform",
                            description: Text("Items you speak appear here.")
                        )
                    } else {
                        ContentUnavailableView.search
                    }
                }
            }
            .navigationTitle("History")
        } detail: {
            if let selectedItem {
                HistoryDetailView(
                    item: selectedItem,
                    isConfirmingDelete: $isConfirmingDelete
                )
            } else {
                ContentUnavailableView(
                    "Choose an item",
                    systemImage: "text.page",
                    description: Text("Replay, export, or regenerate saved speech.")
                )
            }
        }
    }

    private var filteredItems: [HistoryItemSnapshot] {
        state.history.search(searchText)
    }

    private var selectedItem: HistoryItemSnapshot? {
        guard let selection else { return nil }
        return state.history.items.first { $0.id == selection }
    }
}
