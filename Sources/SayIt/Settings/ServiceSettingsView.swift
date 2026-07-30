import AppKit
import SayItProtocol
import ServiceManagement
import SwiftUI

struct ServiceSettingsView: View {
    @Environment(AppState.self) private var state
    @State private var httpEnabled = false
    @State private var httpPort = 59_125
    @State private var isCreatingToken = false
    @State private var tokenToRevoke: APITokenMetadata?

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Run Say It in the background",
                    isOn: backgroundServiceEnabled
                )
                .disabled(state.backgroundService.isWorking)

                LabeledContent("Registration") {
                    HStack(spacing: 6) {
                        if state.backgroundService.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(state.backgroundService.statusDescription)
                            .foregroundStyle(.secondary)
                    }
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
                    .disabled(
                        state.backgroundService.isWorking
                            || !state.backgroundService.isEnabled
                    )
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
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Background service")
            }

            Section {
                Toggle("Enable local automation API", isOn: $httpEnabled)
                    .onChange(of: httpEnabled) { _, _ in
                        updateHTTP()
                    }
                TextField(
                    "Port",
                    value: $httpPort,
                    format: .number.grouping(.never)
                )
                .frame(width: 110)
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
                        .buttonStyle(CircularIconButtonStyle(size: 22))
                    }
                }

                if let message = state.httpAPIErrorMessage {
                    Label(
                        "The local API was turned off. \(message)",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            } header: {
                Text("Local automation API")
            } footer: {
                Text(
                    "Optional. The Say It player and command-line tool do not use this API. It accepts requests only from this Mac and requires an access token."
                )
            }

            Section {
                if state.apiTokens.isEmpty {
                    Text("No access tokens")
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
                    "Create Access Token…",
                    systemImage: "plus",
                    action: showTokenCreation
                )
                if let message = state.apiTokenErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Automation access tokens")
            } footer: {
                Text(
                    "Only apps or scripts using the optional local automation API need a token."
                )
            }

            Section("Command line") {
                if let url = state.commandLineToolURL {
                    LabeledContent("Bundled tool") {
                        Text(url.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Link command") {
                        Text(linkCommand(for: url))
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label(
                        "The command-line tool is missing from this build.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.red)
                }
            }
        }
        .task {
            synchronize()
            state.refreshTokens()
        }
        .onChange(of: state.backendSettings) {
            synchronizeHTTPSettings()
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
            "Revoke this access token?",
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
        synchronizeHTTPSettings()
    }

    private func synchronizeHTTPSettings() {
        httpEnabled = state.backendSettings.httpEnabled
        httpPort = state.backendSettings.httpPort
    }

    private var backgroundServiceEnabled: Binding<Bool> {
        Binding(
            get: { state.backgroundService.isEnabled },
            set: { enabled in
                Task {
                    if enabled {
                        await state.backgroundService.enable()
                    } else {
                        await state.backgroundService.disable()
                    }
                }
            }
        )
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
        state.clearAPITokenError()
        isCreatingToken = true
    }

    private func linkCommand(for url: URL) -> String {
        "mkdir -p ~/.local/bin && ln -sf '\(url.path)' ~/.local/bin/sayit"
    }
}
