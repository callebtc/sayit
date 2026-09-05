import AppKit
import SwiftUI

struct MenuPresentationObserver: NSViewRepresentable {
    let onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> PresentationTrackingView {
        PresentationTrackingView(onChange: onChange)
    }

    func updateNSView(
        _ nsView: PresentationTrackingView,
        context: Context
    ) {
        nsView.onChange = onChange
        nsView.reportPresentation()
    }

    static func dismantleNSView(
        _ nsView: PresentationTrackingView,
        coordinator: Void
    ) {
        nsView.stopObserving()
        nsView.onChange(false)
    }
}

@MainActor
final class PresentationTrackingView: NSView {
    var onChange: @MainActor (Bool) -> Void
    private var observations: [NSObjectProtocol] = []

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingWindow()
    }

    func reportPresentation() {
        let isPresented = window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
        onChange(isPresented)
    }

    func stopObserving() {
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
        observations.removeAll(keepingCapacity: true)
    }

    private func startObservingWindow() {
        stopObserving()
        guard let window else {
            onChange(false)
            return
        }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.willCloseNotification
        ] {
            observations.append(
                center.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] notification in
                    let isClosing = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        if isClosing {
                            self?.onChange(false)
                        } else {
                            self?.reportPresentation()
                        }
                    }
                }
            )
        }
        reportPresentation()
    }
}
