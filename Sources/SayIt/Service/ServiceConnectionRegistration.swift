@MainActor
protocol ServiceConnectionRegistration {
    var isUserDisabled: Bool { get }
    var isWorking: Bool { get }
    var requiresApproval: Bool { get }
    var errorMessage: String? { get }
    func setUserDisabled(_ disabled: Bool)
    func refresh()
    func ensureRunning() async
    func enable() async
    func disable() async
    func restart() async
}

extension BackgroundServiceController: ServiceConnectionRegistration {}
