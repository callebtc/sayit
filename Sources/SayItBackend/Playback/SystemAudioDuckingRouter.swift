import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Lowers every other app's audio by tapping it with a Core Audio process tap,
/// muting the originals, and replaying them attenuated to the default output.
///
/// Say It's own processes are excluded from the tap, so speech is untouched.
/// The tap starts unmuted and only mutes once it delivers real samples: without
/// System Audio Recording permission a tap delivers silence, and muting then
/// would silence other apps instead of lowering them.
/// Taps and the private aggregate device are owned by this process, so macOS
/// restores the original audio if the process exits unexpectedly.
@MainActor
final class SystemAudioDuckingRouter: OtherAudioRouting {
    static let signalPollInterval: DispatchTimeInterval = .milliseconds(20)

    nonisolated static let excludedBundleIDPrefix = "sh.sayit."

    private let renderState: DuckingRenderState
    private let queue = DispatchQueue(
        label: "sh.sayit.ducking-io",
        qos: .userInteractive
    )
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var signalTimer: DispatchSourceTimer?
    private var outputDeviceListener: AudioObjectPropertyListenerBlock?
    var onOutputDeviceChange: (@MainActor () -> Void)?

    /// Starts replaying other audio at full volume; call `setGain` to duck.
    init() throws {
        renderState = DuckingRenderState()
        do {
            try start()
        } catch {
            stop()
            throw error
        }
    }

    func setGain(_ gain: Float, rampDuration: TimeInterval) {
        renderState.setTarget(gain, rampDuration: rampDuration)
    }

    func stop() {
        signalTimer?.cancel()
        signalTimer = nil
        if let outputDeviceListener {
            var address = Self.defaultOutputDeviceAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                .main,
                outputDeviceListener
            )
            self.outputDeviceListener = nil
        }
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func start() throws {
        let excluded = try Self.sayItProcessObjects()
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: excluded
        )
        description.uuid = UUID()
        description.name = "Say It ducking"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        tapDescription = description

        try check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "create the audio tap"
        )
        let tapFormat: AudioStreamBasicDescription = try Self.property(
            of: tapID,
            kAudioTapPropertyFormat
        )
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32 else {
            throw DuckingError.unsupportedFormat
        }

        let outputDevice: AudioObjectID = try Self.property(
            of: AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice
        )
        let outputUID: CFString = try Self.property(
            of: outputDevice,
            kAudioDevicePropertyDeviceUID
        )
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Say It Ducking",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID as String],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ],
            ],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(
                aggregate as CFDictionary,
                &aggregateID
            ),
            "create the ducking device"
        )

        renderState.configure(
            tapChannels: Int(tapFormat.mChannelsPerFrame),
            sampleRate: tapFormat.mSampleRate
        )
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateID,
                queue,
                Self.ioBlock(rendering: renderState)
            ),
            "start the ducking device"
        )
        try check(
            AudioDeviceStart(aggregateID, ioProcID),
            "start the ducking device"
        )
        startWaitingForSignal()
        observeOutputDevice()
    }

    nonisolated private static var defaultOutputDeviceAddress:
        AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// The replay is bound to the device that was current at start.
    private func observeOutputDevice() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.onOutputDeviceChange?()
            }
        }
        var address = Self.defaultOutputDeviceAddress
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        ) == noErr {
            outputDeviceListener = listener
        }
    }

    /// Built outside the main actor: Core Audio calls it on its IO thread.
    nonisolated private static func ioBlock(
        rendering renderState: DuckingRenderState
    ) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            renderState.render(input: input, output: output)
        }
    }

    /// Mutes the originals once the tap proves it can hear them.
    private func startWaitingForSignal() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.signalPollInterval,
            repeating: Self.signalPollInterval
        )
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.muteOriginalsIfSignalArrived()
            }
        }
        signalTimer = timer
        timer.resume()
    }

    private func muteOriginalsIfSignalArrived() {
        guard renderState.hasReceivedSignal,
              let tapDescription else { return }
        signalTimer?.cancel()
        signalTimer = nil
        tapDescription.muteBehavior = .mutedWhenTapped
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var reference = tapDescription
        let status = withUnsafeMutablePointer(to: &reference) {
            AudioObjectSetPropertyData(
                tapID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<CATapDescription>.size),
                $0
            )
        }
        // If muting fails, other apps simply stay at full volume.
        if status == noErr {
            renderState.startReplaying()
        }
    }

    /// Process objects for this process and every Say It helper that plays
    /// audio. Throws if this process is missing, because tapping it would
    /// mute and attenuate Say It's own speech.
    nonisolated private static func sayItProcessObjects() throws -> [AudioObjectID] {
        let processes: [AudioObjectID] = try propertyArray(
            of: AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyProcessObjectList
        )
        let ownPID = getpid()
        var excluded: [AudioObjectID] = []
        var includesSelf = false
        for process in processes {
            let pid: pid_t? = try? property(of: process, kAudioProcessPropertyPID)
            let bundleID: CFString? = try? property(
                of: process,
                kAudioProcessPropertyBundleID
            )
            if pid == ownPID {
                includesSelf = true
                excluded.append(process)
            } else if let bundleID,
                      (bundleID as String).hasPrefix(excludedBundleIDPrefix) {
                excluded.append(process)
            }
        }
        guard includesSelf else { throw DuckingError.ownProcessUnavailable }
        return excluded
    }

    nonisolated private static func property<Value>(
        of object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) throws -> Value {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Value>.size)
        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<Value>.size,
            alignment: MemoryLayout<Value>.alignment
        )
        defer { pointer.deallocate() }
        try check(
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer),
            "read audio device properties"
        )
        return pointer.load(as: Value.self)
    }

    nonisolated private static func propertyArray<Element>(
        of object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) throws -> [Element] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
            "read audio device properties"
        )
        let count = Int(size) / MemoryLayout<Element>.stride
        guard count > 0 else { return [] }
        return try [Element](unsafeUninitializedCapacity: count) {
            buffer, initialized in
            try check(
                AudioObjectGetPropertyData(
                    object,
                    &address,
                    0,
                    nil,
                    &size,
                    buffer.baseAddress!
                ),
                "read audio device properties"
            )
            initialized = Int(size) / MemoryLayout<Element>.stride
        }
    }
}

private func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else {
        throw DuckingError.coreAudio(action: action, status: status)
    }
}

enum DuckingError: LocalizedError, Equatable {
    case coreAudio(action: String, status: OSStatus)
    case unsupportedFormat
    case ownProcessUnavailable

    var errorDescription: String? {
        switch self {
        case .coreAudio(let action, let status):
            "Couldn't lower other audio: failed to \(action) (\(status))."
        case .unsupportedFormat:
            "Couldn't lower other audio: unsupported audio format."
        case .ownProcessUnavailable:
            "Couldn't lower other audio: Say It's audio process isn't ready."
        }
    }
}

/// Real-time state shared with the Core Audio IO block. The target gain and
/// ramp step are atomics; the current gain is only touched on the IO thread.
final class DuckingRenderState: @unchecked Sendable {
    private let targetGainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let rampDurationBits = Atomic<UInt64>(0)
    private let signalReceived = Atomic<Bool>(false)
    private let replaying = Atomic<Bool>(false)
    private var currentGain: Float = 1
    private var tapChannels = 2
    private var sampleRate: Double = 48_000

    func configure(tapChannels: Int, sampleRate: Double) {
        self.tapChannels = max(tapChannels, 1)
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
    }

    var hasReceivedSignal: Bool { signalReceived.load(ordering: .acquiring) }

    func startReplaying() {
        replaying.store(true, ordering: .releasing)
    }

    func setTarget(_ gain: Float, rampDuration: TimeInterval) {
        rampDurationBits.store(rampDuration.bitPattern, ordering: .relaxed)
        targetGainBits.store(
            min(max(gain, 0), 1).bitPattern,
            ordering: .releasing
        )
    }

    /// Copies the tap's channels (the trailing input buffers) to every output
    /// channel, ramping the gain linearly toward the target.
    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input)
        )
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard replaying.load(ordering: .acquiring) else {
            // Originals are still audible: listen for signal, output silence.
            if !signalReceived.load(ordering: .relaxed),
               Self.containsSignal(inputs) {
                signalReceived.store(true, ordering: .releasing)
            }
            for buffer in outputs {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return
        }
        let target = Float(
            bitPattern: targetGainBits.load(ordering: .acquiring)
        )
        let rampDuration = TimeInterval(
            bitPattern: rampDurationBits.load(ordering: .relaxed)
        )
        let step: Float = rampDuration > 0
            ? Float(1 / (rampDuration * sampleRate))
            : 1

        // The tap's buffers follow any input streams of the output device.
        var tapStart = inputs.count
        var foundChannels = 0
        while tapStart > 0, foundChannels < tapChannels {
            tapStart -= 1
            foundChannels += Int(inputs[tapStart].mNumberChannels)
        }
        let hasTap = foundChannels == tapChannels

        let startGain = currentGain
        var framesRendered = 0
        var outputChannel = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buffer.mDataByteSize)
                / (MemoryLayout<Float>.size * channels)
            framesRendered = max(framesRendered, frames)
            for frame in 0..<frames {
                let gain = Self.move(
                    startGain,
                    toward: target,
                    by: step * Float(frame + 1)
                )
                for channel in 0..<channels {
                    let source = hasTap
                        ? sample(
                            inputs,
                            from: tapStart,
                            channel: (outputChannel + channel) % tapChannels,
                            frame: frame
                        )
                        : 0
                    samples[frame * channels + channel] = source * gain
                }
            }
            outputChannel += channels
        }
        currentGain = Self.move(
            startGain,
            toward: target,
            by: step * Float(framesRendered)
        )
    }

    private func sample(
        _ buffers: UnsafeMutableAudioBufferListPointer,
        from start: Int,
        channel: Int,
        frame: Int
    ) -> Float {
        var remaining = channel
        for index in start..<buffers.count {
            let buffer = buffers[index]
            let channels = Int(buffer.mNumberChannels)
            guard remaining >= channels else {
                guard let data = buffer.mData else { return 0 }
                let frames = Int(buffer.mDataByteSize)
                    / (MemoryLayout<Float>.size * max(channels, 1))
                guard frame < frames else { return 0 }
                return data.assumingMemoryBound(to: Float.self)[
                    frame * channels + remaining
                ]
            }
            remaining -= channels
        }
        return 0
    }

    static func containsSignal(
        _ buffers: UnsafeMutableAudioBufferListPointer
    ) -> Bool {
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<count where samples[index] != 0 {
                return true
            }
        }
        return false
    }

    static func move(_ value: Float, toward target: Float, by delta: Float) -> Float {
        value < target
            ? min(value + delta, target)
            : max(value - delta, target)
    }
}
