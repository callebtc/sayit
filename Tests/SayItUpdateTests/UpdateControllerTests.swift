import Foundation
import Sparkle
import Testing

@Suite(.serialized)
@MainActor
struct UpdateControllerTests {
    private func preferences() -> (UserDefaults, UpdatePreferences) {
        let defaults = UserDefaults(suiteName: "UpdateTests.\(UUID().uuidString)")!
        return (defaults, UpdatePreferences(defaults: defaults))
    }

    private let offer = UpdateOffer(build: "20", version: "1.2.0", notesURL: nil)

    @Test func backgroundOfferEndsSessionAndKeepsIndicator() {
        let (_, preferences) = preferences()
        let controller = UpdateController(preferences: preferences, presentsWindows: false)
        controller.isUserInteracting = { false }
        var replies: [SPUUserUpdateChoice] = []
        controller.receive(offer, userInitiated: false) { replies.append($0) }
        #expect(replies == [.dismiss])
        controller.dismissUpdateInstallation()
        #expect(controller.hasUpdate)
        #expect(controller.phase == .idle)
    }

    @Test func laterResolvesOnlyOnceAndSuppressesNextReminder() {
        let (_, preferences) = preferences()
        let controller = UpdateController(preferences: preferences, presentsWindows: false)
        var replies: [SPUUserUpdateChoice] = []
        controller.receive(offer, userInitiated: true) { replies.append($0) }
        controller.later()
        controller.later()
        #expect(replies == [.dismiss])
        #expect(!preferences.mayRemind)
        #expect(controller.hasUpdate)
    }

    @Test func manualCheckBypassesDisabledChecksAndReminder() {
        let (defaults, preferences) = preferences()
        defaults.set(false, forKey: "checkForUpdates")
        preferences.remindLater()
        let controller = UpdateController(preferences: preferences, presentsWindows: false)
        var replies: [SPUUserUpdateChoice] = []
        controller.receive(offer, userInitiated: true) { replies.append($0) }
        #expect(replies.isEmpty)
        controller.updateNow()
        controller.updateNow()
        #expect(replies == [.install])
    }

    @Test func updateNowPreparesThenInstallsWithoutSecondConfirmation() async throws {
        let controller = UpdateController(presentsWindows: false)
        var prepared = false
        controller.prepareForInstallation = { prepared = true }
        controller.receive(offer, userInitiated: true) { _ in }
        controller.updateNow()
        let result = await withCheckedContinuation { continuation in
            controller.showReady(toInstallAndRelaunch: { continuation.resume(returning: $0) })
        }
        #expect(prepared)
        #expect(result == .install)
        #expect(controller.phase == .installing)
    }

    @Test func preparationFailureCancelsInstallerAndRestoresServices() async {
        let controller = UpdateController(presentsWindows: false)
        var recovered = false
        controller.prepareForInstallation = { throw CocoaError(.fileWriteUnknown) }
        controller.recoverFromInstallationFailure = { recovered = true }
        controller.receive(offer, userInitiated: true) { _ in }
        controller.updateNow()
        let result = await withCheckedContinuation { continuation in
            controller.showReady(toInstallAndRelaunch: { continuation.resume(returning: $0) })
        }
        await Task.yield()
        #expect(result == .skip)
        #expect(recovered)
        #expect(controller.phase == .failed)
    }

    @Test func cancellationClearsConsentAndRunsOnce() async {
        let controller = UpdateController(presentsWindows: false)
        controller.receive(offer, userInitiated: true) { _ in }
        controller.updateNow()
        var cancellations = 0
        controller.showDownloadInitiated { cancellations += 1 }
        controller.cancel()
        controller.cancel()
        #expect(cancellations == 1)
        let result = await withCheckedContinuation { continuation in
            controller.showReady(toInstallAndRelaunch: { continuation.resume(returning: $0) })
        }
        #expect(result == .skip)
    }

    @Test func unknownAndIncorrectDownloadLengthsUseIndeterminateProgress() {
        let controller = UpdateController(presentsWindows: false)
        controller.showDownloadInitiated {}
        controller.showDownloadDidReceiveData(ofLength: 50)
        #expect(controller.progress == nil)
        controller.showDownloadDidReceiveExpectedContentLength(100)
        #expect(controller.progress == 0.5)
        controller.showDownloadDidReceiveData(ofLength: 100)
        #expect(controller.progress == nil)
        controller.showDownloadDidStartExtractingUpdate()
        #expect(!controller.canCancel)
    }

    @Test func informationalUpdateCannotInstall() {
        let controller = UpdateController(presentsWindows: false)
        var info = offer
        info.informationOnly = true
        var replies: [SPUUserUpdateChoice] = []
        controller.receive(info, userInitiated: true) { replies.append($0) }
        controller.updateNow()
        #expect(replies.isEmpty)
        controller.later()
        #expect(replies == [.dismiss])
    }

    @Test func taskDrainHasDeadline() async {
        let task = Task { try? await Task.sleep(for: .seconds(5)) }
        let pending = Task { _ = await task.value }
        await #expect(throws: UpdateTaskBarrier.BarrierError.self) {
            try await UpdateTaskBarrier.wait(for: [pending], until: Date.now.addingTimeInterval(0.05))
        }
        task.cancel()
        await pending.value
    }
}
