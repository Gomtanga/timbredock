import AppKit
import AudioToolbox
import AVFoundation
import AudioRingBufferC
import CoreAudio
import Darwin
import Foundation
import LowEndSupport

/// Optional manager-side platform boundary for offline graph integration checks.
/// A normal processor leaves this nil. Callback bodies never consult this interface.
/// Implementations return OSStatus and handles separately so partial creation and
/// failed destruction still pass through the production ownership rules.
@available(macOS 14.4, *)
protocol AudioGraphIO: AnyObject {
    var monotonicTime: TimeInterval { get }
    func pause(_ seconds: TimeInterval)
    func waitForRateEvent(_ semaphore: DispatchSemaphore, timeout: TimeInterval)
    func nominalRate(_ device: AudioObjectID) throws -> Double
    func setNominalRate(_ rate: Double, device: AudioObjectID) throws
    func capabilities(_ device: AudioObjectID) throws -> HardwareSampleRateTracker.RateCapabilities
    func makeTapDescription() throws -> CATapDescription
    func createTap(_ description: CATapDescription) -> (OSStatus, AudioObjectID)
    func tapRate(_ tap: AudioObjectID) throws -> Double
    func addTapListener(_ tap: AudioObjectID, queue: DispatchQueue, listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    func removeTapListener(_ tap: AudioObjectID, listener: AudioObjectPropertyListenerBlock) -> OSStatus
    func createAggregate(_ description: CFDictionary) -> (OSStatus, AudioObjectID)
    func registerCapture(_ device: AudioObjectID, callback: @escaping AudioDeviceIOProc,
                         clientData: UnsafeMutableRawPointer) -> (OSStatus, AudioDeviceIOProcID?)
    func startCapture(_ device: AudioObjectID, ioProc: AudioDeviceIOProcID?) -> OSStatus
    func stopCapture(_ device: AudioObjectID, ioProc: AudioDeviceIOProcID) -> OSStatus
    func unregisterCapture(_ device: AudioObjectID, ioProc: AudioDeviceIOProcID) -> OSStatus
    func destroyAggregate(_ device: AudioObjectID) -> OSStatus
    func destroyTap(_ tap: AudioObjectID) -> OSStatus
    func configureOutput(_ sampleRate: Double) throws
    func startOutput() throws
    func stopOutput()
    var outputIsRunning: Bool { get }
}

/// Read-only values used by the offline integration fixture. These are sampled
/// on the manager queue, never from an audio callback or the live UI.
struct AudioGraphCheckState {
    var outputDevice: AudioObjectID
    var started: Bool
    var outputRunning: Bool
    var tap: AudioObjectID
    var aggregate: AudioObjectID
    var hasIOProc: Bool
    var hasOutputSource: Bool
    var tapRate: Double
    var outputRate: Double
    var hardwareRate: Double
    var live2x: Bool
    var restoreRate: Double?
    var automaticRestoreRate: Double?
    var phase: String
    var status: String
    var resets: UInt64
    var written: UInt64
    var read: UInt64
    var gain: Float
    var appliedRevision: UInt64
}

@available(macOS 14.4, *)
final class SystemAudioProcessor: @unchecked Sendable {
    let notificationSessionID = UUID().uuidString
    private struct AudioProcessInfo {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    private let settings: Settings
    private let ringBuffer: LockFreeFloatRingBuffer
    private let visualizerRingBuffer: LockFreeFloatRingBuffer
    private let outputGainRamp: OpaquePointer
    private let controlQueue: LockFreeControlEventQueue
    private let scratchFrameCapacity = 8192
    private let inputScratch: UnsafeMutablePointer<Float>
    /// Output-conditioning scratch. `processLive` writes its (possibly 2×)
    /// result here so the live path is never in-place — a rate-changing output
    /// cannot overwrite its own input. Sized for the 2× interleaved-stereo case
    /// (`scratchFrameCapacity * 2 * 2`); allocated once, reused every callback.
    private let conditioningOutputScratch: UnsafeMutablePointer<Float>
    private let managerQueue = DispatchQueue(label: "com.codexaudiolab.lowendcircuit.audio-manager")
    private let managerQueueKey = DispatchSpecificKey<UInt8>()
    private enum RateControlMode { case manual, automatic, livePCM2x }
    private var rateControlMode: RateControlMode = .manual
    private func onManagerQueue<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: managerQueueKey) == 1 { return try operation() }
        return try managerQueue.sync(execute: operation)
    }
    private var engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var outputCallbackLifetime: AudioCallbackLifetime?
    private var captureCallbackLifetime: AudioCallbackLifetime?
    private var hardwareTracker: HardwareSampleRateTracker?
    private var tapFormatListener: AudioObjectPropertyListenerBlock?
    private var tapFormatObservationToken: HardwareObservationToken?
    private var currentOutputDeviceID: AudioObjectID
    private var currentHardwareSampleRate: Double
    private var currentTapSampleRate: Double
    private var currentSampleRate: Double
    /// Optional device boundary for offline lifecycle checks. The normal
    /// initializer leaves this nil and keeps the existing Core Audio path.
    private let rateOperation: ((Double, AudioObjectID) throws -> Double)?
    private let graphIO: AudioGraphIO?
    private let captureTargetRead: (AudioObjectID) throws -> String
    // Manager-only process ownership; never read or locked by audio callbacks.
    // Offline graph fixtures opt in with their own private lease directory.
    private let captureSessionLease: CaptureSessionLease?
    /// Live PCM 2× oversampling. When active, the output device runs at 2× the
    /// capture (tap) rate while the aggregate/tap stays at the source rate, and
    /// `ResamplingOutputConditioningEngine.processLive` polyphase-upsamples the
    /// captured signal 2× before it reaches the output ring buffer. Off by
    /// default; activating it is a device-rate negotiation that runs on the
    /// manager queue (never inside the audio callback).
    private var livePCM2xActive: Bool {
        get { rateControlMode == .livePCM2x }
        set {
            if newValue { rateControlMode = .livePCM2x }
            else if rateControlMode == .livePCM2x { rateControlMode = .manual }
        }
    }
    private var livePCM2xOutputRate: Double = 0
    /// Hardware rate/device captured before activating 2×, used to restore PCM
    /// bypass on disable or on negotiation failure. nil while 2× is not active.
    private var preLivePCM2xHardwareRate: Double?
    private var preLivePCM2xDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let tonalDSP: TonalDSPRouter
    private let spatializer: Spatializer
    /// Independent output-conditioning layer (oversampling / dither / experimental
    /// DSD-DoP). Lives between the tonal DSP and the output ring buffer; defaults
    /// to identity bypass on the live path. See ResamplingOutputConditioningEngine.
    private let conditioningEngine: ResamplingOutputConditioningEngine
    private var currentIntensity: Float
    private var currentBody: Float
    private var currentOutputDb: Float
    private var currentDSPModel: Settings.DSPModel
    private var currentExciterOversamplingMode: ExciterOversamplingMode
    private var automaticRateMatchingEnabled: Bool {
        get { rateControlMode == .automatic }
        set {
            if newValue { rateControlMode = .automatic }
            else if rateControlMode == .automatic { rateControlMode = .manual }
        }
    }
    private var rateMatchCoordinator = SourceRateMatchCoordinator()
    private var rateMatchSessionDisabled = false
    private var isAutomaticRateTransition = false
    private var originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var originalRateMatchSampleRate: Double?
    private var rateMatchStatus = L10n.string("runtime.rate.off")
    private var rateMatchPhase: RateMatchPhase = .idle
    private var rateMatchTransitionID: UInt64 = 0
    private var rateMatchActiveTransitionID: UInt64 = 0
    private var ringWrittenAtTransitionStart: UInt64 = 0
    private var ringReadAtTransitionStart: UInt64 = 0
    private var audioFlowGeneration: UInt64 = 0
    private var ringWrittenAtCaptureStart: UInt64 = 0
    private var ringReadAtCaptureStart: UInt64 = 0
    private var currentSpatialSettings: SpatialSettings
    private var currentCaptureTargetSummary = L10n.string("runtime.target.system")
    private var engineRestartCount: UInt64 = 0
    private let runningState = RuntimeSnapshotBox(false)
    private var isStarted = false { didSet { runningState.store(isStarted) } }
    private let displayState = RuntimeSnapshotBox(ManagerDisplayState())
    private let stopFailureState = RuntimeSnapshotBox<String?>(nil)
    private let spatialSubmissions: SpatialSubmissionBox
    private var spatialSubmissionRevision: UInt64 = 0
    private var controlTimer: DispatchSourceTimer?
    private var captureTargetTimer: DispatchSourceTimer?

    var captureTargetSummary: String { displayState.load().captureTarget }
    var outputDeviceID: AudioObjectID { displayState.load().deviceID }
    var capturedBundleIDs: [String]? {
        if case .bundleIDs(let ids) = settings.mode { return ids }
        return nil
    }
    var appliedSpatialRevision: UInt64 { controlQueue.appliedSpatialRevision }
    var receivedTone: ToneControlReceipt? {
        guard runningState.load() else { return nil }
        return controlQueue.receivedTone
    }
    var stopFailureDescription: String { stopFailureState.load() ?? L10n.string("runtime.stop.incomplete") }

    func diagnosticsSnapshot() -> AudioDiagnosticsSnapshot {
        let state = displayState.load()
        let written = ringBuffer.totalWrittenSamples()
        let read = ringBuffer.totalReadSamples()
        return AudioDiagnosticsSnapshot(
            outputUnderrunSamples: ringBuffer.underrunSamples(),
            outputDroppedSamples: ringBuffer.droppedWriteSamples(),
            visualizerDroppedSamples: visualizerRingBuffer.droppedWriteSamples(),
            engineRestartCount: state.restartCount,
            captureTarget: state.captureTarget,
            audioFlow: AudioFlowProgress(generation: state.audioFlowGeneration,
                producedSamples: written > state.ringWrittenAtCaptureStart ? written - state.ringWrittenAtCaptureStart : 0,
                consumedSamples: read > state.ringReadAtCaptureStart ? read - state.ringReadAtCaptureStart : 0)
        )
    }

    private func publishManagerDisplayState() {
        displayState.store(ManagerDisplayState(
            deviceID: currentOutputDeviceID, outputSampleRate: currentSampleRate,
            tapSampleRate: currentTapSampleRate, restartCount: engineRestartCount,
            captureTarget: currentCaptureTargetSummary,
            audioFlowGeneration: audioFlowGeneration,
            ringWrittenAtCaptureStart: ringWrittenAtCaptureStart,
            ringReadAtCaptureStart: ringReadAtCaptureStart
        ))
    }

    private func startControlTimer() {
        let timer = DispatchSource.makeTimerSource(queue: managerQueue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, isStarted else { return }
            let latest = spatialSubmissions.load()
            if latest.revision != spatialSubmissionRevision {
                spatialSubmissionRevision = latest.revision
                currentSpatialSettings = latest.settings
                controlQueue.pushSpatial(latest.settings, revision: latest.revision)
            }
            controlQueue.flushPending()
        }
        controlTimer = timer
        timer.resume()
    }

    private func startCaptureTargetTimer() {
        guard case .bundleIDs = settings.mode else { return }
        let timer = DispatchSource.makeTimerSource(queue: managerQueue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.refreshCaptureTargetSummary() }
        captureTargetTimer = timer
        timer.resume()
    }

    private func refreshCaptureTargetSummary() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard isStarted, tapID != kAudioObjectUnknown, case .bundleIDs = settings.mode else { return }
        let next: String
        do { next = try captureTargetRead(tapID) }
        catch { next = L10n.format("runtime.capture.queryFailed", String(describing: error)) }
        guard next != currentCaptureTargetSummary else { return }
        currentCaptureTargetSummary = next
        publishManagerDisplayState()
    }

    init(settings inputSettings: Settings,
         initialOutput: () throws -> (AudioObjectID, Double) = {
             let device = try HardwareSampleRateTracker.defaultOutputDevice()
             return (device, try HardwareSampleRateTracker.nominalSampleRate(for: device))
         },
         rateOperation: ((Double, AudioObjectID) throws -> Double)? = nil,
         graphIO: AudioGraphIO? = nil,
         captureSessionLease: CaptureSessionLease? = nil,
         captureTargetRead: ((AudioObjectID) throws -> String)? = nil) throws {
        let settings = inputSettings.normalized()
        let (outputDeviceID, detectedSampleRate) = try initialOutput()
        let sampleRate = try Self.validSampleRate(detectedSampleRate)

        self.settings = settings
        self.rateOperation = rateOperation
        self.graphIO = graphIO
        self.captureSessionLease = captureSessionLease ?? (graphIO == nil ? CaptureSessionLease() : nil)
        self.captureTargetRead = captureTargetRead ?? Self.readCurrentCaptureTargetSummary
        self.currentOutputDeviceID = outputDeviceID
        self.currentHardwareSampleRate = sampleRate
        self.currentTapSampleRate = sampleRate
        self.currentSampleRate = sampleRate
        self.currentIntensity = settings.intensity
        self.currentBody = settings.body
        self.currentOutputDb = settings.outputDb
        self.currentDSPModel = settings.dspModel
        self.currentExciterOversamplingMode = settings.exciterOversamplingMode
        self.rateControlMode = settings.automaticRateMatchingEnabled ? .automatic : .manual
        self.rateMatchStatus = settings.automaticRateMatchingEnabled
            ? L10n.string("runtime.rate.waiting")
            : L10n.string("runtime.rate.off")
        self.currentSpatialSettings = settings.spatial
        self.spatialSubmissions = SpatialSubmissionBox(settings.spatial)
        self.ringBuffer = try LockFreeFloatRingBuffer(capacityFrames: Int(max(sampleRate, 48_000)) * 4, channels: 2)
        self.visualizerRingBuffer = try LockFreeFloatRingBuffer(capacityFrames: Int(max(sampleRate, 48_000)), channels: 2)
        self.controlQueue = try LockFreeControlEventQueue(sampleRate: Float(sampleRate))
        self.inputScratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrameCapacity * 2)
        self.conditioningOutputScratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrameCapacity * 2 * 2)
        inputScratch.initialize(repeating: 0, count: scratchFrameCapacity * 2)
        conditioningOutputScratch.initialize(repeating: 0, count: scratchFrameCapacity * 2 * 2)
        self.tonalDSP = TonalDSPRouter(
            sampleRate: Float(sampleRate), intensity: settings.intensity,
            body: settings.body, outputDb: settings.outputDb,
            dspModel: settings.dspModel, exciterOversamplingMode: settings.exciterOversamplingMode
        )
        self.spatializer = Spatializer(sampleRate: Float(sampleRate), settings: settings.spatial)
        self.conditioningEngine = ResamplingOutputConditioningEngine(maxInputFrames: scratchFrameCapacity)
        guard let outputGainRamp = lc_output_gain_ramp_create(1) else {
            inputScratch.deallocate()
            conditioningOutputScratch.deallocate()
            throw AppError.message("Could not allocate the output gain ramp.")
        }
        self.outputGainRamp = outputGainRamp
        managerQueue.setSpecific(key: managerQueueKey, value: 1)
        publishManagerDisplayState()
        startControlTimer()
        startCaptureTargetTimer()
    }

    deinit {
        controlTimer?.cancel()
        captureTargetTimer?.cancel()
        if !stop() {
            // A failed tap teardown or device restoration must not admit a
            // second owner just because the last Swift reference went away.
            captureSessionLease?.abandonUntilProcessExit()
        }
        // An admitted callback retains this processor through its C gate. This
        // point is reachable only after every userdata reader has quiesced.
        lc_output_gain_ramp_destroy(outputGainRamp)
        inputScratch.deallocate()
        conditioningOutputScratch.deallocate()
    }

    func start() throws {
        try start(hardwareIO: nil)
    }

    private func start(hardwareIO: HardwareTrackerIO?) throws {
        try onManagerQueue {
            guard !isStarted else { return }
            guard captureSessionLease?.isHeld != true else {
                throw AppError.message(L10n.string("runtime.stop.retry"))
            }
            if graphIO == nil { try CaptureInstanceCompatibility.validate() }
            // Reject contention before creating a tap or changing any device.
            try captureSessionLease?.acquire()
            do {
            isStarted = true
            try createProcessTapAndAggregateDevice()
            currentSampleRate = try syncAggregateSampleRate(preferredSampleRate: currentHardwareSampleRate)
            try refreshTapSampleRate()
            try AudioLifecyclePolicy.validateUnityRoute(captureRate: currentTapSampleRate, outputRate: currentSampleRate)
            controlQueue.updateSampleRate(Float(currentTapSampleRate))
            applyCurrentSettingsDirectly()
            if sourceNode != nil { try replaceOutputEngine() }
            try startOutput(sampleRate: currentSampleRate)
            try startCapture()
            hardwareTracker = makeHardwareTracker(io: hardwareIO)
            try hardwareTracker?.start()
            publishFormatStatus()
            } catch {
                hardwareTracker?.stop(); hardwareTracker = nil
                let startFailure = error
                if let failure = startFailure as? AudioGraphTransitionFailure, !failure.recovered {
                    isStarted = false
                    rateMatchStatus = L10n.format("runtime.start.cleanupPending", String(describing: failure))
                    publishFormatStatus()
                    throw failure
                }
                do {
                    try suspendForHardwareReconfigure()
                    detachOutputSource()
                }
                catch {
                    isStarted = false
                    rateMatchStatus = L10n.format("runtime.start.cleanupPending", String(describing: error))
                    publishFormatStatus()
                    throw AudioGraphTransitionFailure(cause: startFailure, recoveryFailure: error)
                }
                isStarted = false
                captureSessionLease?.release()
                publishFormatStatus()
                throw error
            }
        }
        print("Audio format: \(onManagerQueue { makeFormatStatus().indicatorText })")
        print("Capture target: \(captureTargetSummary)")
        print("LowEnd system audio processing is running. Press Ctrl-C to stop.")
    }

    func updateDSP(intensity: Float,
                   body: Float,
                   outputDb: Float,
                   dspModel: Settings.DSPModel,
                   exciterOversamplingMode: ExciterOversamplingMode) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            AudioLifecyclePolicy.withRunningProcessor(isStarted: isStarted) {
                currentIntensity = intensity
                currentBody = body
                currentOutputDb = outputDb
                currentDSPModel = dspModel
                currentExciterOversamplingMode = exciterOversamplingMode
                controlQueue.pushDSP(
                    intensity: intensity,
                    body: body,
                    outputDb: outputDb,
                    dspModel: dspModel,
                    exciterOversamplingMode: exciterOversamplingMode
                )
            }
        }
    }

    @discardableResult
    func updateSpatial(_ settings: SpatialSettings) -> UInt64 {
        spatialSubmissions.submit(settings)
    }

    /// Push output-conditioning parameters, after first performing any device-
    /// rate negotiation the parameters require. Live PCM 2× (enabled +
    /// pcmOversampling + 2×) switches the output device to 2× the capture rate;
    /// every other configuration restores PCM bypass. The negotiation runs on
    /// the manager queue (never inside the audio callback); the engine only
    /// receives its snapshot once the device rate has settled — or, on an
    /// unsupported device/rate or a failed transition, after falling back to a
    /// bypass snapshot so it never upsamples into a device still running at 1×.
    func updateOutputConditioning(_ parameters: OutputConditioningParameters) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            self.applyLivePCM2xState(for: parameters)
        }
    }

    /// A headroom edit cannot negotiate or restart a device. The manager may
    /// already have left 2x while its last active notification is still queued.
    func updateActiveLivePCM2xParameters(_ parameters: OutputConditioningParameters) {
        managerQueue.async { [weak self] in
            guard let self, self.isStarted, self.livePCM2xActive,
                  parameters.isEnabled, parameters.outputMode == .pcmOversampling,
                  parameters.oversamplingFactor == 2 else { return }
            self.controlQueue.pushConditioning(parameters)
        }
    }

    /// Whether the output device can actually run live PCM 2× for the current
    /// capture (tap) rate. Queries the device off the audio thread.
    private func canDeviceRunLivePCM2x(tapRate: Double) -> Bool {
        guard let capabilities = try? rateCapabilities(for: currentOutputDeviceID) else {
            return false
        }
        let capability = OutputConditioningCapability(
            supportedCarriers: [:],
            supportsWideCarrierBitDepth: true,
            supportedRates: capabilities.supportedRates,
            isRateSettable: capabilities.isSettable,
            deviceID: currentOutputDeviceID
        )
        return capability.canAttemptLivePCM2x(tapRate: tapRate)
    }

    /// Decide whether the parameters activate live PCM 2×, then negotiate the
    /// device rate (or restore bypass) accordingly.
    private func applyLivePCM2xState(for parameters: OutputConditioningParameters) {
        AudioLifecyclePolicy.withRunningProcessor(isStarted: isStarted) {
            let requested = parameters.isEnabled
                && parameters.outputMode == .pcmOversampling
                && parameters.oversamplingFactor == 2

            if requested {
                activateLivePCM2x(parameters: parameters)
            } else {
                deactivateLivePCM2x(parameters: parameters)
            }
        }
    }

    /// Returns a bypass snapshot (same params, mode forced to bypass) used when
    /// the device/rate cannot run 2× — the live path must stay a PCM identity.
    private func bypassConditioning(from parameters: OutputConditioningParameters) -> OutputConditioningParameters {
        var bypass = parameters
        bypass.outputMode = .bypass
        return bypass
    }

    private func activateLivePCM2x(parameters: OutputConditioningParameters) {
        if livePCM2xActive {
            controlQueue.pushConditioning(parameters)
            return
        }
        guard isStarted else {
            controlQueue.pushConditioning(parameters)
            return
        }
        // Live 2× and automatic rate matching both change the output device
        // rate and cannot coexist; rate matching yields to the explicit 2× mode.
        if automaticRateMatchingEnabled {
            automaticRateMatchingEnabled = false
            rateMatchCoordinator.invalidateSource()
            do { try restoreOriginalRateMatchIfNeeded() }
            catch {
                publishLivePCM2xStatus(active: false, fallbackReason: L10n.format("runtime.rate.previousRestoreFailed", String(describing: error)))
                publishFormatStatus()
                return
            }
        }

        let tapRate = currentTapSampleRate
        guard tapRate > 1,
              let target = OutputConditioningCapability.livePCM2xTargetRate(forTapRate: tapRate),
              canDeviceRunLivePCM2x(tapRate: tapRate) else {
            fputs("[Live2x] fallback (unsupported): tap=\(Self.rateText(tapRate)) device=\(currentOutputDeviceID)\n", stderr)
            controlQueue.pushConditioning(bypassConditioning(from: parameters))
            publishLivePCM2xStatus(active: false,
                                   fallbackReason: L10n.string("runtime.output.unsupported"))
            return
        }
        do {
            try performLivePCM2xTransition(tapRate: tapRate, outputRate: target, parameters: parameters)
            livePCM2xActive = true
            livePCM2xOutputRate = target
            fputs("[Live2x] activated: tap \(Self.rateText(tapRate)) → output \(Self.rateText(target)) on device \(currentOutputDeviceID)\n", stderr)
            publishLivePCM2xStatus(active: true, fallbackReason: nil)
        } catch {
            if let failure = error as? AudioGraphTransitionFailure, failure.recovered {
                preLivePCM2xHardwareRate = nil
                preLivePCM2xDeviceID = kAudioObjectUnknown
            }
            livePCM2xActive = false
            livePCM2xOutputRate = 0
            publishLivePCM2xStatus(active: false, fallbackReason: String(describing: error))
        }
    }

    @discardableResult
    private func deactivateLivePCM2x(parameters: OutputConditioningParameters) -> Error? {
        guard livePCM2xActive || preLivePCM2xHardwareRate != nil else {
            controlQueue.pushConditioning(bypassConditioning(from: parameters))
            return nil
        }
        let restoreRate = preLivePCM2xHardwareRate ?? currentTapSampleRate
        rateMatchTransitionID &+= 1
        var failure: Error?
        do {
            // The normal-graph installer applies bypass only after both callbacks stop.
            // Rebuild even if the nominal rate already matches: the tap/output split may not.
            try performRateTransition(to: restoreRate,
                successStatus: L10n.format("runtime.output.disabled", Self.rateText(restoreRate)), transitionID: rateMatchTransitionID)
            preLivePCM2xHardwareRate = nil
            preLivePCM2xDeviceID = kAudioObjectUnknown
        } catch {
            failure = error
            // Keep the restoration target for a later retry/Stop. Failed rollback
            // is left fully stopped by AudioGraphTransition.
        }
        livePCM2xActive = false
        livePCM2xOutputRate = 0
        if outputIsRunning { controlQueue.pushConditioning(bypassConditioning(from: parameters)) }
        publishLivePCM2xStatus(active: false, fallbackReason: failure.map { String(describing: $0) })
        return failure
    }

    /// Device-rate negotiation for live PCM 2×: fade out, suspend, switch the
    /// output DAC to `outputRate`, reconfigure with the aggregate/tap held at
    /// `tapRate` and the output graph at `outputRate`, recover flow, fade in.
    /// Mirrors `performRateTransition`'s safety shape but keeps the tap at 1×
    /// while the output runs at 2×. On any failure it restores the pre-2× rate.
    private func performLivePCM2xTransition(tapRate: Double, outputRate: Double,
                                            parameters: OutputConditioningParameters) throws {
        guard !isAutomaticRateTransition else { throw AppError.message(L10n.string("runtime.transition.busy")) }
        isAutomaticRateTransition = true
        defer { isAutomaticRateTransition = false; publishFormatStatus() }
        if preLivePCM2xHardwareRate == nil {
            preLivePCM2xHardwareRate = currentHardwareSampleRate
            preLivePCM2xDeviceID = currentOutputDeviceID
        }
        let rollbackRate = preLivePCM2xHardwareRate ?? currentHardwareSampleRate
        try runGraphTransition(
            installTarget: {
                let confirmed = try self.setAndConfirmHardwareRate(outputRate)
                try self.restartForLivePCM2x(tapRate: tapRate, outputRate: confirmed, parameters: parameters)
            },
            rollbackRate: rollbackRate
        )
    }

    /// Reconfigure for live PCM 2×: the aggregate (tap) stays at the source rate
    /// so the tap captures the 1× signal, while the output graph runs at 2×.
    /// `currentSampleRate` (output rate) and `currentTapSampleRate` (capture
    /// rate) therefore differ while 2× is active — the tonal DSP and the ring-
    /// buffer push both key off the capture rate, and `processLive` doubles it.
    private func restartForLivePCM2x(tapRate: Double, outputRate: Double,
                                     parameters: OutputConditioningParameters) throws {
        try createProcessTapAndAggregateDevice()
        // Aggregate/tap at the source rate (1× capture).
        _ = try syncAggregateSampleRate(preferredSampleRate: tapRate)
        try refreshTapSampleRate()
        guard abs(currentTapSampleRate - tapRate) < 1, abs(outputRate - currentTapSampleRate * 2) < 1 else {
            throw AppError.message(L10n.string("runtime.output.formatLost"))
        }
        // Output device/graph at 2×.
        currentHardwareSampleRate = outputRate
        currentSampleRate = outputRate
        controlQueue.updateSampleRate(Float(currentTapSampleRate))
        applyCurrentSettingsDirectly()

        do {
            try replaceOutputEngine()
            try configureOutputGraph(sampleRate: currentSampleRate)
            conditioningEngine.resetAll()
            conditioningEngine.updateSettings(parameters)
            try startOutputEngine()
            try startCapture()
        } catch {
            try cleanupAfterInstallFailure(error)
        }
        publishFormatStatus()
    }

    /// Publish live PCM 2× activation / fallback state to the UI. Runs on the
    /// manager queue; hops to main for the notification.
    private func publishLivePCM2xStatus(active: Bool, fallbackReason: String?) {
        let sessionID = notificationSessionID
        let processing = isStarted
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: AudioFormatNotifications.didChange,
                object: nil,
                userInfo: [
                    "processorSessionID": sessionID,
                    AudioFormatNotifications.livePCM2xActiveKey: active,
                    AudioFormatNotifications.isProcessingKey: processing,
                    AudioFormatNotifications.livePCM2xFallbackKey: fallbackReason ?? ""
                ]
            )
        }
    }

    /// Decode the flat C snapshot back into the Swift parameter value type.
    /// Runs on the audio thread (from `applyPendingControlEvents`), so it must
    /// stay allocation- and lock-free: no Swift collection APIs, no static-let
    /// first-touch (which lazily initializes under a lock). All decoding is plain
    /// scalar branching.
    private static func parameters(from c: LCOutputConditioningSettings) -> OutputConditioningParameters {
        var p = OutputConditioningParameters()
        p.isEnabled = c.enabled != 0
        p.outputMode = OutputConditioningMode(rawValue: c.outputMode) ?? .bypass
        // Inline clamp — avoid touching the `allowedOversamplingFactors` static
        // array (its lazy init takes a lock on first access) on the audio thread.
        let factorValue = Int(c.oversamplingFactor)
        p.oversamplingFactor = (factorValue == 8) ? 8 : (factorValue == 4) ? 4 : 2
        p.filterMode = ResamplingFilterMode(rawValue: c.filterMode) ?? .linearPhaseShort
        // Headroom is carried as a separate precomputed scalar to the engine;
        // this RT decoder never converts it back to dB.
        p.ditherEnabled = c.ditherEnabled != 0
        p.noiseShapingEnabled = c.noiseShapingEnabled != 0
        p.dsdMode = DSDMode(rawValue: c.dsdMode) ?? .off
        return p
    }

    func setAutomaticRateMatchingEnabled(_ enabled: Bool) {
        managerQueue.async { [weak self] in
            guard let self else { return }
            AudioLifecyclePolicy.withRunningProcessor(isStarted: isStarted) {
                if enabled && livePCM2xActive {
                    rateMatchStatus = L10n.string("runtime.rate.conflict")
                    publishFormatStatus()
                    return
                }
                automaticRateMatchingEnabled = enabled
                rateMatchSessionDisabled = false
                rateMatchCoordinator.reset()
                rateMatchPhase = enabled ? .idle : .idle
                rateMatchStatus = enabled ? L10n.string("runtime.rate.waiting") : L10n.string("runtime.rate.off")
                if !enabled {
                    do {
                        try restoreOriginalRateMatchIfNeeded()
                    } catch {
                        rateMatchStatus = L10n.string("runtime.rate.restoreFailed")
                    }
                }
                publishFormatStatus()
            }
        }
    }

    func observeSourceFormats(_ formats: [SourceAudioFormat]) {
        managerQueue.async { [weak self] in
            guard let self,
                  automaticRateMatchingEnabled,
                  !rateMatchSessionDisabled,
                  isStarted,
                  !isAutomaticRateTransition else {
                return
            }

            let capturedBundleIDs: [String]?
            if case .bundleIDs(let ids) = settings.mode { capturedBundleIDs = ids }
            else { capturedBundleIDs = nil }
            guard let format = SourceFormatSelectionPolicy.select(formats: formats, capturedBundleIDs: capturedBundleIDs),
                  format.hasUsableSampleRate else {
                rateMatchCoordinator.invalidateSource()
                return
            }

            do {
                let capabilities = try rateCapabilities(for: currentOutputDeviceID)
                let outcome = try rateMatchCoordinator.observe(
                    format: format,
                    currentDeviceRate: currentHardwareSampleRate,
                    supportedRates: capabilities.supportedRates,
                    isDeviceRateSettable: capabilities.isSettable,
                    now: { Date() },
                    performTransition: { try self.performAutomaticRateTransition(to: $0) }
                )
                if case .coolingDown(let remaining) = outcome {
                    rateMatchStatus = L10n.format("runtime.rate.cooldown", remaining)
                    publishFormatStatus()
                }
            } catch {
                disableAutomaticRateMatchingForSession(error)
            }
        }
    }

    func makeSpectrumAnalyzer(dynamicsModel: DynamicsMeterModel,
                              spectrumModel: SpectrumModel) -> AudioSpectrumAnalyzer {
        let sampleRate = displayState.load().outputSampleRate
        return AudioSpectrumAnalyzer(
            ringBuffer: visualizerRingBuffer,
            sampleRate: Float(sampleRate),
            dynamicsModel: dynamicsModel,
            spectrumModel: spectrumModel
        )
    }

    @discardableResult
    func stop() -> Bool {
        onManagerQueue {
            stopFailureState.store(nil)
            guard AudioLifecyclePolicy.needsStop(
                hasResources: isStarted || hardwareTracker != nil || aggregateDeviceID != kAudioObjectUnknown || tapID != kAudioObjectUnknown
                    || sourceNode != nil || captureCallbackLifetime != nil || outputCallbackLifetime != nil
                    || captureSessionLease?.isHeld == true,
                automaticRestoreRate: originalRateMatchSampleRate, liveRestoreRate: preLivePCM2xHardwareRate) else {
                stopOutputEngine()
                return true
            }

            hardwareTracker?.stop()
            hardwareTracker = nil
            do {
                try quiesceAndDestroyCapture()
                detachOutputSource()
            } catch {
                isStarted = false
                isAutomaticRateTransition = false
                rateMatchPhase = .aborted
                rateMatchStatus = L10n.format("runtime.stop.pending", String(describing: error))
                stopFailureState.store(rateMatchStatus)
                rateMatchLog(rateMatchStatus)
                publishFormatStatus()
                return false
            }
            ringBuffer.clear()
            visualizerRingBuffer.requestDiscard()
            ringBuffer.resetDiagnostics()
            visualizerRingBuffer.resetDiagnostics()
            if originalRateMatchSampleRate != nil {
                do { try restoreOriginalRateMatchIfNeeded(reconfigureEngine: false) }
                catch {
                    stopFailureState.store(L10n.format("runtime.rate.originalPending", String(describing: error)))
                    rateMatchLog("Stop automatic-rate restoration pending: \(error)")
                }
            }
            // If live PCM 2× left the output device at 2×, restore its rate so a
            // subsequent launch / other apps see the device's normal rate.
            if let rate = preLivePCM2xHardwareRate, preLivePCM2xDeviceID != kAudioObjectUnknown {
                do {
                    try AudioLifecyclePolicy.restoreRate(rate,
                        apply: { try setAndConfirmHardwareRate(rate, deviceID: preLivePCM2xDeviceID) },
                        didRestore: {
                            preLivePCM2xHardwareRate = nil
                            preLivePCM2xDeviceID = kAudioObjectUnknown
                        })
                } catch {
                    stopFailureState.store(L10n.format("runtime.output.originalPending", String(describing: error)))
                    rateMatchLog("Stop restoration pending: \(error)")
                }
            }
            livePCM2xActive = false
            livePCM2xOutputRate = 0
            isStarted = false
            isAutomaticRateTransition = false
            rateMatchPhase = .idle
            rateMatchActiveTransitionID = 0
            rateMatchCoordinator.reset()
            publishManagerDisplayState()
            if (originalRateMatchSampleRate != nil || preLivePCM2xHardwareRate != nil) && stopFailureState.load() == nil {
                stopFailureState.store(L10n.string("runtime.rate.previousPending"))
            }
            let fullyStopped = originalRateMatchSampleRate == nil && preLivePCM2xHardwareRate == nil
            if fullyStopped { captureSessionLease?.release() }
            return fullyStopped
        }
    }

    private func startOutput(sampleRate: Double) throws {
        try configureOutputGraph(sampleRate: sampleRate)
        try startOutputEngine()
    }

    private var outputIsRunning: Bool { graphIO?.outputIsRunning ?? engine.isRunning }
    private var monotonicTime: TimeInterval {
        graphIO?.monotonicTime ?? (Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000)
    }
    private func pauseForGraph(_ seconds: TimeInterval) {
        if let graphIO { graphIO.pause(seconds) }
        else { Thread.sleep(forTimeInterval: seconds) }
    }
    private func startOutputEngine() throws {
        if let graphIO { try graphIO.startOutput() }
        else { try engine.start() }
    }
    private func stopOutputEngine() {
        if let graphIO { graphIO.stopOutput() }
        else { engine.stop() }
    }
    private func nominalRate(for device: AudioObjectID) throws -> Double {
        if let graphIO { return try graphIO.nominalRate(device) }
        return try HardwareSampleRateTracker.nominalSampleRate(for: device)
    }
    private func setNominalRate(_ rate: Double, for device: AudioObjectID) throws {
        if let graphIO { try graphIO.setNominalRate(rate, device: device) }
        else { try HardwareSampleRateTracker.setNominalSampleRate(rate, for: device) }
    }
    private func rateCapabilities(for device: AudioObjectID) throws -> HardwareSampleRateTracker.RateCapabilities {
        if let graphIO { return try graphIO.capabilities(device) }
        return try HardwareSampleRateTracker.rateCapabilities(for: device)
    }

    private func configureOutputGraph(sampleRate: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw AppError.message("Could not create AVAudioFormat for \(sampleRate) Hz.")
        }

        let node = try sourceNode ?? makeSourceNode()
        if let graphIO {
            sourceNode = node
            try graphIO.configureOutput(sampleRate)
            return
        }
        if sourceNode == nil {
            sourceNode = node
            engine.attach(node)
        }

        engine.disconnectNodeOutput(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
    }

    private func makeSourceNode() throws -> AVAudioSourceNode {
        let lifetime = try AudioCallbackLifetime(retaining: self)
        outputCallbackLifetime = lifetime
        return AVAudioSourceNode { [lifetime] isSilence, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let userdata = lc_callback_gate_try_enter(lifetime.handle) else {
                for index in 0..<abl.count {
                    let buffer = abl[index]
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                isSilence.pointee = true
                return noErr
            }
            defer { lc_callback_gate_leave(lifetime.handle) }
            let processor = Unmanaged<SystemAudioProcessor>.fromOpaque(userdata).takeUnretainedValue()
            let ringBuffer = processor.ringBuffer
            let outputGainRamp = processor.outputGainRamp
            let frames = Int(frameCount)

            if abl.count >= 2 {
                guard let left = abl[0].mData?.assumingMemoryBound(to: Float.self),
                      let right = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                    return noErr
                }
                ringBuffer.popStereo(left: left, right: right, frameCount: frames)
                lc_output_gain_ramp_apply_stereo(
                    outputGainRamp,
                    left,
                    right,
                    UInt32(frames)
                )
            } else if let buffer = abl.first,
                      let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                let channels = max(Int(buffer.mNumberChannels), 1)
                ringBuffer.popInterleaved(into: data, count: frames * channels)
                lc_output_gain_ramp_apply_interleaved(
                    outputGainRamp,
                    data,
                    UInt32(frames),
                    UInt32(channels)
                )
            }

            return noErr
        }
    }

    private func performAutomaticRateTransition(to targetRate: Double) throws -> Bool {
        guard !isAutomaticRateTransition,
              abs(targetRate - currentHardwareSampleRate) > 1 else {
            return false
        }

        if originalRateMatchSampleRate == nil {
            originalRateMatchDeviceID = currentOutputDeviceID
            originalRateMatchSampleRate = currentHardwareSampleRate
        }

        rateMatchTransitionID &+= 1
        let transitionID = rateMatchTransitionID
        rateMatchActiveTransitionID = transitionID

        defer {
            if rateMatchActiveTransitionID == transitionID {
                rateMatchActiveTransitionID = 0
            }
        }

        do {
            try performRateTransition(
                to: targetRate,
                successStatus: L10n.format("runtime.rate.active", Self.rateText(targetRate)),
                transitionID: transitionID
            )
        } catch {
            // A failed teardown barrier must remain stopped until an explicit
            // retry. Keep the original restore target; do not start a new graph.
            if let failure = error as? AudioGraphTransitionFailure, !failure.recovered {
                throw failure
            }
            rateMatchPhase = .rollback
            let originalRate = originalRateMatchSampleRate
            let originalDevice = originalRateMatchDeviceID
            var rollbackSucceeded = false
            if let originalRate, originalDevice == currentOutputDeviceID {
                do {
                    rateMatchTransitionID &+= 1
                    let rollbackID = rateMatchTransitionID
                    rateMatchActiveTransitionID = rollbackID
                    try performRateTransition(
                        to: originalRate,
                        successStatus: L10n.format("runtime.rate.rollback", Self.rateText(originalRate)),
                        transitionID: rollbackID
                    )
                    rollbackSucceeded = true
                } catch {
                    rollbackSucceeded = false
                }
            }
            if rollbackSucceeded {
                originalRateMatchSampleRate = nil
                originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
            }
            throw error
        }
        return true
    }

    private func restoreOriginalRateMatchIfNeeded(reconfigureEngine: Bool = true) throws {
        guard let originalRate = originalRateMatchSampleRate,
              originalRateMatchDeviceID == currentOutputDeviceID else {
            return
        }

        if reconfigureEngine, isStarted {
            rateMatchTransitionID &+= 1
            let restoreID = rateMatchTransitionID
            rateMatchActiveTransitionID = restoreID
            defer {
                if rateMatchActiveTransitionID == restoreID {
                    rateMatchActiveTransitionID = 0
                }
            }
            try performRateTransition(
                to: originalRate,
                successStatus: L10n.format("runtime.rate.offRestored", Self.rateText(originalRate)),
                transitionID: restoreID
            )
        } else {
            try AudioLifecyclePolicy.restoreRate(originalRate,
                apply: { try setAndConfirmHardwareRate(originalRate) }, didRestore: {})
        }
        originalRateMatchSampleRate = nil
        originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    private func performRateTransition(to targetRate: Double,
                                       successStatus: String,
                                       transitionID: UInt64) throws {
        guard !isAutomaticRateTransition else { throw AppError.message(L10n.string("runtime.transition.busy")) }
        isAutomaticRateTransition = true
        let rollbackRate = currentHardwareSampleRate
        rateMatchStatus = L10n.format("runtime.rate.switching", Self.rateText(targetRate))
        defer { isAutomaticRateTransition = false; publishFormatStatus() }
        do {
            try runGraphTransition(
                installTarget: {
                    let confirmed = try self.setAndConfirmHardwareRate(targetRate)
                    try self.restartForHardwareFormat(deviceID: self.currentOutputDeviceID, hardwareSampleRate: confirmed)
                },
                rollbackRate: rollbackRate
            )
            rateMatchPhase = .running
            rateMatchStatus = successStatus
            rateMatchLog("tid=\(transitionID) complete rate=\(Self.rateText(targetRate))")
        } catch {
            rateMatchPhase = .aborted
            rateMatchStatus = String(describing: error)
            throw error
        }
    }

    private func runGraphTransition(installTarget: () throws -> Void, rollbackRate: Double) throws {
        do {
            try withoutActuallyEscaping(installTarget) { installTarget in
                try AudioGraphTransition.run(.init(
                    fadeOut: {
                        self.rateMatchPhase = .fadingOut
                        self.publishFormatStatus()
                        self.requestOutputGain(0, duration: 0.05)
                        // A stopped output has no callback to ramp, and is already silent.
                        if self.outputIsRunning && !self.waitForOutputGain(atMost: 0.001, timeout: 0.25) {
                            throw AppError.message(L10n.string("runtime.transition.fadeOutTimeout"))
                        }
                    },
                    quiesce: { try self.suspendForHardwareReconfigure() },
                    installTarget: installTarget,
                    installRollback: {
                        self.rateMatchPhase = .rollback
                        let confirmed = try self.setAndConfirmHardwareRate(rollbackRate)
                        try self.restartForHardwareFormat(deviceID: self.currentOutputDeviceID, hardwareSampleRate: confirmed)
                    },
                    verifyFlow: {
                        self.rateMatchPhase = .waitingForCapture
                        self.ringWrittenAtTransitionStart = self.ringBuffer.totalWrittenSamples()
                        self.ringReadAtTransitionStart = self.ringBuffer.totalReadSamples()
                        guard self.waitForAudioFlowRecovery(timeout: 0.75) else {
                            throw AppError.message(L10n.string("runtime.transition.flowTimeout"))
                        }
                    },
                    fadeIn: {
                        self.rateMatchPhase = .fadingIn
                        self.requestOutputGain(1, duration: 0.08)
                        guard self.waitForOutputGain(atLeast: 0.99, timeout: 0.5) else {
                            throw AppError.message(L10n.string("runtime.transition.fadeInTimeout"))
                        }
                    }
                ))
            }
            isStarted = true // Flow and fade-in were verified for the installed graph.
        } catch {
            if let failure = error as? AudioGraphTransitionFailure {
                isStarted = failure.recovered
            }
            throw error
        }
    }

    private func setAndConfirmHardwareRate(_ targetRate: Double, deviceID: AudioObjectID? = nil) throws -> Double {
        let targetDevice = deviceID ?? currentOutputDeviceID
        // Check before any nominal-rate read, write or confirmation wait.
        // Callers still validate the returned rate through their real policy.
        if let rateOperation { return try rateOperation(targetRate, targetDevice) }
        if let actual = try? nominalRate(for: targetDevice),
           abs(actual - targetRate) < 1 { return actual }
        let semaphore = DispatchSemaphore(value: 0)
        let confirmedBox = RateBox()
        if let tracker = hardwareTracker {
            try tracker.requestRateChange(targetRate, for: targetDevice) { rate in
                confirmedBox.set(rate); semaphore.signal()
            }
        } else {
            try setNominalRate(targetRate, for: targetDevice)
        }
        defer { hardwareTracker?.cancelRateChangeConfirmation() }
        return try waitForNominalSampleRate(targetRate, deviceID: targetDevice,
            semaphore: semaphore, confirmedRate: { confirmedBox.get() })
    }

    private func requestOutputGain(_ target: Float, duration: Double) {
        let frameCount = UInt32(max(currentSampleRate * max(duration, 0), 0))
        lc_output_gain_ramp_set_target(outputGainRamp, target, frameCount)
    }

    private func waitForOutputGain(atMost maximumGain: Float,
                                   timeout: TimeInterval) -> Bool {
        let deadline = monotonicTime + max(timeout, 0)
        while monotonicTime < deadline {
            if lc_output_gain_ramp_current(outputGainRamp) <= maximumGain {
                return true
            }
            pauseForGraph(0.005)
        }
        return lc_output_gain_ramp_current(outputGainRamp) <= maximumGain
    }

    private func waitForOutputGain(atLeast minimumGain: Float,
                                   timeout: TimeInterval) -> Bool {
        let deadline = monotonicTime + max(timeout, 0)
        while monotonicTime < deadline {
            if lc_output_gain_ramp_current(outputGainRamp) >= minimumGain {
                return true
            }
            pauseForGraph(0.005)
        }
        return lc_output_gain_ramp_current(outputGainRamp) >= minimumGain
    }

    private func waitForNominalSampleRate(_ targetRate: Double,
                                          deviceID: AudioObjectID,
                                          semaphore: DispatchSemaphore,
                                          confirmedRate: () -> Double?) throws -> Double {
        // Event-wait first; if the listener never fires, polls below will still confirm.
        if let graphIO { graphIO.waitForRateEvent(semaphore, timeout: 0.9) }
        else { _ = semaphore.wait(timeout: .now() + .milliseconds(900)) }

        let fastPollIterations = 30
        func freshConfirmation() -> Double? {
            if let readback = try? nominalRate(for: deviceID), readback.isFinite {
                return readback
            }
            if let confirmed = confirmedRate(), confirmed.isFinite { return confirmed }
            return nil
        }
        // A cached pre-transition value says nothing about the device after a
        // failed set/read. In particular it cannot certify a rollback target.
        var lastRate = freshConfirmation()
        for _ in 0..<fastPollIterations {
            if let lastRate, abs(lastRate - targetRate) <= 1 {
                return lastRate
            }
            pauseForGraph(0.002)
            lastRate = freshConfirmation() ?? lastRate
        }
        if let lastRate, abs(lastRate - targetRate) <= 1 {
            return lastRate
        }
        let observed = lastRate.map(Self.rateText) ?? "unknown (no finite readback)"
        throw AppError.message(
            "DAC did not confirm \(Self.rateText(targetRate)); current \(observed)."
        )
    }

    private func waitForAudioFlowRecovery(timeout: TimeInterval) -> Bool {
        let deadline = monotonicTime + max(timeout, 0)
        while monotonicTime < deadline {
            let captureAdvanced =
                ringBuffer.totalWrittenSamples() > ringWrittenAtTransitionStart
            let outputAdvanced =
                ringBuffer.totalReadSamples() > ringReadAtTransitionStart
            if captureAdvanced && outputAdvanced && outputIsRunning {
                return true
            }
            pauseForGraph(0.002)
        }
        return ringBuffer.totalWrittenSamples() > ringWrittenAtTransitionStart
            && ringBuffer.totalReadSamples() > ringReadAtTransitionStart
            && outputIsRunning
    }

    private func disableAutomaticRateMatchingForSession(_ error: Error) {
        rateMatchSessionDisabled = true
        rateMatchCoordinator.invalidateSource()
        rateMatchPhase = .aborted
        rateMatchStatus = L10n.format("runtime.rate.paused", String(describing: error))
        requestOutputGain(1, duration: 0.08)
        publishFormatStatus()
    }

    private func makeHardwareTracker(io: HardwareTrackerIO? = nil) -> HardwareSampleRateTracker {
        HardwareSampleRateTracker(queue: managerQueue, io: io) { [weak self] deviceID, sampleRate in
            self?.handleHardwareFormatChange(deviceID: deviceID, sampleRate: sampleRate)
        }
    }

    private func handleHardwareFormatChange(deviceID: AudioObjectID, sampleRate: Double) {
        let newHardwareSampleRate: Double
        do { newHardwareSampleRate = try Self.validSampleRate(sampleRate) }
        catch {
            if isStarted { reportSuspensionFailureIfNeeded() }
            rateMatchStatus = L10n.format("runtime.format.unsupported", String(describing: error))
            publishFormatStatus()
            return
        }
        let deviceChanged = deviceID != currentOutputDeviceID
        let rateChanged = abs(newHardwareSampleRate - currentHardwareSampleRate) > 0.5

        if (deviceChanged || rateChanged) && !isAutomaticRateTransition {
            originalRateMatchSampleRate = nil
            originalRateMatchDeviceID = AudioObjectID(kAudioObjectUnknown)
            rateMatchCoordinator.invalidateSource()
            rateMatchStatus = automaticRateMatchingEnabled
                ? L10n.string("runtime.rate.deviceChanged")
                : L10n.string("runtime.rate.off")
            // An external device/rate change invalidates the live PCM 2× split
            // (tap 1× / output 2×). Drop back to PCM bypass and let the normal
            // reconfigure run the aggregate and output at the device's new rate.
            if livePCM2xActive {
                livePCM2xActive = false
                livePCM2xOutputRate = 0
                preLivePCM2xHardwareRate = nil
                preLivePCM2xDeviceID = kAudioObjectUnknown
                publishLivePCM2xStatus(
                    active: false,
                    fallbackReason: L10n.string("runtime.output.deviceChanged")
                )
            }
        }

        rateMatchLog("hardware-change device=\(deviceID) rate=\(Self.rateText(newHardwareSampleRate)) deviceChanged=\(deviceChanged) rateChanged=\(rateChanged) duringAuto=\(isAutomaticRateTransition) phase=\(rateMatchPhase.rawValue)")

        guard isStarted else {
            currentOutputDeviceID = deviceID
            currentHardwareSampleRate = newHardwareSampleRate
            publishFormatStatus()
            return
        }

        if isAutomaticRateTransition {
            rateMatchLog("listener ignored during automatic transition (tid=\(rateMatchActiveTransitionID))")
            publishFormatStatus()
            return
        }

        guard deviceChanged || rateChanged else {
            publishFormatStatus()
            return
        }

        do {
            try reconfigureForHardwareFormat(deviceID: deviceID, hardwareSampleRate: newHardwareSampleRate)
        } catch {
            reportSuspensionFailureIfNeeded(after: error)
            rateMatchStatus = L10n.format("runtime.format.outputResetFailed", String(describing: error))
            publishFormatStatus()
            fputs("Output format reconfigure failed: \(error)\n", stderr)
        }

    }

    private func reconfigureForHardwareFormat(deviceID: AudioObjectID, hardwareSampleRate: Double) throws {
        do { try suspendForHardwareReconfigure() }
        catch { throw AudioGraphTransitionFailure(cause: error, recoveryFailure: error) }
        try restartForHardwareFormat(
            deviceID: deviceID,
            hardwareSampleRate: hardwareSampleRate
        )
    }

    private func suspendForHardwareReconfigure() throws {
        try quiesceAndDestroyCapture()
        ringBuffer.clear()
        visualizerRingBuffer.requestDiscard()
        controlQueue.drain()
        resetDSPState()
        engineRestartCount &+= 1
    }

    private func quiesceAndDestroyCapture() throws {
        // Close both admissions before waiting on either callback. A timeout
        // keeps that callback's retained processor alive and forbids all resets.
        outputCallbackLifetime?.disable()
        captureCallbackLifetime?.disable()
        try quiesceOutput()
        if let lifetime = captureCallbackLifetime {
            try lifetime.waitForQuiescence()
            lifetime.releaseOwnerAfterQuiescence(on: managerQueue)
        }
        try stopCaptureAndDestroyAggregateDevice()
        try destroyProcessTap()
    }

    private func quiesceOutput() throws {
        outputCallbackLifetime?.disable()
        if let lifetime = outputCallbackLifetime {
            try lifetime.waitForQuiescence()
            lifetime.releaseOwnerAfterQuiescence(on: managerQueue)
        }
        stopOutputEngine()
        guard !outputIsRunning else { throw AppError.message(L10n.string("runtime.stop.engineUnconfirmed")) }
    }

    /// Notification handlers cannot throw to Core Audio. Keep the failed graph
    /// and report the failure. A failed teardown is not retried implicitly;
    /// explicit Stop owns the next attempt to release the preserved resources.
    private func reportSuspensionFailureIfNeeded(after error: Error? = nil) {
        isStarted = false
        if let failure = error as? AudioGraphTransitionFailure, !failure.recovered {
            rateMatchPhase = .aborted
            rateMatchLog(L10n.format("runtime.stop.pending", String(describing: failure)))
            return
        }
        do { try suspendForHardwareReconfigure() }
        catch {
            isStarted = false
            rateMatchPhase = .aborted
            rateMatchLog(L10n.format("runtime.stop.pending", String(describing: error)))
        }
    }

    private func cleanupAfterInstallFailure(_ cause: Error) throws -> Never {
        do { try quiesceAndDestroyCapture() }
        catch { throw AudioGraphTransitionFailure(cause: cause, recoveryFailure: error) }
        throw cause
    }

    private func restartForHardwareFormat(deviceID: AudioObjectID,
                                          hardwareSampleRate: Double) throws {
        currentOutputDeviceID = deviceID
        currentHardwareSampleRate = hardwareSampleRate
        try createProcessTapAndAggregateDevice()
        currentSampleRate = try syncAggregateSampleRate(preferredSampleRate: hardwareSampleRate)
        try refreshTapSampleRate()
        try AudioLifecyclePolicy.validateUnityRoute(captureRate: currentTapSampleRate, outputRate: currentSampleRate)
        controlQueue.updateSampleRate(Float(currentTapSampleRate))
        applyCurrentSettingsDirectly()
        conditioningEngine.resetAll()
        conditioningEngine.updateSettings(OutputConditioningParameters())

        do {
            try replaceOutputEngine()
            try configureOutputGraph(sampleRate: currentSampleRate)
            try startOutputEngine()
            try startCapture()
        } catch {
            try cleanupAfterInstallFailure(error)
        }
        publishFormatStatus()
        print("Output format re-synced: \(makeFormatStatus().indicatorText)")
    }

    private func replaceOutputEngine() throws {
        try quiesceOutput()
        detachOutputSource()
        engine = AVAudioEngine()
    }

    private func detachOutputSource() {
        if let sourceNode {
            if graphIO == nil {
                engine.disconnectNodeOutput(sourceNode)
                engine.detach(sourceNode)
            }
            self.sourceNode = nil
        }
        outputCallbackLifetime?.markSourceRemoved()
        outputCallbackLifetime = nil
    }

    private func syncAggregateSampleRate(preferredSampleRate: Double) throws -> Double {
        guard aggregateDeviceID != kAudioObjectUnknown else {
            return preferredSampleRate
        }

        do {
            try setNominalRate(preferredSampleRate, for: aggregateDeviceID)
        } catch {
            fputs("Aggregate sample rate set skipped: \(error)\n", stderr)
        }

        return try Self.validSampleRate(nominalRate(for: aggregateDeviceID))
    }

    private func stopCaptureAndDestroyAggregateDevice() throws {
        if aggregateDeviceID == kAudioObjectUnknown {
            return
        }

        if let ioProcID {
            let stopStatus = try AudioTeardownAdapter.unregisterIOProc(
                stop: { graphIO?.stopCapture(aggregateDeviceID, ioProc: ioProcID)
                    ?? AudioDeviceStop(aggregateDeviceID, ioProcID) },
                destroy: { graphIO?.unregisterCapture(aggregateDeviceID, ioProc: ioProcID)
                    ?? AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID) },
                didUnregister: {
                    self.ioProcID = nil
                    captureCallbackLifetime?.markSourceRemoved()
                    captureCallbackLifetime = nil
                }
            )
            if stopStatus != noErr { rateMatchLog("AudioDeviceStop=\(stopStatus); IOProc 제거 성공으로 종료 확인") }
        }

        try AudioTeardownAdapter.destroy("AudioHardwareDestroyAggregateDevice",
            call: { graphIO?.destroyAggregate(aggregateDeviceID)
                ?? AudioHardwareDestroyAggregateDevice(aggregateDeviceID) },
            didDestroy: { aggregateDeviceID = AudioObjectID(kAudioObjectUnknown) })
    }

    private func destroyProcessTap() throws {
        guard tapID != kAudioObjectUnknown else { return }
        try removeTapFormatListener()
        try AudioTeardownAdapter.destroy("AudioHardwareDestroyProcessTap",
            call: { graphIO?.destroyTap(tapID) ?? AudioHardwareDestroyProcessTap(tapID) },
            didDestroy: { tapID = AudioObjectID(kAudioObjectUnknown) })
    }

    private func resetDSPState() {
        tonalDSP.resetState()
        spatializer.resetState()
    }

    // Written by the manager only while callbacks are quiescent, then consumed
    // by the first capture callback after a rebuild (including PCM 2x).
    private var initialToneReceipt: UInt64 = 0

    private func applyCurrentSettingsDirectly() {
        // DSP/capture runs at the tap rate (the captured signal's rate). This is
        // distinct from the *output* rate (`currentSampleRate`) once live PCM 2×
        // is active — the tonal DSP still operates on the 1× captured signal.
        let sampleRate = Float(currentTapSampleRate)
        let dspSettings = DSPPrecompute.makeDSPSettings(
            sampleRate: sampleRate,
            intensity: currentIntensity,
            body: currentBody,
            outputDb: currentOutputDb,
            dspModel: currentDSPModel,
            exciterOversamplingMode: currentExciterOversamplingMode
        )
        tonalDSP.update(dspSettings)
        initialToneReceipt = LockFreeControlEventQueue.receiptWord(for: dspSettings)
        tonalDSP.resetState()
        let submission = spatialSubmissions.load()
        currentSpatialSettings = submission.settings
        spatialSubmissionRevision = submission.revision
        spatializer.update(DSPPrecompute.makeSpatialSettings(sampleRate: sampleRate, settings: submission.settings))
        spatializer.resetState()
        controlQueue.acknowledgeSpatial(submission.revision)
    }

    private func publishFormatStatus() {
        publishManagerDisplayState()
        let status = makeFormatStatus()
        let capabilities = try? rateCapabilities(for: currentOutputDeviceID)
        let rateMatchingEnabled = automaticRateMatchingEnabled
        let currentRateMatchStatus = rateMatchStatus
        let currentRateMatchPhase = rateMatchPhase.rawValue
        let sessionID = notificationSessionID
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: AudioFormatNotifications.didChange,
                object: nil,
                userInfo: [
                    "processorSessionID": sessionID,
                    AudioFormatNotifications.sampleRateKey: status.sampleRate,
                    AudioFormatNotifications.tapSampleRateKey: status.tapSampleRate,
                    AudioFormatNotifications.processingSampleRateKey: status.processingSampleRate,
                    AudioFormatNotifications.sampleFormatKey: status.sampleFormat,
                    AudioFormatNotifications.isSampleRateMatchedKey: status.isSampleRateMatched,
                    AudioFormatNotifications.indicatorTextKey: status.indicatorText,
                    AudioFormatNotifications.supportedSampleRatesKey: capabilities?.supportedRates ?? [],
                    AudioFormatNotifications.isSampleRateSettableKey: capabilities?.isSettable ?? false,
                    AudioFormatNotifications.automaticRateMatchingEnabledKey: rateMatchingEnabled,
                    AudioFormatNotifications.rateMatchStatusKey: currentRateMatchStatus,
                    AudioFormatNotifications.rateMatchPhaseKey: currentRateMatchPhase
                ]
            )
        }
    }

    private func makeFormatStatus() -> AudioFormatStatus {
        AudioFormatStatus(
            sampleRate: currentHardwareSampleRate,
            tapSampleRate: currentTapSampleRate,
            processingSampleRate: currentSampleRate,
            sampleFormat: "32-bit Float",
            isSampleRateMatched: abs(currentHardwareSampleRate - currentSampleRate) <= 0.5
        )
    }

    private static func validSampleRate(_ sampleRate: Double) throws -> Double {
        guard sampleRate.isFinite, (8_000...768_000).contains(sampleRate) else {
            throw AppError.message(L10n.format("runtime.format.range", sampleRate))
        }
        return sampleRate
    }

    private static func rateText(_ sampleRate: Double) -> String {
        String(format: "%.1f kHz", sampleRate / 1_000)
    }

    private func rateMatchLog(_ message: String) {
        NSLog("[RateMatch] %@", message)
        let line = "\(Date().timeIntervalSince1970) \(message)\n"
        let path = NSTemporaryDirectory() + "lowend-ratematch.log"
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
            handle.seekToEndOfFile()
            if let data = line.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func refreshTapSampleRate() throws {
        guard tapID != kAudioObjectUnknown else { throw AppError.message(L10n.string("runtime.capture.noTap")) }
        currentTapSampleRate = try Self.validSampleRate(readTapSampleRate(tapID))
    }

    private func readTapSampleRate(_ tap: AudioObjectID) throws -> Double {
        if let graphIO { return try graphIO.tapRate(tap) }
        return try Self.tapFormat(for: tap).mSampleRate
    }

    private func installTapFormatListener() throws {
        guard tapID != kAudioObjectUnknown, tapFormatListener == nil else { return }

        let observedTapID = tapID
        let token = HardwareObservationToken()
        tapFormatObservationToken = token
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let state = TapFormatEventHandler.State(previousSampleRate: currentTapSampleRate,
                isStarted: isStarted, isAutomaticTransition: isAutomaticRateTransition,
                isLivePCM2x: livePCM2xActive)
            TapFormatEventHandler.handle(state: state, operations: .init(
                isCurrentRegistration: { token.isValid && self.tapID == observedTapID },
                readCurrentSampleRate: { try self.readTapSampleRate(observedTapID) },
                acceptSampleRate: { self.currentTapSampleRate = $0 },
                rebuildNormalGraph: {
                    try self.reconfigureForHardwareFormat(deviceID: self.currentOutputDeviceID,
                                                         hardwareSampleRate: self.currentHardwareSampleRate)
                },
                deactivateLivePCM2x: {
                    if let error = self.deactivateLivePCM2x(parameters: OutputConditioningParameters()) {
                        throw error
                    }
                    guard self.isStarted, self.preLivePCM2xHardwareRate == nil else {
                        throw AppError.message(L10n.format("runtime.output.disableUnconfirmed", self.rateMatchStatus))
                    }
                    self.publishLivePCM2xStatus(active: false,
                        fallbackReason: L10n.string("runtime.output.tapChanged"))
                },
                reportFailure: { error, phase in
                    if state.isStarted { self.reportSuspensionFailureIfNeeded(after: error) }
                    let operation = phase == .read ? L10n.string("runtime.capture.read") : L10n.string("runtime.capture.reset")
                    self.rateMatchStatus = L10n.format("runtime.capture.formatFailed", operation, String(describing: error))
                },
                publishState: { self.publishFormatStatus() }
            ))
        }
        tapFormatListener = listener
        var address = Self.tapFormatAddress()
        do {
            try check(
                graphIO?.addTapListener(tapID, queue: managerQueue, listener: listener)
                    ?? AudioObjectAddPropertyListenerBlock(tapID, &address, managerQueue, listener),
                "AudioObjectAddPropertyListenerBlock TapFormat"
            )
        } catch {
            token.invalidate()
            tapFormatObservationToken = nil
            tapFormatListener = nil
            throw error
        }
    }

    private func removeTapFormatListener() throws {
        guard tapID != kAudioObjectUnknown, let tapFormatListener else { return }
        // Retire delivery before removal, including when Core Audio reports a
        // removal failure and the block must remain retained for a retry.
        tapFormatObservationToken?.invalidate()
        var address = Self.tapFormatAddress()
        try AudioTeardownAdapter.destroy("AudioObjectRemovePropertyListenerBlock TapFormat",
            call: { graphIO?.removeTapListener(tapID, listener: tapFormatListener)
                ?? AudioObjectRemovePropertyListenerBlock(tapID, &address, managerQueue, tapFormatListener) },
            didDestroy: {
                self.tapFormatListener = nil
                self.tapFormatObservationToken = nil
            })
    }

    private static func tapFormat(for tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = tapFormatAddress()
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format),
            "AudioObjectGetPropertyData TapFormat"
        )
        return format
    }

    private static func tapFormatAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func makeTapDescription() throws -> CATapDescription {
        let description: CATapDescription

        switch settings.mode {
        case .all:
            let ownProcess = try audioProcessObjectID(for: getpid())
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
            currentCaptureTargetSummary = L10n.string("runtime.target.system")
        case .bundleIDs(let bundleIDs):
            let processes = try resolveAudioProcesses(for: bundleIDs)
            description = CATapDescription(
                stereoMixdownOfProcesses: processes.map(\.objectID)
            )
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                description.isProcessRestoreEnabled = true
            }
#endif
            currentCaptureTargetSummary = processes
                .map { "\($0.bundleID) (pid \($0.pid))" }
                .joined(separator: ", ")
        case .listApps:
            throw AppError.message("Cannot start capture while listing apps.")
        case .selfTest:
            throw AppError.message("Cannot start capture while running self-tests.")
        }

        description.name = "LowEnd Native System Tap"
        description.isPrivate = true
        description.isMixdown = true
        description.isMono = false
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private static func readCurrentCaptureTargetSummary(_ tap: AudioObjectID) throws -> String {
        try CaptureTargetSummary.read(processes: {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CATapDescription>?
            var size = UInt32(MemoryLayout.size(ofValue: value))
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &value),
                      "AudioObjectGetPropertyData TapDescription")
            guard let description = value?.takeRetainedValue(), !description.isExclusive else {
                throw AppError.message(L10n.string("runtime.capture.listFailed"))
            }
            return description.processes
        }, identity: { objectID in
            let pid = try processPID(for: objectID)
            let bundleID = try processBundleID(for: objectID)
            guard try processPID(for: objectID) == pid else {
                throw AppError.message(L10n.string("runtime.capture.changed"))
            }
            return CaptureTargetSummary.Identity(pid: pid, bundleID: bundleID)
        })
    }

    private func resolveAudioProcesses(for requestedBundleIDs: [String]) throws -> [AudioProcessInfo] {
        let requested = requestedBundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !requested.isEmpty else {
            throw AppError.message(L10n.string("runtime.capture.emptyID"))
        }

        let connected = try Self.audioProcessInfos()
        let descriptors = connected.map {
            AudioProcessDescriptor(
                objectID: $0.objectID,
                pid: $0.pid,
                bundleID: $0.bundleID,
                isRunningOutput: $0.isRunningOutput
            )
        }
        let resolved = AudioProcessMatcher.resolve(
            requestedBundleIDs: requestedBundleIDs,
            from: descriptors
        )
        let resolvedIDs = Set(resolved.map(\.objectID))
        let selected = connected.filter { resolvedIDs.contains($0.objectID) }
        guard !selected.isEmpty else {
            throw AppError.message(
                L10n.format("runtime.capture.notFound", requestedBundleIDs.joined(separator: ", "))
            )
        }

        var seen = Set<AudioObjectID>()
        return selected.filter { seen.insert($0.objectID).inserted }
    }

    private static func audioProcessInfos() throws -> [AudioProcessInfo] {
        let objectIDs = try audioProcessObjectIDs()
        return objectIDs.compactMap { objectID in
            guard let bundleID = try? processBundleID(for: objectID), !bundleID.isEmpty else {
                return nil
            }
            let pid = (try? processPID(for: objectID)) ?? 0
            let isRunningOutput = (try? processIsRunningOutput(for: objectID)) ?? false
            return AudioProcessInfo(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID,
                isRunningOutput: isRunningOutput
            )
        }
    }

    private static func audioProcessObjectIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            "AudioObjectGetPropertyDataSize ProcessObjectList"
        )

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objectIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        let status = objectIDs.withUnsafeMutableBytes { storage in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize,
                storage.baseAddress!
            )
        }
        try check(status, "AudioObjectGetPropertyData ProcessObjectList")
        return objectIDs.filter { $0 != kAudioObjectUnknown }
    }

    private static func processBundleID(for objectID: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleID: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &bundleID),
            "AudioObjectGetPropertyData ProcessBundleID"
        )
        return bundleID?.takeRetainedValue() as String? ?? ""
    }

    private static func processPID(for objectID: AudioObjectID) throws -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &pid),
            "AudioObjectGetPropertyData ProcessPID"
        )
        return pid
    }

    private static func processIsRunningOutput(for objectID: AudioObjectID) throws -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value),
            "AudioObjectGetPropertyData ProcessIsRunningOutput"
        )
        return value != 0
    }

    private func audioProcessObjectID(for pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let status = withUnsafePointer(to: &processID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                qualifier,
                &dataSize,
                &processObjectID
            )
        }

        try check(status, "AudioObjectGetPropertyData TranslatePIDToProcessObject")

        if processObjectID == kAudioObjectUnknown {
            throw AppError.message("Could not find current Core Audio process object.")
        }

        return processObjectID
    }

    private func createProcessTapAndAggregateDevice() throws {
        guard tapID == kAudioObjectUnknown,
              aggregateDeviceID == kAudioObjectUnknown,
              ioProcID == nil else {
            throw AppError.message("Capture graph must be fully destroyed before recreation.")
        }

        let tapDescription = try graphIO?.makeTapDescription() ?? makeTapDescription()
        do {
            let tapStatus: OSStatus
            if let graphIO {
                (tapStatus, tapID) = graphIO.createTap(tapDescription)
            } else {
                tapStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
            }
            try check(
                tapStatus,
                "AudioHardwareCreateProcessTap"
            )
            try refreshTapSampleRate()
            do {
                try installTapFormatListener()
            } catch {
                fputs("Tap format listener unavailable: \(error)\n", stderr)
            }

            let tapUID = tapDescription.uuid.uuidString
            let aggregateUID = "com.codexaudiolab.lowendcircuit.aggregate.\(UUID().uuidString)"
            let tapEntry: [String: Any] = [
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true
            ]

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "LowEnd Native Audio",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [tapEntry],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]

            let aggregateStatus: OSStatus
            if let graphIO {
                (aggregateStatus, aggregateDeviceID) = graphIO.createAggregate(aggregateDescription as CFDictionary)
            } else {
                aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary,
                                                                     &aggregateDeviceID)
            }
            try check(
                aggregateStatus,
                "AudioHardwareCreateAggregateDevice"
            )
        } catch {
            try cleanupAfterInstallFailure(error)
        }
    }

    private func startCapture() throws {
        // Manager-only: publish the new baseline before registering a callback
        // that could run immediately. Never discard early data at GUI completion.
        audioFlowGeneration &+= 1
        ringWrittenAtCaptureStart = ringBuffer.totalWrittenSamples()
        ringReadAtCaptureStart = ringBuffer.totalReadSamples()
        publishManagerDisplayState()
        let lifetime = try AudioCallbackLifetime(retaining: self)
        captureCallbackLifetime = lifetime
        let callback: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let gate = OpaquePointer(clientData)
            guard let userdata = lc_callback_gate_try_enter(gate) else { return noErr }
            defer { lc_callback_gate_leave(gate) }
            let processor = Unmanaged<SystemAudioProcessor>.fromOpaque(userdata).takeUnretainedValue()
            processor.handleInput(inputData)
            return noErr
        }

        let result: OSStatus
        if let graphIO {
            (result, ioProcID) = graphIO.registerCapture(aggregateDeviceID, callback: callback,
                clientData: UnsafeMutableRawPointer(lifetime.handle))
        } else {
            result = AudioDeviceCreateIOProcID(aggregateDeviceID, callback,
                UnsafeMutableRawPointer(lifetime.handle), &ioProcID)
        }
        if ioProcID == nil {
            // No registered source can call this gate. Keep normal quiescence
            // and deferred owner release even when registration itself failed.
            lifetime.disable()
            try lifetime.waitForQuiescence()
            lifetime.releaseOwnerAfterQuiescence(on: managerQueue)
            lifetime.markSourceRemoved()
            captureCallbackLifetime = nil
            if result == noErr { throw AppError.message("AudioDeviceCreateIOProcID did not return a callback registration.") }
        }
        try check(result, "AudioDeviceCreateIOProcID")

        try check(graphIO?.startCapture(aggregateDeviceID, ioProc: ioProcID)
            ?? AudioDeviceStart(aggregateDeviceID, ioProcID), "AudioDeviceStart")
    }

    private func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }

        applyPendingControlEvents()

        // A disabled channel may have nil mData. Accept only complete supported
        // Float layouts; never reinterpret a partial stereo block as mono.
        let sampleBytes = UInt32(MemoryLayout<Float>.size)
        if buffers.count == 2 {
            let second = buffers[1]
            guard first.mNumberChannels == 1, second.mNumberChannels == 1,
                  first.mDataByteSize == second.mDataByteSize,
                  first.mDataByteSize % sampleBytes == 0,
                  let leftData = first.mData?.assumingMemoryBound(to: Float.self),
                  let rightData = second.mData?.assumingMemoryBound(to: Float.self) else { return }
            processAndPushStereo(left: leftData, right: rightData,
                                 frameCount: Int(first.mDataByteSize / sampleBytes))
        } else if buffers.count == 1 {
            guard let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            switch first.mNumberChannels {
            case 2:
                let frameBytes = sampleBytes * 2
                guard first.mDataByteSize % frameBytes == 0 else { return }
                processAndPushInterleavedStereo(data, frameCount: Int(first.mDataByteSize / frameBytes))
            case 1:
                guard first.mDataByteSize % sampleBytes == 0 else { return }
                processAndPushMono(data, frameCount: Int(first.mDataByteSize / sampleBytes))
            default:
                return
            }
        }
    }

    private func applyPendingControlEvents() {
        var event = LCControlEvent()
        var latestDSP = LCDSPSettings()
        var hasDSP = false
        var latestDSPReceipt: UInt64 = 0
        var latestSpatial = LCSpatialSettings()
        var hasSpatial = false
        var spatialRevision: UInt64 = 0
        var latestConditioning = LCOutputConditioningSettings()
        var hasConditioning = false

        for _ in 0..<LockFreeControlEventQueue.callbackDrainBudget {
            guard controlQueue.pop(into: &event) else { break }
            switch event.type {
            case UInt32(LC_CONTROL_EVENT_DSP):
                latestDSP = event.dsp
                latestDSPReceipt = event.revision
                hasDSP = true
            case UInt32(LC_CONTROL_EVENT_SPATIAL):
                latestSpatial = event.spatial
                spatialRevision = event.revision
                hasSpatial = true
            case UInt32(LC_CONTROL_EVENT_OUTPUT_CONDITIONING):
                latestConditioning = event.conditioning
                hasConditioning = true
            default:
                break
            }
        }

        if hasDSP {
            tonalDSP.update(latestDSP)
            controlQueue.acknowledgeDSP(latestDSPReceipt)
        } else if initialToneReceipt != 0 {
            controlQueue.acknowledgeDSP(initialToneReceipt)
        }
        initialToneReceipt = 0

        if hasSpatial {
            spatializer.update(latestSpatial)
            controlQueue.acknowledgeSpatial(spatialRevision)
        }

        if hasConditioning {
            conditioningEngine.updateSettings(Self.parameters(from: latestConditioning),
                precomputedHeadroomGain: latestConditioning.headroomGain)
        }
    }

    private func processAndPushStereo(left: UnsafePointer<Float>,
                                      right: UnsafePointer<Float>,
                                      frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunkFrames = min(scratchFrameCapacity, frameCount - offset)
            let leftChunk = left.advanced(by: offset)
            let rightChunk = right.advanced(by: offset)

            for frame in 0..<chunkFrames {
                let processed = processSelectedModel(left: leftChunk[frame], right: rightChunk[frame])
                let output = processPostModel(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = output.0
                inputScratch[frame * 2 + 1] = output.1
            }

            // Output-conditioning layer. Bypass (verbatim copy) unless the live
            // PCM 2× mode is active, in which case this upsamples 2× and the
            // returned frame count is 2× the input. Never in-place: it writes into
            // conditioningOutputScratch so a rate-changing output cannot overwrite
            // its own input. Push the produced frames at the *output* rate.
            let conditioningFrames = conditioningEngine.processLive(
                input: inputScratch,
                inputFrames: chunkFrames,
                output: conditioningOutputScratch
            )
            ringBuffer.push(conditioningOutputScratch, count: conditioningFrames * 2)
            visualizerRingBuffer.push(conditioningOutputScratch, count: conditioningFrames * 2)
            offset += chunkFrames
        }
    }

    private func processAndPushInterleavedStereo(_ interleaved: UnsafePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunkFrames = min(scratchFrameCapacity, frameCount - offset)
            let chunk = interleaved.advanced(by: offset * 2)

            for frame in 0..<chunkFrames {
                let processed = processSelectedModel(left: chunk[frame * 2], right: chunk[frame * 2 + 1])
                let output = processPostModel(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = output.0
                inputScratch[frame * 2 + 1] = output.1
            }

            // Output-conditioning layer. Bypass (verbatim copy) unless the live
            // PCM 2× mode is active, in which case this upsamples 2× and the
            // returned frame count is 2× the input. Never in-place: it writes into
            // conditioningOutputScratch so a rate-changing output cannot overwrite
            // its own input. Push the produced frames at the *output* rate.
            let conditioningFrames = conditioningEngine.processLive(
                input: inputScratch,
                inputFrames: chunkFrames,
                output: conditioningOutputScratch
            )
            ringBuffer.push(conditioningOutputScratch, count: conditioningFrames * 2)
            visualizerRingBuffer.push(conditioningOutputScratch, count: conditioningFrames * 2)
            offset += chunkFrames
        }
    }

    private func processAndPushMono(_ mono: UnsafePointer<Float>, frameCount: Int) {
        var offset = 0
        while offset < frameCount {
            let chunkFrames = min(scratchFrameCapacity, frameCount - offset)
            let chunk = mono.advanced(by: offset)

            for frame in 0..<chunkFrames {
                let processed = processSelectedModel(left: chunk[frame], right: chunk[frame])
                let output = processPostModel(left: processed.0, right: processed.1)
                inputScratch[frame * 2] = output.0
                inputScratch[frame * 2 + 1] = output.1
            }

            // Output-conditioning layer. Bypass (verbatim copy) unless the live
            // PCM 2× mode is active, in which case this upsamples 2× and the
            // returned frame count is 2× the input. Never in-place: it writes into
            // conditioningOutputScratch so a rate-changing output cannot overwrite
            // its own input. Push the produced frames at the *output* rate.
            let conditioningFrames = conditioningEngine.processLive(
                input: inputScratch,
                inputFrames: chunkFrames,
                output: conditioningOutputScratch
            )
            ringBuffer.push(conditioningOutputScratch, count: conditioningFrames * 2)
            visualizerRingBuffer.push(conditioningOutputScratch, count: conditioningFrames * 2)
            offset += chunkFrames
        }
    }

    private func processSelectedModel(left: Float, right: Float) -> (Float, Float) {
        let safeLeft = left.isFinite ? left : 0
        let safeRight = right.isFinite ? right : 0

        return tonalDSP.process(left: safeLeft, right: safeRight)
    }

    private func processPostModel(left: Float, right: Float) -> (Float, Float) {
        // Spatial audio is an INDEPENDENT stage. The model bypass (Clean) only
        // skips the tonal DSP (Circuit / HighExciter); it must not silence the
        // spatializer. The spatializer itself no-ops when its `enabled` flag is
        // off or its amount is ~0, so Clean + spatial-off stays a pure pass-through.
        return spatializer.process(left: left, right: right)
    }

    /// Drive the actual stop() and the caller's actual ownership path from the
    /// reachable state with no graph resources and an outstanding restoration.
    /// Only this test entrypoint seeds the private pending rate/device fields.
    /// It never starts an engine/tap or installs hardware observations.
    @MainActor
    static func runStopRestorationChecks(
        makeOwner: @MainActor (SystemAudioProcessor) -> (
            attempt: @MainActor () -> Bool,
            retainsProcessor: @MainActor () -> Bool
        )
    ) throws {
        enum FirstResult: CaseIterable { case failure, mismatched, nonfinite }
        var assertions = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw AppError.message("Stop restoration checks: \(message)") }
        }
        for isAutomatic in [true, false] {
            for firstResult in FirstResult.allCases {
                let calls = RuntimeSnapshotBox<[(rate: Double, device: AudioObjectID)]>([])
                let processor = try SystemAudioProcessor(settings: Settings(),
                    initialOutput: { (777, 96_000) },
                    rateOperation: { rate, device in
                        var recorded = calls.load()
                        recorded.append((rate, device))
                        calls.store(recorded)
                        if recorded.count == 1 {
                            switch firstResult {
                            case .failure: throw AppError.message("Injected restoration failure")
                            case .mismatched: return 96_000
                            case .nonfinite: return .nan
                            }
                        }
                        return 48_000
                    })
                processor.onManagerQueue {
                    if isAutomatic {
                        processor.originalRateMatchSampleRate = 48_000
                        processor.originalRateMatchDeviceID = 777
                    } else {
                        processor.preLivePCM2xHardwareRate = 48_000
                        processor.preLivePCM2xDeviceID = 777
                        processor.livePCM2xActive = true
                        processor.livePCM2xOutputRate = 96_000
                    }
                }
                func hasNoGraphResources() -> Bool {
                    processor.onManagerQueue {
                        !processor.isStarted && !processor.engine.isRunning
                            && processor.hardwareTracker == nil
                            && processor.tapID == kAudioObjectUnknown
                            && processor.aggregateDeviceID == kAudioObjectUnknown
                            && processor.ioProcID == nil && processor.tapFormatListener == nil
                            && processor.sourceNode == nil
                            && processor.outputCallbackLifetime == nil
                            && processor.captureCallbackLifetime == nil
                            && processor.engineRestartCount == 0
                    }
                }
                let owner = makeOwner(processor)
                try require(hasNoGraphResources() && calls.load().isEmpty,
                            "fixture must begin without a graph or device operation")
                try require(owner.retainsProcessor(), "actual owner did not adopt the fixture instance")
                try require(!owner.attempt(), "first failed/mismatched restoration was accepted")
                try require(owner.retainsProcessor(), "failed stop discarded the actual owner's processor")
                try require(hasNoGraphResources(), "failed restoration created a graph")
                let pendingPreserved = processor.onManagerQueue {
                    if isAutomatic {
                        return processor.originalRateMatchSampleRate == 48_000
                            && processor.originalRateMatchDeviceID == 777
                            && processor.preLivePCM2xHardwareRate == nil
                    }
                    return processor.preLivePCM2xHardwareRate == 48_000
                        && processor.preLivePCM2xDeviceID == 777
                        && processor.originalRateMatchSampleRate == nil
                }
                try require(pendingPreserved, "first stop lost its actual original rate/device fields")
                try require(processor.stopFailureState.load() != nil,
                            "first restoration failure was not published to the owner")
                let firstCalls = calls.load()
                try require(firstCalls.count == 1 && firstCalls[0].rate == 48_000 && firstCalls[0].device == 777,
                            "first stop used a different rate/device or repeated the operation")

                try require(owner.attempt(), "second stop did not accept confirmed restoration")
                try require(!owner.retainsProcessor(), "successful stop kept the actual owner reference")
                let cleared = processor.onManagerQueue {
                    processor.originalRateMatchSampleRate == nil
                        && processor.originalRateMatchDeviceID == kAudioObjectUnknown
                        && processor.preLivePCM2xHardwareRate == nil
                        && processor.preLivePCM2xDeviceID == kAudioObjectUnknown
                        && processor.stopFailureState.load() == nil
                }
                try require(cleared, "confirmed restoration did not clear actual pending fields/failure")
                let finalCalls = calls.load()
                try require(finalCalls.count == 2 && finalCalls[1].rate == 48_000 && finalCalls[1].device == 777,
                            "retry did not use the retained original rate/device")
                try require(hasNoGraphResources(), "successful restoration installed a graph")
                try require(processor.stop() && calls.load().count == 2,
                            "third stop repeated an already confirmed restoration")
            }
        }
        print("StopRestorationChecks: \(assertions) assertions, actual SAP.stop + actual GUI owner, automatic/2x × throw/mismatched/nonfinite first result, retained pending fields and identity then confirmed release; no capture or nominal device calls")
    }

    /// Exercise membership, failed reads, manager publication and the actual
    /// one-second dispatch timer without creating a real tap or device.
    static func runCaptureTargetRefreshChecks() throws {
        enum ReadFailure: Error { case disappeared }
        var assertions = 0
        func expect(_ value: Bool, _ label: String) throws {
            assertions += 1
            guard value else { throw AppError.message("CaptureTargetRefreshChecks: \(label)") }
        }
        let old = "qa.helper (pid 101)"
        let new = "qa.helper (pid 202)"
        var readIDs: [UInt32] = []
        let identity: (UInt32) throws -> CaptureTargetSummary.Identity = { id in
            readIDs.append(id)
            if id == 9 { throw ReadFailure.disappeared }
            return .init(pid: id == 1 ? 101 : 202, bundleID: "qa.helper")
        }
        try expect(try CaptureTargetSummary.read(processes: { [1, 1] }, identity: identity) == old,
                   "deduplicated current membership")
        try expect(readIDs == [1], "only tap members queried")
        try expect(try CaptureTargetSummary.read(processes: { [] }, identity: identity)
                   == L10n.string("runtime.capture.noProcesses"), "empty membership clears old PID")
        try expect(try CaptureTargetSummary.read(processes: { [2] }, identity: identity) == new,
                   "restored process identity replaces old PID")
        do {
            _ = try CaptureTargetSummary.read(processes: { [1, 9] }, identity: identity)
            throw AppError.message("partial membership was accepted")
        } catch ReadFailure.disappeared { assertions += 1 }
        do {
            _ = try CaptureTargetSummary.read(processes: { throw ReadFailure.disappeared }, identity: identity)
            throw AppError.message("tap read failure was accepted")
        } catch ReadFailure.disappeared { assertions += 1 }
        for value in [CaptureTargetSummary.Identity(pid: 0, bundleID: "qa"), .init(pid: 1, bundleID: "")] {
            var rejected = false
            do { _ = try CaptureTargetSummary.read(processes: { [1] }, identity: { _ in value }) }
            catch { rejected = true }
            try expect(rejected, "invalid process identity rejected")
        }
        let observation = RuntimeSnapshotBox<Result<String, Error>>(.success(old))
        let reads = RuntimeSnapshotBox(0)
        let timerSignal = DispatchSemaphore(value: 0)
        let signalEnabled = RuntimeSnapshotBox(false)
        var settings = Settings(); settings.mode = .bundleIDs(["qa"])
        let processor = try SystemAudioProcessor(settings: settings, initialOutput: { (777, 48_000) },
            captureTargetRead: { tap in
                precondition(tap == 999)
                reads.store(reads.load() + 1)
                if signalEnabled.load() { timerSignal.signal() }
                return try observation.load().get()
            })
        defer {
            processor.onManagerQueue {
                processor.isStarted = false; processor.tapID = AudioObjectID(kAudioObjectUnknown)
            }
        }
        try processor.onManagerQueue {
            processor.refreshCaptureTargetSummary()
            try expect(reads.load() == 0, "idle never queries HAL")
            processor.isStarted = true
            processor.refreshCaptureTargetSummary()
            try expect(reads.load() == 0, "unknown tap never queried")
            processor.tapID = 999
            processor.refreshCaptureTargetSummary()
            try expect(processor.captureTargetSummary == old, "actual published initial PID")
            observation.store(.success(new)); processor.refreshCaptureTargetSummary()
            try expect(processor.diagnosticsSnapshot().captureTarget == new, "diagnostics reflects refreshed PID")
            observation.store(.success(L10n.string("runtime.capture.noProcesses"))); processor.refreshCaptureTargetSummary()
            try expect(!processor.captureTargetSummary.contains("pid"), "absent member has no stale PID")
            observation.store(.failure(ReadFailure.disappeared)); processor.refreshCaptureTargetSummary()
            try expect(processor.captureTargetSummary.hasPrefix(L10n.format("runtime.capture.queryFailed", "")), "read failure replaces stale value")
            observation.store(.success(new)); processor.refreshCaptureTargetSummary()
            try expect(processor.captureTargetSummary == new, "read failure recovers without graph restart")
            let count = reads.load(); processor.isStarted = false
            processor.refreshCaptureTargetSummary()
            try expect(reads.load() == count, "stopped observer does not query a retained tap")
            observation.store(.success(old)); processor.isStarted = true; signalEnabled.store(true)
        }
        try expect(timerSignal.wait(timeout: .now() + 3) == .success, "actual periodic timer fired")
        processor.onManagerQueue {}
        try expect(processor.diagnosticsSnapshot().captureTarget == old, "timer publishes to UI snapshot")
        print("CaptureTargetRefreshChecks: \(assertions) assertions; current tap membership, helper PID replacement, disappearance/read failure, idle/stop guards, actual manager timer and snapshot; injected readback, no device calls")
    }

    /// The actual public UI accessors and submission path must remain responsive
    /// while device work occupies management. Uses an injected initial device;
    /// never starts a tap, engine, rate negotiation or callback registration.
    @MainActor
    static func runManagerResponsivenessChecks() throws {
        let processor = try SystemAudioProcessor(settings: Settings(), initialOutput: { (777, 48_000) })
        let entered = DispatchSemaphore(value: 0)
        let finished = RuntimeSnapshotBox(false)
        processor.managerQueue.async {
            entered.signal()
            Thread.sleep(forTimeInterval: 2)
            processor.currentCaptureTargetSummary = "manager resumed"
            processor.publishManagerDisplayState()
            finished.store(true)
        }
        guard entered.wait(timeout: .now() + 5) == .success else {
            throw AppError.message("Manager heartbeat fixture did not start")
        }
        var latencies: [Double] = []
        var heartbeatTimes: [UInt64] = []
        var invalidSnapshot = false
        var finalRevision: UInt64 = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                let start = DispatchTime.now().uptimeNanoseconds
                heartbeatTimes.append(start)
                let summary = processor.captureTargetSummary
                let diagnostics = processor.diagnosticsSnapshot()
                if processor.outputDeviceID != 777 || diagnostics.engineRestartCount != 0
                    || ![L10n.string("runtime.target.system"), "manager resumed"].contains(summary) {
                    invalidSnapshot = true
                }
                _ = processor.stopFailureDescription
                _ = processor.appliedSpatialRevision
                var spatial = SpatialSettings()
                spatial.listenerX = 2.4
                finalRevision = processor.updateSpatial(spatial)
                latencies.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
        }
        defer { timer.invalidate() }
        let timeout = Date().addingTimeInterval(5)
        while !finished.load() && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        timer.invalidate()
        guard finished.load(), !invalidSnapshot, heartbeatTimes.count >= 50,
              latencies.max() ?? .infinity < 100 else {
            throw AppError.message("UI getters/submission blocked behind two-second manager work")
        }
        let latest = processor.spatialSubmissions.load()
        guard latest.revision == finalRevision, finalRevision > 0,
              latest.settings.listenerX == 2.4,
              processor.captureTargetSummary == "manager resumed" else {
            throw AppError.message("Manager wait lost the final UI revision or published snapshot")
        }
        let sorted = latencies.sorted()
        let maxGap = zip(heartbeatTimes.dropFirst(), heartbeatTimes).map {
            Double($0 - $1) / 1_000_000
        }.max() ?? 0
        print(String(format: "ManagerResponsivenessChecks: 2s blocked management, %d MainActor heartbeats, getter+submission p95 %.3f ms/max %.3f ms, max heartbeat gap %.3f ms, final revision %llu retained", heartbeatTimes.count, sorted[Int(Double(sorted.count - 1) * 0.95)], sorted.last!, maxGap, finalRevision))
    }
}

@available(macOS 14.4, *)
extension SystemAudioProcessor {
    /// Exercise the real callback input decoder with owned Float buffers only.
    /// The injected initial device avoids hardware reads; no audio graph starts.
    @MainActor
    static func runInputBufferLayoutChecks() throws {
        enum Layout { case planar, interleaved, mono }
        struct Fixture {
            let name: String
            let layout: Layout
            var frames = 4
            let channels: [UInt32]
            let bytes: [UInt32]
            var nullBuffers: Set<Int> = []
            var accepted = false
        }
        let cases: [Fixture] = [
            Fixture(name: "valid-planar", layout: .planar, channels: [1, 1], bytes: [16, 16], accepted: true),
            Fixture(name: "valid-interleaved", layout: .interleaved, channels: [2], bytes: [32], accepted: true),
            Fixture(name: "valid-mono", layout: .mono, channels: [1], bytes: [16], accepted: true),
            Fixture(name: "planar-chunk-boundary", layout: .planar, frames: 8193, channels: [1, 1], bytes: [32772, 32772], accepted: true),
            Fixture(name: "interleaved-chunk-boundary", layout: .interleaved, frames: 8193, channels: [2], bytes: [65544], accepted: true),
            Fixture(name: "mono-chunk-boundary", layout: .mono, frames: 8193, channels: [1], bytes: [32772], accepted: true),
            Fixture(name: "disabled-right-null", layout: .planar, channels: [1, 1], bytes: [16, 16], nullBuffers: [1]),
            Fixture(name: "disabled-left-null", layout: .planar, channels: [1, 1], bytes: [16, 16], nullBuffers: [0]),
            Fixture(name: "right-shorter", layout: .planar, channels: [1, 1], bytes: [16, 12]),
            Fixture(name: "right-longer", layout: .planar, channels: [1, 1], bytes: [16, 20]),
            Fixture(name: "right-zero-bytes", layout: .planar, channels: [1, 1], bytes: [16, 0]),
            Fixture(name: "extra-buffer", layout: .planar, channels: [1, 1, 1], bytes: [16, 16, 16]),
            Fixture(name: "planar-left-channel-count", layout: .planar, channels: [2, 1], bytes: [16, 16]),
            Fixture(name: "planar-right-channel-count", layout: .planar, channels: [1, 2], bytes: [16, 16]),
            Fixture(name: "single-three-channels", layout: .mono, channels: [3], bytes: [24]),
            Fixture(name: "single-zero-channels", layout: .mono, channels: [0], bytes: [16]),
            Fixture(name: "planar-partial-float", layout: .planar, channels: [1, 1], bytes: [15, 15]),
            Fixture(name: "interleaved-partial-frame", layout: .interleaved, channels: [2], bytes: [28]),
            Fixture(name: "interleaved-partial-float", layout: .interleaved, channels: [2], bytes: [31]),
            Fixture(name: "mono-partial-float", layout: .mono, channels: [1], bytes: [15]),
            Fixture(name: "single-null", layout: .interleaved, channels: [2], bytes: [32], nullBuffers: [0]),
            Fixture(name: "zero-byte-block", layout: .mono, channels: [1], bytes: [0]),
            Fixture(name: "zero-buffers", layout: .mono, channels: [], bytes: [])
        ]
        var settings = Settings(); settings.dspModel = .clean; settings.outputDb = 0
        let processor = try SystemAudioProcessor(settings: settings, initialOutput: { (777, 48_000) },
            rateOperation: { _, _ in throw AppError.message("Input layout checks unexpectedly requested hardware rate work") })
        guard !processor.isStarted, !processor.engine.isRunning, processor.tapID == kAudioObjectUnknown,
              processor.aggregateDeviceID == kAudioObjectUnknown, processor.ioProcID == nil,
              processor.sourceNode == nil, processor.hardwareTracker == nil,
              processor.captureCallbackLifetime == nil, processor.outputCallbackLifetime == nil else {
            throw AppError.message("Input layout checks require an unstarted processor with no audio resources")
        }
        var assertions = 0, failures: [String] = []
        for fixture in cases {
            // Every backing allocation is deliberately larger than all declared
            // byte sizes, even in malformed cases. Rejection is checked without
            // inducing an actual out-of-allocation access in the old decoder.
            let capacity = max(fixture.frames * 2 + 8, 32)
            let sentinel: Float = 1234.5
            let storage = (0..<max(fixture.channels.count, 1)).map { _ -> UnsafeMutablePointer<Float> in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity + 2)
                pointer.initialize(repeating: sentinel, count: capacity + 2)
                return pointer
            }
            defer { for pointer in storage { pointer.deinitialize(count: capacity + 2); pointer.deallocate() } }
            var expected: [Float] = []
            for frame in 0..<fixture.frames {
                let left = Float(frame % 8 + 1) * 0.0625
                let right = -left
                if fixture.layout == .interleaved {
                    storage[0][1 + frame * 2] = left; storage[0][2 + frame * 2] = right
                } else {
                    storage[0][1 + frame] = left
                    if storage.count > 1 { storage[1][1 + frame] = right }
                }
                if fixture.accepted { expected.append(left); expected.append(fixture.layout == .mono ? left : right) }
            }
            let list = AudioBufferList.allocate(maximumBuffers: max(fixture.channels.count, 1))
            defer { list.unsafeMutablePointer.deallocate() }
            for index in fixture.channels.indices {
                list[index] = AudioBuffer(mNumberChannels: fixture.channels[index], mDataByteSize: fixture.bytes[index],
                    mData: fixture.nullBuffers.contains(index) ? nil : UnsafeMutableRawPointer(storage[index].advanced(by: 1)))
            }
            list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(fixture.channels.count)
            let writtenBefore = processor.ringBuffer.totalWrittenSamples()
            let visualBefore = processor.visualizerRingBuffer.totalWrittenSamples()
            processor.handleInput(UnsafePointer(list.unsafeMutablePointer))
            let written = processor.ringBuffer.totalWrittenSamples() - writtenBefore
            let visualWritten = processor.visualizerRingBuffer.totalWrittenSamples() - visualBefore
            var output = [Float](repeating: 0, count: processor.ringBuffer.availableSamples())
            var visual = [Float](repeating: 0, count: processor.visualizerRingBuffer.availableSamples())
            if !output.isEmpty { output.withUnsafeMutableBufferPointer { processor.ringBuffer.popInterleaved(into: $0.baseAddress!, count: $0.count) } }
            if !visual.isEmpty { visual.withUnsafeMutableBufferPointer { processor.visualizerRingBuffer.popInterleaved(into: $0.baseAddress!, count: $0.count) } }
            let expectedCount = UInt64(expected.count)
            let checks = [written == expectedCount, visualWritten == expectedCount, output == expected, visual == expected,
                storage.allSatisfy { $0[0] == sentinel && $0[capacity + 1] == sentinel }]
            assertions += checks.count
            let passed = checks.allSatisfy { $0 }
            if !passed { failures.append(fixture.name) }
            print("InputBufferLayout: \(fixture.name) written=\(written) visual=\(visualWritten) expected=\(expectedCount) exact=\(output == expected && visual == expected) guards=\(checks.last!) \(passed ? "PASS" : "FAIL")")
        }
        guard failures.isEmpty else {
            throw AppError.message("InputBufferLayoutChecks failed: \(failures.joined(separator: ", "))")
        }
        print("InputBufferLayoutChecks: \(cases.count) layouts, \(assertions) assertions; actual handleInput/output+visualizer rings, exact valid PCM including 8193-frame chunks; malformed whole-block drop; injected device only, no start/capture/nominal-rate calls")
    }
}

// The fixture entry point is intentionally separate from start(): it installs
// the real graph through an explicitly injected platform and never starts the
// hardware tracker, resolves processes, requests permissions or reads a device.
@available(macOS 14.4, *)
extension SystemAudioProcessor {
    final class GraphCheckAccess: @unchecked Sendable {
        private let processor: SystemAudioProcessor
        init(io: AudioGraphIO, captureSessionLease: CaptureSessionLease? = nil) throws {
            var settings = Settings()
            settings.dspModel = .clean
            settings.intensity = 0
            settings.body = 0
            settings.outputDb = 0
            settings.automaticRateMatchingEnabled = false
            processor = try SystemAudioProcessor(settings: settings,
                initialOutput: { (777, 48_000) }, graphIO: io, captureSessionLease: captureSessionLease)
        }
        func start(hardwareIO: HardwareTrackerIO) throws { try processor.start(hardwareIO: hardwareIO) }
        func withProcessorForUICheck(_ body: (SystemAudioProcessor) -> Void) { body(processor) }
        func makeStartFailureObserver(_ factory: (SystemAudioProcessor) -> CaptureStartFailureCheckObserver) -> CaptureStartFailureCheckObserver {
            factory(processor)
        }
        func seed(_ rate: Double = 48_000) throws {
            try processor.onManagerQueue {
                precondition(processor.graphIO != nil && processor.hardwareTracker == nil)
                try processor.restartForHardwareFormat(deviceID: 777, hardwareSampleRate: rate)
                processor.isStarted = true
            }
        }
        func transition(_ rate: Double) throws {
            try processor.onManagerQueue {
                try processor.performRateTransition(to: rate, successStatus: "offline route verified", transitionID: 1)
            }
        }
        func reconfigureHardwareFormat(_ rate: Double) throws {
            try processor.onManagerQueue {
                try processor.reconfigureForHardwareFormat(deviceID: 777, hardwareSampleRate: rate)
            }
        }
        func attachHardwareTracker(_ io: HardwareTrackerIO) throws -> HardwareSampleRateTracker {
            try processor.onManagerQueue {
                precondition(processor.graphIO != nil && processor.hardwareTracker == nil)
                let tracker = processor.makeHardwareTracker(io: io)
                processor.hardwareTracker = tracker
                try tracker.start()
                return tracker
            }
        }
        func managerBarrier() { processor.onManagerQueue {} }
        func restartHardwareTracker(_ tracker: HardwareSampleRateTracker) throws {
            try processor.onManagerQueue {
                precondition(!processor.isStarted && processor.hardwareTracker == nil && processor.graphIO != nil)
                processor.hardwareTracker = tracker
                try tracker.start()
            }
        }
        func stallManager(entered: DispatchSemaphore, release: DispatchSemaphore) {
            processor.managerQueue.async {
                entered.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        func automaticTransition(_ rate: Double) throws {
            _ = try processor.onManagerQueue { try processor.performAutomaticRateTransition(to: rate) }
        }
        func live2x(_ enabled: Bool) {
            processor.onManagerQueue {
                var parameters = OutputConditioningParameters()
                parameters.isEnabled = enabled
                parameters.outputMode = enabled ? .pcmOversampling : .bypass
                parameters.oversamplingFactor = 2
                processor.applyLivePCM2xState(for: parameters)
            }
        }
        func transitionToLive2x() throws {
            try processor.onManagerQueue {
                var parameters = OutputConditioningParameters()
                parameters.isEnabled = true
                parameters.outputMode = .pcmOversampling
                try processor.performLivePCM2xTransition(tapRate: processor.currentTapSampleRate,
                    outputRate: processor.currentTapSampleRate * 2, parameters: parameters)
            }
        }
        @discardableResult func stop() -> Bool { processor.stop() }
        func submit(_ settings: SpatialSettings) -> UInt64 { processor.updateSpatial(settings) }
        func enqueueOldSpatial(_ settings: SpatialSettings, revision: UInt64) {
            processor.onManagerQueue { processor.controlQueue.pushSpatial(settings, revision: revision) }
        }
        func currentTapListener() -> AudioObjectPropertyListenerBlock? {
            processor.onManagerQueue { processor.tapFormatListener }
        }
        func deliver(_ listener: AudioObjectPropertyListenerBlock) {
            processor.onManagerQueue {
                var address = SystemAudioProcessor.tapFormatAddress()
                withUnsafePointer(to: &address) { listener(1, $0) }
            }
        }
        func captureGate() -> OpaquePointer? {
            processor.onManagerQueue { processor.captureCallbackLifetime?.handle }
        }
        func outputGate() -> OpaquePointer? {
            processor.onManagerQueue { processor.outputCallbackLifetime?.handle }
        }
        // The output consumer schedule is simulated, but this consumes the actual
        // output ring and C gain ramp under the real admission gate. The actual
        // AVAudioSourceNode closure is covered by the separate callback probe.
        func consumeOutput(_ frames: Int, advanceRamp: Bool = true) -> [Float] {
            processor.onManagerQueue {
                guard let lifetime = processor.outputCallbackLifetime,
                      lc_callback_gate_try_enter(lifetime.handle) != nil else { return [] }
                defer { lc_callback_gate_leave(lifetime.handle) }
                var samples = [Float](repeating: 0, count: frames * 2)
                samples.withUnsafeMutableBufferPointer { output in
                    processor.ringBuffer.popInterleaved(into: output.baseAddress!, count: output.count)
                    if advanceRamp {
                        lc_output_gain_ramp_apply_interleaved(processor.outputGainRamp,
                            output.baseAddress!, UInt32(frames), 2)
                    }
                }
                return samples
            }
        }
        func spatialState() -> Any { processor.onManagerQueue { processor.spatializer } }
        func state() -> AudioGraphCheckState {
            processor.onManagerQueue {
                AudioGraphCheckState(outputDevice: processor.currentOutputDeviceID,
                    started: processor.isStarted, outputRunning: processor.outputIsRunning,
                    tap: processor.tapID, aggregate: processor.aggregateDeviceID, hasIOProc: processor.ioProcID != nil,
                    hasOutputSource: processor.sourceNode != nil, tapRate: processor.currentTapSampleRate,
                    outputRate: processor.currentSampleRate, hardwareRate: processor.currentHardwareSampleRate,
                    live2x: processor.livePCM2xActive, restoreRate: processor.preLivePCM2xHardwareRate,
                    automaticRestoreRate: processor.originalRateMatchSampleRate,
                    phase: processor.rateMatchPhase.rawValue, status: processor.rateMatchStatus,
                    resets: processor.engineRestartCount, written: processor.ringBuffer.totalWrittenSamples(),
                    read: processor.ringBuffer.totalReadSamples(), gain: lc_output_gain_ramp_current(processor.outputGainRamp),
                    appliedRevision: processor.controlQueue.appliedSpatialRevision)
            }
        }
    }
}
