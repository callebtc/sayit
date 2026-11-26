/// Mono reference audio plus its transcript, in adapter-neutral form.
struct SpeechModelReference: Sendable {
    let samples: [Float]
    let transcript: String?

    init(samples: [Float], transcript: String?) {
        self.samples = samples
        self.transcript = transcript
    }
}
