import Foundation

@objc
public protocol SelectionXPCProtocol {
    func perform(
        _ request: Data,
        withReply reply: @escaping @Sendable (Data) -> Void
    )
}
