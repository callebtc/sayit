import Foundation

@objc
public protocol SayItXPCProtocol {
    func perform(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    )
}
