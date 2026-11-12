extension ModelDescriptor {
    public var supportsPhononVoiceImport: Bool {
        ["phonon", "gradium_phonon_tts"].contains(modelType.lowercased())
    }
}
