import SayItCore
import SwiftUI

struct SpeechSettingsView: View {
    @Environment(AppState.self) private var state
    @Bindable var settings: AppSettings

    var body: some View {
        SettingsPage(
            title: "Speech",
            subtitle: "Choose how new speech is generated and played."
        ) {
            Form {
                Section("Voice generation") {
                    Picker("Model", selection: $settings.activeModelID) {
                        ForEach(selectableInstalledModels) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .onChange(of: settings.activeModelID) { _, id in
                        selectModel(id)
                    }

                    if let model = activeModel, !model.voices.isEmpty {
                        Picker("Voice", selection: $settings.activeVoice) {
                            ForEach(model.voices, id: \.self) { voice in
                                Text(voice).tag(voice)
                            }
                        }
                        .onChange(of: settings.activeVoice) { _, voice in
                            updateLanguage(for: voice, model: model)
                        }
                    }

                    if let model = activeModel,
                       model.capabilities.languageSelection {
                        Picker("Language", selection: $settings.activeLanguage) {
                            ForEach(model.languages, id: \.self) { language in
                                Text(Locale.current.localizedString(
                                    forLanguageCode: language
                                ) ?? language).tag(language)
                            }
                        }
                    }

                    if let model = activeModel,
                       model.capabilities.voiceDescription {
                        TextField(
                            "Voice description",
                            text: $settings.voiceDescription,
                            axis: .vertical
                        )
                        .lineLimit(3...6)
                    }

                    Picker("Speaking pace", selection: $settings.speakingPace) {
                        ForEach(SpeakingPace.allCases) { pace in
                            Text(speakingPaceLabel(pace)).tag(pace)
                        }
                    }
                    .disabled(activeModel?.supportsNativeSpeakingPace != true)

                    Text(speakingPaceExplanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section("Playback") {
                    Picker("Playback speed", selection: $settings.playbackRate) {
                        ForEach([0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) {
                            Text(
                                $0,
                                format: .number.precision(.fractionLength(0...2))
                            )
                            .tag($0)
                        }
                    }
                    .onChange(of: settings.playbackRate) { _, rate in
                        updatePlaybackRate(rate)
                    }

                    Text(
                        "Changes listening speed instantly without regenerating audio."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    Toggle(
                        "Show titles in system media controls",
                        isOn: $settings.showNowPlayingTitles
                    )
                    .onChange(
                        of: settings.showNowPlayingTitles
                    ) { _, showTitles in
                        updateNowPlayingTitleVisibility(showTitles)
                    }
                }
            }

            SpeechPreviewView()
        }
    }

    private var selectableInstalledModels: [ModelDescriptor] {
        state.models.filter {
            state.installedModelIDs.contains($0.id) && $0.isSelectable
        }
    }

    private var activeModel: ModelDescriptor? {
        state.models.first { $0.id == settings.activeModelID }
    }

    private func selectModel(_ id: ModelID) {
        guard let model = state.models.first(where: { $0.id == id }) else {
            return
        }
        state.selectModel(model)
    }

    private func updateLanguage(
        for voice: String,
        model: ModelDescriptor
    ) {
        state.updateLanguageForVoice(voice, model: model)
    }

    private func updatePlaybackRate(_ rate: Double) {
        state.playback.rate = rate
    }

    private func updateNowPlayingTitleVisibility(_ showTitles: Bool) {
        state.playback.showTitleInNowPlaying = showTitles
    }

    private var speakingPaceExplanation: String {
        if activeModel?.supportsNativeSpeakingPace == true {
            "Shapes phoneme timing while generating new audio. Existing history is unchanged."
        } else {
            "The selected model does not expose native speaking pace. New audio uses its natural pace."
        }
    }

    private func speakingPaceLabel(_ pace: SpeakingPace) -> String {
        let rate = pace.rawValue.formatted(
            .number.precision(.fractionLength(0...2))
        )
        let description = switch pace {
        case .slower:
            "Slower"
        case .slow:
            "Slow"
        case .natural:
            "Natural"
        case .brisk:
            "Brisk"
        case .fast:
            "Fast"
        case .faster:
            "Faster"
        }
        return "\(description) · \(rate)×"
    }
}
