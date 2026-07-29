actor InterruptState {
    private var interrupted = false

    func markInterrupted() {
        interrupted = true
    }

    func consume() -> Bool {
        defer { interrupted = false }
        return interrupted
    }
}
