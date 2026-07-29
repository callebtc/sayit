import SayItCore
import SwiftUI

struct ModelsSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var searchText = ""
    @State private var isShowingCommunityModelSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.compactSpacing) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search models", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
            }
            .padding(.horizontal, DesignTokens.standardSpacing)
            .padding(.vertical, DesignTokens.compactSpacing)

            Divider()

            List(filteredModels) { model in
                ModelRowView(model: model)
            }
            .overlay {
                if filteredModels.isEmpty {
                    if searchText.isEmpty {
                        ContentUnavailableView(
                            "No models available",
                            systemImage: "shippingbox",
                            description: Text(
                                "Add a model or rescan to look for local models."
                            )
                        )
                    } else {
                        ContentUnavailableView(
                            "No models found",
                            systemImage: "magnifyingglass",
                            description: Text(
                                "No models match “\(searchText)”."
                            )
                        )
                    }
                }
            }

            Divider()

            HStack {
                Text(
                    "\(state.installedModelIDs.count) installed"
                )
                .foregroundStyle(.secondary)
                Spacer()
                Button(
                    "Add Hugging Face Model…",
                    action: showCommunityModelSheet
                )
                Button("Import Local Model…", action: state.importLocalModel)
                Button("Rescan", action: rescanModels)
            }
            .padding(DesignTokens.standardSpacing)
        }
        .sheet(isPresented: $isShowingCommunityModelSheet) {
            CommunityModelSheet()
                .environment(state)
        }
    }

    private var filteredModels: [ModelDescriptor] {
        guard !searchText.isEmpty else { return state.models }
        return state.models.filter {
            $0.displayName.localizedStandardContains(searchText)
                || $0.family.localizedStandardContains(searchText)
                || $0.languages.contains {
                    $0.localizedStandardContains(searchText)
                }
        }
    }

    private func showCommunityModelSheet() {
        isShowingCommunityModelSheet = true
    }

    private func rescanModels() {
        Task {
            await state.startup()
        }
    }
}
