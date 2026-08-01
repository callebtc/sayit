import SayItCore
import SwiftUI

struct ModelsSettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var isExperimentalExpanded = false
    @State private var isShowingCommunityModelSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search models", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, DesignTokens.standardSpacing)
            .padding(.vertical, DesignTokens.compactSpacing)

            Divider()

            List {
                if !recommendedModels.isEmpty {
                    Section("Recommended") {
                        ForEach(recommendedModels) { model in
                            ModelRowView(model: model)
                        }
                    }
                }

                if !stableModels.isEmpty {
                    Section("Available") {
                        ForEach(stableModels) { model in
                            ModelRowView(model: model)
                        }
                    }
                }

                if !experimentalModels.isEmpty {
                    if isSearching {
                        Section("Experimental") {
                            ForEach(experimentalModels) { model in
                                ModelRowView(model: model)
                            }
                        }
                    } else {
                        Section {
                            ModelDisclosureRow(
                                isExpanded: $isExperimentalExpanded,
                                count: experimentalModels.count
                            )
                            if isExperimentalExpanded {
                                ForEach(experimentalModels) { model in
                                    ModelRowView(model: model)
                                        .transition(
                                            .opacity.combined(
                                                with: .move(edge: .top)
                                            )
                                        )
                                }
                            }
                        }
                    }
                }

                if !unsupportedModels.isEmpty {
                    Section("Not supported") {
                        ForEach(unsupportedModels) { model in
                            ModelRowView(model: model)
                        }
                    }
                }
            }
            .animation(
                reduceMotion ? nil : DesignTokens.smoothAnimation,
                value: isExperimentalExpanded
            )
            .overlay {
                if matchingModels.isEmpty {
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
                Text("\(state.installedModelIDs.count) installed")
                    .font(.caption)
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

    private var rankedModels: [ModelDescriptor] {
        state.models.enumerated().sorted { left, right in
            let leftRank = left.element.experience?.recommendationRank
                ?? 10_000 + left.offset
            let rightRank = right.element.experience?.recommendationRank
                ?? 10_000 + right.offset
            return leftRank < rightRank
        }.map(\.element)
    }

    private var matchingModels: [ModelDescriptor] {
        guard isSearching else { return rankedModels }
        return rankedModels.filter {
            $0.displayName.localizedStandardContains(searchQuery)
                || $0.family.localizedStandardContains(searchQuery)
                || ($0.experience?.note?.localizedStandardContains(
                    searchQuery
                ) ?? false)
                || ($0.experience?.speed.displayName
                    .localizedStandardContains(searchQuery) ?? false)
                || $0.languages.contains {
                    $0.localizedStandardContains(searchQuery)
                }
        }
    }

    private var recommendedModels: [ModelDescriptor] {
        matchingModels.filter { $0.stability == .recommended }
    }

    private var experimentalModels: [ModelDescriptor] {
        matchingModels.filter { $0.stability == .experimental }
    }

    private var stableModels: [ModelDescriptor] {
        matchingModels.filter { $0.stability == .stable }
    }

    private var unsupportedModels: [ModelDescriptor] {
        matchingModels.filter { $0.stability == .unavailable }
    }

    private var isSearching: Bool {
        !searchQuery.isEmpty
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
