import SwiftUI

struct UpdateView: View {
    let controller: UpdateController

    private var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Software Update", systemImage: "arrow.down.circle")
                .font(.title2.bold())
            Text(controller.status)
                .font(.headline)
                .accessibilityAddTraits(.updatesFrequently)

            if controller.phase == .available {
                Text("You have Say It \(installedVersion).")
                    .foregroundStyle(.secondary)
                if !controller.informationOnly {
                    Text("Say It will download the update, stop active speech and recording, and restart automatically.")
                }
                if let url = controller.releaseNotesURL {
                    Link("Release Notes", destination: url)
                }
            }

            if controller.phase.isBusy {
                if let progress = controller.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel(controller.status)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(controller.status)
                }
                if controller.phase == .downloading {
                    Text("You can keep using Say It while the update downloads.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                if controller.phase == .available {
                    Button("Later", action: controller.later)
                        .keyboardShortcut(.cancelAction)
                    if !controller.informationOnly {
                        Button("Update Now", action: controller.updateNow)
                            .keyboardShortcut(.defaultAction)
                    }
                } else if controller.canCancel {
                    Button("Cancel", action: controller.cancel)
                        .keyboardShortcut(.cancelAction)
                } else if !controller.phase.isBusy {
                    Button("Close", action: controller.closeMessage)
                        .keyboardShortcut(.cancelAction)
                    if controller.phase == .failed {
                        Button("Try Again") {
                            controller.closeMessage()
                            controller.checkForUpdates()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 440, height: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
