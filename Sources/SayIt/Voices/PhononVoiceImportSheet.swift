import SayItCore
import SwiftUI
import UniformTypeIdentifiers

struct PhononVoiceImportSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    let model: ModelDescriptor

    @State private var isChoosingFile = false
    @State private var data: Data?
    @State private var filename = ""
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import Phonon Voice")
                .font(.title2.weight(.semibold))
            Text("Choose a voice file exported using “Download for Phonon” in Gradium. Say It saves its own copy for offline use.")
                .foregroundStyle(.secondary)
            Button(filename.isEmpty ? "Choose Voice File…" : "Choose Another File…", action: chooseFile)
                .disabled(isImporting)
            if !filename.isEmpty {
                Text(filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            TextField("Voice name", text: $name)
                .disabled(isImporting)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                if isImporting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .disabled(isImporting)
                Button("Import", action: importVoice)
                    .keyboardShortcut(.defaultAction)
                    .disabled(data == nil || !(1...50).contains(trimmedName.count) || isImporting)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [UTType(filenameExtension: "safetensors") ?? .data],
            onCompletion: fileChosen
        )
        .interactiveDismissDisabled(isImporting)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func chooseFile() { isChoosingFile = true }

    private func fileChosen(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            data = nil
            filename = ""
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard url.pathExtension.lowercased() == "safetensors",
                  let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (1...8 * 1024 * 1024).contains(size) else {
                errorMessage = "Choose a Phonon .safetensors voice file no larger than 8 MB."
                return
            }
            let contents = try Data(contentsOf: url)
            guard contents.count <= 8 * 1024 * 1024 else {
                errorMessage = "The voice file is too large."
                return
            }
            data = contents
            filename = url.lastPathComponent
            if name.isEmpty { name = String(url.deletingPathExtension().lastPathComponent.prefix(50)) }
            errorMessage = nil
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importVoice() {
        guard let data, !isImporting else { return }
        isImporting = true
        Task {
            let imported = await state.importPhononVoice(
                modelID: model.id.rawValue, name: trimmedName, data: data
            )
            isImporting = false
            if imported {
                dismiss()
            } else {
                errorMessage = state.errorMessage ?? "The voice could not be imported."
            }
        }
    }
}
