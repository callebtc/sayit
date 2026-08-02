public struct HTTPServiceConfiguration: Equatable, Sendable {
    public let isEnabled: Bool
    public let port: Int

    public init(isEnabled: Bool, port: Int) {
        self.isEnabled = isEnabled
        self.port = port
    }
}
