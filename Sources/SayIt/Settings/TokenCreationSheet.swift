import SayItProtocol
import SwiftUI

struct TokenCreationSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var preset = APITokenPreset.speechControl
    @State private var scopes = APITokenPreset.speechControl.scopes
    @State private var usesCustomScopes = false
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Create API Token")
                .font(.title2)
                .bold()
                .accessibilityAddTraits(.isHeader)

            Form {
                TextField("Token name", text: $name)

                Picker("Access", selection: $preset) {
                    Text("Read Only").tag(APITokenPreset.readOnly)
                    Text("Speech Control").tag(APITokenPreset.speechControl)
                    Text("Full Access").tag(APITokenPreset.fullAccess)
                }
                .disabled(usesCustomScopes)
                .onChange(of: preset) { _, preset in
                    scopes = preset.scopes
                }

                Toggle("Choose individual scopes", isOn: $usesCustomScopes)

                if usesCustomScopes {
                    ForEach(APITokenScope.allCases, id: \.self) { scope in
                        Toggle(
                            scope.title,
                            isOn: scopeBinding(scope)
                        )
                    }
                }

                Text(
                    "The secret is shown once. Say It stores only a one-way digest."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Create Token") {
                    create()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty || scopes.isEmpty || isCreating
                )
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func scopeBinding(_ scope: APITokenScope) -> Binding<Bool> {
        Binding(
            get: { scopes.contains(scope) },
            set: { enabled in
                if enabled {
                    scopes.insert(scope)
                } else {
                    scopes.remove(scope)
                }
            }
        )
    }

    private func create() {
        isCreating = true
        Task {
            let created = await state.createToken(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                scopes: scopes
            )
            isCreating = false
            if created {
                dismiss()
            }
        }
    }
}
