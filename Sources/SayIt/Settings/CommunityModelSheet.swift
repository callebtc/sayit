import SwiftUI

struct CommunityModelSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var repository = ""
    @State private var revision = ""
    @State private var token = ""
    @State private var isResolving = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.generousSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Hugging Face Model")
                    .font(.title2)
                    .bold()
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Community models must use a model type supported by MLX Audio Swift 0.1.3."
                )
                .foregroundStyle(.secondary)
            }

            Form {
                TextField(
                    "Repository",
                    text: $repository,
                    prompt: Text("owner/repository")
                )
                TextField(
                    "Revision",
                    text: $revision,
                    prompt: Text("main")
                )
                SecureField(
                    "Hugging Face Token",
                    text: $token,
                    prompt: Text("Optional for gated models")
                )
                Text(
                    "Say It resolves the revision to an immutable commit before downloading. Tokens are stored only in Keychain. Community models are untested and require license review."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel, action: dismiss.callAsFunction)
                Spacer()
                if isResolving {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Add Model", action: addModel)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        repository.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty || isResolving
                    )
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func addModel() {
        isResolving = true
        Task {
            let success = await state.addCommunityModel(
                repository: repository,
                revision: revision,
                token: token
            )
            isResolving = false
            if success {
                dismiss()
            }
        }
    }
}
