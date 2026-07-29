import AppKit
import SayItProtocol
import ServiceManagement
import SwiftUI

struct ServiceSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var backgroundEnabled = false
    @State private var httpEnabled = false
    @State private var httpPort = 59_125
    @State private var isCreatingToken = false
    @State private var tokenToRevoke: APITokenMetadata?

    var body: some View {
        SettingsPage(
            title: "Service",
            subtitle: "Keep speech available to Say It and trusted automation."
        ) {
            Form {
                Section("Background service") {
                    Toggle(
                        "Run Say It in the background",
                        isOn: $backgroundEnabled
                    )
                    .onChange(of: backgroundEnabled) { _, enabled in
                        updateBackgroundService(enabled)
                    }

                    LabeledContent("Registration") {
                        Text(state.backgroundService.statusDescription)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Connection") {
                        Text(state.serviceConnection.label)
                            .foregroundStyle(.secondary)
                    }
                    if case .online(let version) = state.serviceConnection {
                        LabeledContent("Service version", value: version)
                    }

                    HStack {
                        Button(
                            "Restart Service",
                            systemImage: "arrow.clockwise",
                            action: state.restartBackgroundService
                        )
                        .disabled(!backgroundEnabled)
                        if state.backgroundService.status == .requiresApproval {
                            Button(
                                "Open Login Items",
                                action: state.backgroundService
                                    .openLoginItemsSettings
                            )
                        }
                    }

                    if let message = state.backgroundService.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section("Local HTTP API") {
                    Toggle("Enable HTTP API", isOn: $httpEnabled)
                        .onChange(of: httpEnabled) { _, _ in
                            updateHTTP()
                        }
                    TextField(
                        "Port",
                        value: $httpPort,
                        format: .number.grouping(.never)
                    )
                    .frame(width: 110)
                    .disabled(!httpEnabled)
                    .onSubmit(updateHTTP)

                    LabeledContent("Base URL") {
                        HStack {
                            Text(baseURL)
                                .textSelection(.enabled)
                            Button(
                                "Copy",
                                systemImage: "doc.on.doc",
                                action: copyBaseURL
                            )
                            .labelStyle(.iconOnly)
                        }
                    }

                    Text(
                        "The API listens only on this Mac’s loopback interface. Requests require a scoped bearer token."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section("API tokens") {
                    if state.apiTokens.isEmpty {
                        Text("No API tokens")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.apiTokens) { token in
                        APITokenRow(
                            token: token,
                            onRevoke: {
                                tokenToRevoke = token
                            }
                        )
                    }
                    Button(
                        "Create Token…",
                        systemImage: "plus",
                        action: showTokenCreation
                    )
                }

                Section("Command line") {
                    if let url = state.commandLineToolURL {
                        LabeledContent("Bundled tool") {
                            Text(url.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Link command") {
                            Text(linkCommand(for: url))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    } else {
                        Label(
                            "The command-line tool is missing from this build.",
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                }
            }
        }
        .task {
            synchronize()
            state.refreshTokens()
        }
        .sheet(isPresented: $isCreatingToken) {
            TokenCreationSheet()
                .environment(state)
        }
        .sheet(isPresented: oneTimeSecretPresented) {
            OneTimeTokenSecretView()
                .environment(state)
        }
        .confirmationDialog(
            "Revoke this API token?",
            isPresented: revokeConfirmationPresented,
            presenting: tokenToRevoke
        ) { token in
            Button("Revoke \(token.name)", role: .destructive) {
                state.revokeToken(token)
                tokenToRevoke = nil
            }
        } message: { token in
            Text("Apps using \(token.prefix)… will immediately lose access.")
        }
    }

    private var baseURL: String {
        "http://127.0.0.1:\(httpPort)"
    }

    private var oneTimeSecretPresented: Binding<Bool> {
        Binding(
            get: { state.oneTimeTokenSecret != nil },
            set: { presented in
                if !presented {
                    state.dismissOneTimeToken()
                }
            }
        )
    }

    private var revokeConfirmationPresented: Binding<Bool> {
        Binding(
            get: { tokenToRevoke != nil },
            set: { presented in
                if !presented {
                    tokenToRevoke = nil
                }
            }
        )
    }

    private func synchronize() {
        state.backgroundService.refresh()
        backgroundEnabled = state.backgroundService.isEnabled
        httpEnabled = state.backendSettings.httpEnabled
        httpPort = state.backendSettings.httpPort
    }

    private func updateBackgroundService(_ enabled: Bool) {
        if enabled {
            state.backgroundService.enable()
            backgroundEnabled = state.backgroundService.isEnabled
        } else {
            Task {
                await state.backgroundService.disable()
                backgroundEnabled = state.backgroundService.isEnabled
            }
        }
    }

    private func updateHTTP() {
        guard (1_024...65_535).contains(httpPort) else { return }
        state.updateHTTP(enabled: httpEnabled, port: httpPort)
    }

    private func copyBaseURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(baseURL, forType: .string)
    }

    private func showTokenCreation() {
        isCreatingToken = true
    }

    private func linkCommand(for url: URL) -> String {
        "mkdir -p ~/.local/bin && ln -sf '\(url.path)' ~/.local/bin/sayit"
    }
}
