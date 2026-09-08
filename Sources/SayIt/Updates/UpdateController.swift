import AppKit
import Observation
import Sparkle
import SwiftUI

@MainActor
@Observable
final class UpdateController: NSObject, NSWindowDelegate {
    private(set) var phase: UpdatePhase = .idle
    private(set) var status = "Not checked yet"
    private(set) var availableVersion: String?
    private(set) var releaseNotesURL: URL?
    private(set) var progress: Double?
    private(set) var canCancel = false
    private(set) var informationOnly = false

    @ObservationIgnored private let presentsWindows: Bool
    @ObservationIgnored private var needsRecovery = false
    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private let preferences: UpdatePreferences
    @ObservationIgnored private var choice: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var cancellation: (() -> Void)?
    @ObservationIgnored private var acknowledgement: (() -> Void)?
    @ObservationIgnored private var availableBuild: String?
    @ObservationIgnored private var acceptedBuild: String?
    @ObservationIgnored private var receivedBytes: Double = 0
    @ObservationIgnored private var expectedBytes: Double = 0
    @ObservationIgnored private var userInitiated = false
    @ObservationIgnored private var preparationTask: Task<Void, Never>?

    @ObservationIgnored var prepareForInstallation: () async throws -> Void = {}
    @ObservationIgnored var recoverFromInstallationFailure: () async -> Void = {}
    @ObservationIgnored var isUserInteracting: () -> Bool = { NSApp.isActive }

    init(preferences: UpdatePreferences = UpdatePreferences(), presentsWindows: Bool = true) {
        self.preferences = preferences
        self.presentsWindows = presentsWindows
        super.init()
    }

    var hasUpdate: Bool { availableVersion != nil }

    func start() {
        guard updater == nil else { return }
        #if DEBUG || SAYIT_LOCAL_BUILD || SAYIT_MODEL_AUDIT_BUILD
        phase = .unavailable
        status = "Updates are unavailable in development builds"
        return
        #else
        let location = Bundle.main.bundleURL
        let volume = try? location.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if volume?.volumeIsReadOnly == true || location.pathComponents.contains("AppTranslocation") {
            phase = .unavailable
            status = "Move Say It to Applications, then reopen it to install updates."
            return
        }
        preferences.migrate()
        #if SAYIT_UPDATE_TEST_BUILD
        let permitsLoopbackFeed = Bundle.main.bundleIdentifier == "sh.sayit.mac.update-test"
        #else
        let permitsLoopbackFeed = false
        #endif
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed),
              (url.scheme == "https" || (permitsLoopbackFeed && url.scheme == "http" && url.host == "127.0.0.1")),
              url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            phase = .unavailable
            status = "Update feed is not configured"
            return
        }
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: self
        )
        self.updater = updater
        do {
            try updater.start()
        } catch {
            self.updater = nil
            phase = .unavailable
            status = "The updater could not start. Reopen Say It to try again."
        }
        #endif
    }

    func setAutomaticChecks(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
        if !enabled, !userInitiated, phase == .available {
            resolveChoice(.dismiss)
            window?.orderOut(nil)
        }
    }

    func checkForUpdates() {
        guard !phase.isBusy, choice == nil else {
            showWindow()
            return
        }
        guard let updater else {
            showWindow()
            return
        }
        guard updater.canCheckForUpdates else { return }
        userInitiated = true
        updater.checkForUpdates()
    }

    /// A deferred background offer never holds Sparkle's session open.
    /// Recheck on interaction so we do not offer a withdrawn or superseded build.
    func userDidInteract() {
        guard hasUpdate, preferences.mayRemind, !phase.isBusy,
              choice == nil, window?.isVisible != true else { return }
        checkForUpdates()
    }

    func updateNow() {
        guard !phase.isBusy else { showWindow(); return }
        guard !informationOnly else { return }
        if choice != nil {
            acceptedBuild = availableBuild
            resolveChoice(.install)
        } else if let build = availableBuild, !phase.isBusy {
            acceptedBuild = build
            checkForUpdates()
        }
    }

    func later() {
        preferences.remindLater()
        acceptedBuild = nil
        resolveChoice(.dismiss)
        phase = .idle
        window?.orderOut(nil)
    }

    func cancel() {
        acceptedBuild = nil
        let cancel = cancellation
        cancellation = nil
        canCancel = false
        cancel?()
    }

    func closeMessage() {
        let acknowledge = acknowledgement
        acknowledgement = nil
        acknowledge?()
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if phase == .available { later(); return false }
        if phase.isBusy {
            // Closing progress hides it; cancellation is always explicit.
            sender.orderOut(nil)
            return false
        }
        closeMessage()
        return false
    }

    private func resolveChoice(_ result: SPUUserUpdateChoice) {
        let reply = choice
        choice = nil
        reply?(result)
    }

    func showWindow() {
        guard presentsWindows else { return }
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Software Update"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: UpdateView(controller: self))
            window.center()
            self.window = window
        }
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension UpdateController: SPUUserDriver {
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: preferences.automaticallyChecks, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        canCancel = true
        phase = .checking
        status = "Checking for updates…"
        showWindow()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let offer = UpdateOffer(
            build: appcastItem.versionString,
            version: appcastItem.displayVersionString,
            notesURL: Self.httpsURL(appcastItem.infoURL ?? appcastItem.releaseNotesURL),
            informationOnly: appcastItem.isInformationOnlyUpdate
        )
        receive(offer, userInitiated: state.userInitiated) { [weak self] choice in
            // A resumed installer still needs helper preparation in this process.
            if choice == .install && state.stage == .installing {
                self?.showReady(toInstallAndRelaunch: reply)
            } else {
                reply(choice)
            }
        }
    }

    func receive(_ offer: UpdateOffer, userInitiated: Bool, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancellation = nil
        canCancel = false
        availableBuild = offer.build
        availableVersion = offer.version
        releaseNotesURL = offer.notesURL
        informationOnly = offer.informationOnly
        status = "Say It \(offer.version) is available"
        phase = .available
        self.userInitiated = userInitiated
        if !userInitiated && (!preferences.mayRemind || !isUserInteracting()) {
            acceptedBuild = nil
            reply(.dismiss)
            return
        }
        choice = reply
        if acceptedBuild == offer.build && !informationOnly {
            resolveChoice(.install)
        } else {
            acceptedBuild = nil
            showWindow()
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        availableVersion = nil
        availableBuild = nil
        acceptedBuild = nil
        cancellation = nil
        canCancel = false
        phase = .current
        status = (error as NSError).localizedDescription
        self.acknowledgement = acknowledgement
        showWindow()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acceptedBuild = nil
        cancellation = nil
        canCancel = false
        phase = .failed
        // Do not expose installer paths or raw launchctl output in the dialog.
        switch (error as NSError).code {
        case Int(SUError.signatureError.rawValue), Int(SUError.validationError.rawValue):
            status = "The update couldn’t be verified. Your installed app is unchanged. Check for updates again to retry the download."
        case Int(SUError.runningFromDiskImageError.rawValue), Int(SUError.runningTranslocated.rawValue):
            status = "Move Say It to Applications, then reopen it to install updates."
        case Int(SUError.installationCanceledError.rawValue), Int(SUError.authenticationFailure.rawValue):
            status = "Installation was canceled or couldn’t be authorized. Check for updates when you’re ready to try again."
        default:
            status = "The update couldn’t be completed. Check your connection and try again. If this keeps happening, quit and reopen Say It."
        }
        self.acknowledgement = acknowledgement
        showWindow()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
        canCancel = true
        receivedBytes = 0
        expectedBytes = 0
        progress = nil
        phase = .downloading
        status = "Downloading update…"
        showWindow()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = Double(expectedContentLength)
        updateDownloadProgress()
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += Double(length)
        updateDownloadProgress()
    }

    private func updateDownloadProgress() {
        progress = expectedBytes > 0 && receivedBytes <= expectedBytes
            ? receivedBytes / expectedBytes : nil
    }

    func showDownloadDidStartExtractingUpdate() {
        cancellation = nil
        canCancel = false
        progress = nil
        phase = .extracting
        status = "Verifying and preparing update…"
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        self.progress = progress.isFinite ? min(1, max(0, progress)) : nil
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard acceptedBuild != nil else {
            reply(.skip)
            return
        }
        phase = .preparing
        status = "Stopping background services…"
        progress = nil
        preparationTask = Task { [weak self] in
            guard let self else { reply(.skip); return }
            do {
                needsRecovery = true
                try await prepareForInstallation()
                try Task.checkCancellation()
                phase = .installing
                status = "Installing and restarting Say It…"
                reply(.install)
            } catch {
                reply(.skip)
                await recoverIfNeeded()
                phase = .failed
                status = "Say It couldn’t stop its background services. The update was canceled. Try again when active work has finished."
                showWindow()
            }
            preparationTask = nil
        }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        phase = .installing
        status = "Installing and restarting Say It…"
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        acceptedBuild = nil
        choice = nil
        cancellation = nil
        acknowledgement = nil
        canCancel = false
        progress = nil
        if phase != .failed && phase != .current {
            phase = .idle
            window?.orderOut(nil)
        }
        userInitiated = false
    }

    func showUpdateInFocus() { showWindow() }

    private static func httpsURL(_ url: URL?) -> URL? {
        guard let url, url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

extension UpdateController: SPUUpdaterDelegate {
    private func recoverIfNeeded() async {
        guard needsRecovery else { return }
        needsRecovery = false
        await recoverFromInstallationFailure()
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Task { await recoverIfNeeded() }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error, (error as NSError).code == SUError.noUpdateError.rawValue {
            availableVersion = nil
            availableBuild = nil
            status = "Up to date"
        }
    }
}
