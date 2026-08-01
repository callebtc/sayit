public func firstValueAlongAncestorChain<Element, Value>(
    from element: Element,
    maximumElementCount: Int = 64,
    value: (Element) -> Value?,
    parent: (Element) -> Element?
) -> Value? {
    var currentElement: Element? = element
    for _ in 0..<maximumElementCount {
        guard let current = currentElement else { return nil }
        if let value = value(current) {
            return value
        }
        currentElement = parent(current)
    }
    return nil
}
