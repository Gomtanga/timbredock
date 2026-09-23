import AudioToolbox
import AudioRingBufferC
import CoreAudio
import Foundation

/// In-memory platform with real resource identities and operation-specific
/// failures. It does not implement a transition algorithm: SAP owns all order,
/// rollback, handle assignment, gate admission, DSP reset and route changes.
@available(macOS 14.4, *)
final class GraphCheckIO: AudioGraphIO, @unchecked Sendable {
    var monotonicTime: TimeInterval = 0
    var counts: [String: Int] = [:]
    var failures: [String: Set<Int>] = [:]
    var trace: [String] = []
    var taps: Set<AudioObjectID> = []
    var aggregates: Set<AudioObjectID> = []
    var listeners: Set<AudioObjectID> = []
    private let nominalLock = NSLock()
    private var nominalStorage: [AudioObjectID: Double] = [777: 48_000, 888: 44_100]
    var nominal: [AudioObjectID: Double] {
        get { nominalLock.lock(); defer { nominalLock.unlock() }; return nominalStorage }
        set { nominalLock.lock(); nominalStorage = newValue; nominalLock.unlock() }
    }
    var defaultOutputDeviceID: AudioObjectID = 777
    private func isOutputDevice(_ device: AudioObjectID) -> Bool { device == 777 || device == 888 }
    var forcedTapRate: Double?
    var rejectRates: Set<Double> = []
    var outputReadFailsAfterRejectedSet = false
    var invalidOutputReadAfterRejectedSet: Double?
    var confirmationDelay: TimeInterval = 0
    var pendingRate: (Double, TimeInterval)?
    var confirmationReadOrdinal: Int?
    private var pendingReadback: (rate: Double, remaining: Int)?
    var rateRequests: [Double] = []
    var onPause: (@Sendable () -> Void)?
    var outputIsRunning = false
    var captureRunning = false
    var registeredDevice: AudioObjectID?
    var callback: AudioDeviceIOProc?
    var clientData: UnsafeMutableRawPointer?
    var outputEpoch = 0
    var captureCalls = 0
    var captureFrames = 0
    var nextID: AudioObjectID = 1_000
    var onCall: ((String) -> Void)?

    func call(_ operation: String) -> OSStatus {
        onCall?(operation)
        counts[operation, default: 0] += 1
        let count = counts[operation]!
        let result: OSStatus = failures[operation]?.contains(count) == true ? -70_001 : noErr
        trace.append(String(format: "%.6f %@#%d=%d", monotonicTime, operation, count, result))
        return result
    }
    func require(_ operation: String) throws {
        let result = call(operation)
        if result != noErr { throw AppError.message("Injected \(operation) OSStatus=\(result)") }
    }
    func pause(_ seconds: TimeInterval) {
        monotonicTime += seconds
        onPause?()
    }
    func waitForRateEvent(_ semaphore: DispatchSemaphore, timeout: TimeInterval) {
        _ = call("waitRateEvent")
        // No pretend listener ACK. Advance the injected monotonic deadline and
        // let SAP's unchanged readback polling predicate decide confirmation.
        pause(timeout)
    }
    func nominalRate(_ device: AudioObjectID) throws -> Double {
        try require("readNominal")
        if isOutputDevice(device), let pendingReadback {
            if pendingReadback.remaining == 1 {
                nominal[device] = pendingReadback.rate
                self.pendingReadback = nil
            } else {
                self.pendingReadback = (pendingReadback.rate, pendingReadback.remaining - 1)
            }
        }
        if isOutputDevice(device), outputReadFailsAfterRejectedSet,
           let requested = rateRequests.last, rejectRates.contains(requested) {
            if let invalidOutputReadAfterRejectedSet { return invalidOutputReadAfterRejectedSet }
            trace.append("output-query-error after rejected set \(requested)")
            throw AppError.message("Injected output-only nominal read failure")
        }
        if isOutputDevice(device), let pendingRate, monotonicTime >= pendingRate.1 {
            nominal[device] = pendingRate.0
            self.pendingRate = nil
        }
        guard let result = nominal[device] else { throw AppError.message("Unknown virtual rate device \(device)") }
        return result
    }
    func setNominalRate(_ rate: Double, device: AudioObjectID) throws {
        try require(isOutputDevice(device) ? "setOutputRate" : "setAggregateRate")
        guard isOutputDevice(device) || aggregates.contains(device) else { throw AppError.message("Set on unknown device") }
        if isOutputDevice(device) {
            rateRequests.append(rate)
            if rejectRates.contains(rate) { return }
            if let confirmationReadOrdinal { pendingReadback = (rate, confirmationReadOrdinal) }
            else if confirmationDelay > 0 { pendingRate = (rate, monotonicTime + confirmationDelay) }
            else { nominal[device] = rate }
        } else { nominal[device] = rate }
    }
    func capabilities(_ device: AudioObjectID) throws -> HardwareSampleRateTracker.RateCapabilities {
        precondition(isOutputDevice(device))
        return .init(supportedRates: [44_100, 48_000, 88_200, 96_000, 192_000], isSettable: true)
    }
    func makeTapDescription() throws -> CATapDescription {
        try require("makeTapDescription")
        return CATapDescription(stereoMixdownOfProcesses: [])
    }
    func createTap(_ description: CATapDescription) -> (OSStatus, AudioObjectID) {
        let result = call("createTap")
        guard result == noErr else { return (result, kAudioObjectUnknown) }
        nextID += 1; taps.insert(nextID)
        return (result, nextID)
    }
    func tapRate(_ tap: AudioObjectID) throws -> Double {
        try require("readTap")
        guard taps.contains(tap) else { throw AppError.message("Read of destroyed tap") }
        return forcedTapRate ?? aggregates.first.flatMap { nominal[$0] } ?? nominal[defaultOutputDeviceID]!
    }
    func addTapListener(_ tap: AudioObjectID, queue: DispatchQueue,
                        listener: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        precondition(taps.contains(tap))
        let result = call("addTapListener")
        if result == noErr { listeners.insert(tap) }
        return result
    }
    func removeTapListener(_ tap: AudioObjectID, listener: AudioObjectPropertyListenerBlock) -> OSStatus {
        let result = call("removeTapListener")
        if result == noErr { listeners.remove(tap) }
        return result
    }
    func createAggregate(_ description: CFDictionary) -> (OSStatus, AudioObjectID) {
        precondition(!taps.isEmpty)
        let result = call("createAggregate")
        guard result == noErr else { return (result, kAudioObjectUnknown) }
        nextID += 1; aggregates.insert(nextID); nominal[nextID] = nominal[defaultOutputDeviceID]
        return (result, nextID)
    }
    func registerCapture(_ device: AudioObjectID, callback: @escaping AudioDeviceIOProc,
                         clientData: UnsafeMutableRawPointer) -> (OSStatus, AudioDeviceIOProcID?) {
        precondition(aggregates.contains(device) && registeredDevice == nil)
        let result = call("registerCapture")
        guard result == noErr else { return (result, nil) }
        registeredDevice = device; self.callback = callback; self.clientData = clientData
        return (result, callback)
    }
    func startCapture(_ device: AudioObjectID, ioProc: AudioDeviceIOProcID?) -> OSStatus {
        precondition(registeredDevice == device && ioProc != nil)
        let result = call("startCapture")
        if result == noErr { captureRunning = true }
        return result
    }
    func stopCapture(_ device: AudioObjectID, ioProc: AudioDeviceIOProcID) -> OSStatus {
        precondition(registeredDevice == device)
        let result = call("stopCapture")
        if result == noErr { captureRunning = false }
        return result
    }
    func unregisterCapture(_ device: AudioObjectID, ioProc: AudioDeviceIOProcID) -> OSStatus {
        precondition(registeredDevice == device)
        let result = call("unregisterCapture")
        if result == noErr {
            registeredDevice = nil; callback = nil; clientData = nil; captureRunning = false
        }
        return result
    }
    func destroyAggregate(_ device: AudioObjectID) -> OSStatus {
        precondition(registeredDevice != device)
        let result = call("destroyAggregate")
        if result == noErr { aggregates.remove(device); nominal.removeValue(forKey: device) }
        return result
    }
    func destroyTap(_ tap: AudioObjectID) -> OSStatus {
        precondition(!listeners.contains(tap) && aggregates.isEmpty)
        let result = call("destroyTap")
        if result == noErr { taps.remove(tap) }
        return result
    }
    func configureOutput(_ sampleRate: Double) throws {
        precondition(!outputIsRunning)
        try require("configureOutput")
        outputEpoch += 1
    }
    func startOutput() throws { try require("startOutput"); outputIsRunning = true }
    func stopOutput() {
        if call("stopOutput") == noErr { outputIsRunning = false }
    }

    // Invoke the C IOProc closure actually registered by SAP, with fully backed
    // Float input. This exercises gate -> handleInput -> DSP -> conditioning ->
    // ring. It is scheduled by a deterministic manager-side test clock.
    func capture(_ frames: Int, sample: Float = 0.125) {
        capture(interleaved: [Float](repeating: sample, count: frames * 2))
    }

    /// Deterministic non-constant input for end-to-end spectral/model checks.
    func capture(interleaved inputSamples: [Float]) {
        precondition(inputSamples.count % 2 == 0)
        guard captureRunning, let callback, let clientData, let device = registeredDevice else { return }
        let frames = inputSamples.count / 2
        var samples = inputSamples
        samples.withUnsafeMutableBufferPointer { data in
            var input = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(data.count * 4), mData: data.baseAddress!))
            var output = AudioBufferList()
            var timestamp = AudioTimeStamp()
            withUnsafePointer(to: &timestamp) { time in
                withUnsafePointer(to: &input) { input in
                    _ = callback(device, time, input, time, &output, time, clientData)
                }
            }
        }
        captureCalls += 1; captureFrames += frames
    }
}

@available(macOS 14.4, *)
enum AudioGraphChecks {
    private final class Fixture: @unchecked Sendable {
        let io = GraphCheckIO()
        let access: SystemAudioProcessor.GraphCheckAccess
        var suppressCaptureEpochs: Set<Int> = []
        var suppressOutputEpochs: Set<Int> = []
        var freezeFadeInEpochs: Set<Int> = []
        var freezeFadeOut = false
        init() throws {
            access = try SystemAudioProcessor.GraphCheckAccess(io: io)
            io.onPause = { [weak self] in self?.pump() }
            try access.seed()
        }
        func pump() {
            let state = access.state()
            let epoch = io.outputEpoch
            if !suppressCaptureEpochs.contains(epoch) { io.capture(256) }
            if io.outputIsRunning && !suppressOutputEpochs.contains(epoch) {
                let freeze = (state.phase == "fadingIn" && freezeFadeInEpochs.contains(epoch))
                    || (state.phase == "fadingOut" && freezeFadeOut)
                _ = access.consumeOutput(Int(256 * state.outputRate / max(state.tapRate, 1)), advanceRamp: !freeze)
            }
        }
        func close() throws {
            io.failures = [:]; io.rejectRates = []; io.forcedTapRate = nil
            io.onPause = nil
            guard access.stop(), io.taps.isEmpty, io.aggregates.isEmpty,
                  io.registeredDevice == nil, io.listeners.isEmpty, !io.outputIsRunning else {
                throw AppError.message("GraphChecks fixture did not release its resources")
            }
        }
    }

    @MainActor
    static func run() throws {
        var assertions = 0
        var cases = 0
        var trace: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            assertions += 1
            guard condition() else { throw AppError.message("AudioGraphChecks: \(label)") }
        }
        func record(_ name: String, _ fixture: Fixture) throws {
            let state = fixture.access.state()
            try fixture.close()
            cases += 1
            let summary = "GraphChecks \(name): PASS virtual=\(fixture.io.monotonicTime) observedTap=\(state.tapRate) observedOutput=\(state.outputRate) resets=\(state.resets) actualInputCalls=\(fixture.io.captureCalls) finalStop=true resources=0"
            print(summary)
            trace.append(summary); trace += fixture.io.trace
        }
        func expectFailure(_ operation: () throws -> Void) throws -> AudioGraphTransitionFailure {
            do { try operation() }
            catch let error as AudioGraphTransitionFailure { return error }
            throw AppError.message("AudioGraphChecks expected actual transition failure")
        }
        func assertActive(_ fixture: Fixture, rate: Double, ratio: Int) throws {
            let before = fixture.access.state()
            try expect(before.started && before.outputRunning && before.hasIOProc && before.hasOutputSource,
                       "installed actual SAP graph must be active")
            try expect(fixture.io.taps == [before.tap] && fixture.io.aggregates == [before.aggregate]
                       && fixture.io.registeredDevice == before.aggregate, "SAP/platform resource identity agrees")
            try expect(before.outputRate == rate && before.hardwareRate == rate
                       && before.outputRate / before.tapRate == Double(ratio), "route rates agree")
            try expect(fixture.io.nominal[777] == before.hardwareRate, "platform readback agrees with reported hardware rate")
            fixture.io.capture(257)
            let after = fixture.access.state()
            try expect(after.written - before.written == UInt64(257 * ratio * 2), "actual epoch produced/captured frame ratio")
            let output = fixture.access.consumeOutput(257 * ratio)
            try expect(output.count == 257 * ratio * 2 && output.allSatisfy(\.isFinite), "actual ring output is finite")
        }
        func assertPreview(_ model: SpatialControlModel, _ fixture: Fixture, revision: UInt64) throws {
            guard let preview = model.preview else { throw AppError.message("Missing actual UI preview") }
            let state = fixture.access.state()
            try expect(Double(preview.raw.sampleRate) == state.tapRate && state.appliedRevision == revision,
                       "actual UI preview uses applied revision's tap rate")
            // Read actual private DSP storage off-callback. No expected value is
            // recomputed through DSPPrecompute, and no RT observer is installed.
            let spatial = Mirror(reflecting: fixture.access.spatialState())
            guard let paths = spatial.children.first(where: { $0.label == "target" })?.value else {
                throw AppError.message("Spatializer target storage changed; update explicit fixture")
            }
            let target = Mirror(reflecting: paths)
            let expected = preview.raw.settings
            for (name, path) in [("ll", expected.ll), ("lr", expected.lr), ("rl", expected.rl), ("rr", expected.rr)] {
                guard let value = target.children.first(where: { $0.label == name })?.value else {
                    throw AppError.message("Missing actual Spatializer path \(name)")
                }
                let stored = Mirror(reflecting: value)
                let delay = stored.children.first(where: { $0.label == "delay" })?.value as? Int
                let gain = stored.children.first(where: { $0.label == "gain" })?.value as? Float
                try expect(delay == Int(path.delaySamples) && gain == path.gain,
                           "actual applied \(name) delay/gain equals actual UI preview")
            }
            let amount = spatial.children.first(where: { $0.label == "targetAmount" })?.value as? Float
            try expect(amount == expected.amount, "actual applied amount equals preview")
        }

        // A cached pre-transition rate cannot confirm rollback if the setter is
        // a no-op and every new output query fails. This exercises the actual
        // live installer failure before it assigns currentHardwareSampleRate.
        for invalidRead in ["query-error", "NaN", "infinity"] {
            let f = try Fixture(); defer { try? f.close() }
            f.io.failures["createTap"] = [2]
            f.io.rejectRates = [48_000]
            f.io.outputReadFailsAfterRejectedSet = true
            if invalidRead == "NaN" { f.io.invalidOutputReadAfterRejectedSet = .nan }
            if invalidRead == "infinity" { f.io.invalidOutputReadAfterRejectedSet = .infinity }
            let failure = try expectFailure { try f.access.transitionToLive2x() }
            let state = f.access.state()
            print("GraphChecks cached-readback canary: recovered=\(failure.recovered) reported=\(state.hardwareRate) platform=\(f.io.nominal[777]!) started=\(state.started) restore=\(String(describing: state.restoreRate))")
            try expect(!failure.recovered && !state.started && !state.outputRunning,
                       "cached previous rate must not certify rollback after failed fresh queries")
            try expect(state.restoreRate == 48_000 && f.io.nominal[777] == 96_000,
                       "unconfirmed restoration target remains retained")
            try expect(String(describing: failure.recoveryFailure).contains("no finite readback"),
                       "invalid or missing readback is explicitly unknown")
            try record("cached-readback-rejected-\(invalidRead)", f)
        }

        // Actual route/conditioning installers: unity -> 2x -> unity, then a
        // normal rate change and an independent tap event at constant output.
        do {
            let f = try Fixture(); defer { try? f.close() }
            try assertActive(f, rate: 48_000, ratio: 1)
            f.access.live2x(true)
            try expect(f.access.state().live2x && f.access.state().restoreRate == 48_000, "actual 2x mode and restore snapshot")
            try assertActive(f, rate: 96_000, ratio: 2)
            f.access.live2x(false)
            try expect(!f.access.state().live2x && f.access.state().restoreRate == nil, "actual 2x disable consumes confirmed restore")
            try assertActive(f, rate: 48_000, ratio: 1)
            try f.access.transition(96_000)
            try assertActive(f, rate: 96_000, ratio: 1)
            let oldListener = f.access.currentTapListener()!
            f.io.forcedTapRate = 48_000
            f.access.deliver(oldListener)
            let stopped = f.access.state()
            try expect(!stopped.started && !stopped.outputRunning && !stopped.hasIOProc,
                       "independent mismatched tap event cannot run unity at 2:1")
            try expect(f.io.taps.isEmpty && f.io.aggregates.isEmpty, "tap-event failure cleans partially installed capture")
            let reads = f.io.counts["readTap"]!
            f.access.deliver(oldListener)
            try expect(f.io.counts["readTap"] == reads, "retired actual listener never reads or reinstalls")
            try record("unity-2x-disable-rate-tap-mismatch-late-event", f)
        }

        do {
            let f = try Fixture(); defer { try? f.close() }
            let domain = "lowend.graph-checks.\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: domain)!
            defer { preferences.removePersistentDomain(forName: domain) }
            let model = SpatialControlModel(preferences: preferences)
            var revision: UInt64 = 0
            model.onChange = { revision = f.access.submit($0) }
            var obsolete = SpatialSettings()
            obsolete.enabled = true; obsolete.listenerX = -2; obsolete.amount = 99
            f.access.enqueueOldSpatial(obsolete, revision: 0)
            f.suppressCaptureEpochs = [1] // Keep the old-rate packet queued until actual quiescence/drain.
            model.mutate(final: true) {
                $0.enabled = true; $0.listenerX = 1.375; $0.listenerZ = -0.7
                $0.speakerWidth = 1.8; $0.amount = 72
            }
            try f.access.transition(44_100)
            // The UI notification bridge is outside this offline check. Feed
            // the actual installed tap rate to the actual UI model explicitly.
            model.processingSampleRate = Float(f.access.state().tapRate)
            try assertActive(f, rate: 44_100, ratio: 1)
            try assertPreview(model, f, revision: revision)
            f.access.live2x(true)
            try assertActive(f, rate: 88_200, ratio: 2)
            try assertPreview(model, f, revision: revision)
            model.mutate(final: true) { $0.listenerX = -1.625; $0.amount = 63 }
            // Wait only for the actual manager's existing 60 Hz timer; the C
            // input callback then drains the real packet. No substitute push.
            let deadline = DispatchTime.now().uptimeNanoseconds + 300_000_000
            repeat {
                Thread.sleep(forTimeInterval: 0.005)
                f.io.capture(512)
                _ = f.access.consumeOutput(1024)
            } while f.access.state().appliedRevision != revision && DispatchTime.now().uptimeNanoseconds < deadline
            try assertPreview(model, f, revision: revision)
            try record("actual-UI-preview-rebuild-and-queued-apply", f)
        }

        // OS operation failures run through the real target installer and its
        // cleanup; rollback rebuilds the original 48 kHz graph.
        for operation in ["setOutputRate", "createTap", "createAggregate", "configureOutput", "startOutput", "registerCapture", "startCapture"] {
            let f = try Fixture(); defer { try? f.close() }
            let firstTargetCall = (f.io.counts[operation] ?? 0) + 1
            f.io.failures[operation] = [firstTargetCall]
            let failure = try expectFailure { try f.access.transition(96_000) }
            try expect(failure.recovered, "\(operation) rollback recovers")
            try assertActive(f, rate: 48_000, ratio: 1)
            try expect(f.access.state().gain >= 0.99, "\(operation) rollback actual fade-in completes")
            try record("target-\(operation)-rollback", f)
        }

        // Confirmation has a real set attempt and executes the actual SAP
        // polling loop. A no-op setter must fail; a delayed readback may pass.
        do {
            let f = try Fixture(); defer { try? f.close() }
            f.io.rejectRates = [96_000]
            let failure = try expectFailure { try f.access.transition(96_000) }
            try expect(failure.recovered && String(describing: failure.cause).contains("did not confirm"), "no-op rate setter cannot certify success")
            try expect((f.io.counts["readNominal"] ?? 0) >= 31 && f.io.monotonicTime >= 0.96, "actual confirmation timeout polls")
            try assertActive(f, rate: 48_000, ratio: 1)
            try record("confirmation-no-readback-timeout", f)
        }
        do {
            let f = try Fixture(); defer { try? f.close() }
            f.io.confirmationDelay = 0.906
            try f.access.transition(96_000)
            try expect(f.io.pendingRate == nil && (f.io.counts["waitRateEvent"] ?? 0) == 1, "late readback confirms after event wait")
            try assertActive(f, rate: 96_000, ratio: 1)
            try record("confirmation-delayed-poll", f)
        }
        // The post-event initial read is ordinal 1. SAP then makes 30 more
        // reads: ordinal 31 is the last result inside this confirmation window.
        for ordinal in [30, 31, 32] {
            let f = try Fixture(); defer { try? f.close() }
            f.io.confirmationReadOrdinal = ordinal
            if ordinal <= 31 {
                do { try f.access.transition(96_000) }
                catch {
                    print("GraphChecks final-poll canary: readOrdinal=\(ordinal) unexpected=\(error)")
                    throw error
                }
                try assertActive(f, rate: 96_000, ratio: 1)
                try expect(f.io.counts["waitRateEvent"] == 1 && f.io.rateRequests == [96_000],
                           "a target confirmed by read \(ordinal) must not trigger rollback")
            } else {
                let failure = try expectFailure { try f.access.transition(96_000) }
                try expect(String(describing: failure.cause).contains("did not confirm 96.0 kHz"),
                           "read outside the final poll cannot certify the target transition")
                try expect(!f.access.state().started && !f.access.state().outputRunning,
                           "unconfirmed target and rollback remain stopped")
            }
            try record("confirmation-read-ordinal-\(ordinal)", f)
        }

        for phase in ["captureFlow", "outputFlow", "fadeIn", "fadeOut"] {
            let f = try Fixture(); defer { try? f.close() }
            if phase == "captureFlow" { f.suppressCaptureEpochs = [2] }
            if phase == "outputFlow" { f.suppressOutputEpochs = [2] }
            if phase == "fadeIn" { f.freezeFadeInEpochs = [2] }
            if phase == "fadeOut" { f.freezeFadeOut = true }
            let failure = try expectFailure { try f.access.transition(96_000) }
            try expect(failure.recovered, "\(phase) late failure rollback recovers")
            let cause = String(describing: failure.cause)
            try expect(cause.contains(L10n.string(phase.contains("Flow") ? "runtime.transition.flowTimeout" : phase == "fadeIn" ? "runtime.transition.fadeInTimeout" : "runtime.transition.fadeOutTimeout")), "actual \(phase) timeout predicate")
            try assertActive(f, rate: 48_000, ratio: 1)
            // Two 0.9 s confirmation waits plus the actual failed phase and
            // successful rollback fades fit below this complete-transaction cap.
            try expect(f.io.monotonicTime < 3.5, "virtual transition deadline remains bounded")
            try record("actual-\(phase)-timeout", f)
        }

        // Fully installed target, then actual flow or fade timeout followed by
        // rollback failure. Quiescence must leave no running graph.
        for rollbackFailure in ["createAggregate", "captureFlow", "fadeIn"] {
            let f = try Fixture(); defer { try? f.close() }
            f.suppressCaptureEpochs = [2]
            if rollbackFailure == "createAggregate" { f.io.failures["createAggregate"] = [3] }
            if rollbackFailure == "captureFlow" { f.suppressCaptureEpochs.insert(3) }
            if rollbackFailure == "fadeIn" { f.freezeFadeInEpochs = [3] }
            let failure = try expectFailure { try f.access.transition(96_000) }
            let state = f.access.state()
            try expect(!failure.recovered && !state.started && !state.outputRunning, "failed rollback leaves actual SAP stopped")
            try expect(!state.hasIOProc && state.tap == kAudioObjectUnknown && state.aggregate == kAudioObjectUnknown,
                       "failed rollback releases all removable capture resources")
            try record("late-flow-rollback-\(rollbackFailure)-failure", f)
        }

        // Failed teardown preserves the exact production handle. No reset or
        // replacement installer may run until a subsequent explicit Stop retry.
        for operation in ["stopOutput", "unregisterCapture", "destroyAggregate", "removeTapListener", "destroyTap"] {
            let f = try Fixture(); defer { try? f.close() }
            let before = f.access.state()
            f.io.failures[operation] = [(f.io.counts[operation] ?? 0) + 1]
            let failure = try expectFailure { try f.access.transition(96_000) }
            let after = f.access.state()
            try expect(!failure.recovered && !after.started && after.resets == before.resets, "\(operation) barrier prevents reset")
            try expect(f.io.counts["createTap"] == 1 && after.tap == before.tap, "\(operation) preserves actual tap and forbids reinstall")
            if operation == "unregisterCapture" {
                try expect(after.hasIOProc && after.aggregate == before.aggregate && f.io.registeredDevice == before.aggregate,
                           "failed IOProc removal preserves real stored registration")
            }
            if operation == "destroyAggregate" { try expect(after.aggregate == before.aggregate, "failed aggregate removal preserves stored handle") }
            try record("teardown-\(operation)-preservation", f)
        }
        do {
            let f = try Fixture(); defer { try? f.close() }
            f.suppressCaptureEpochs = [2]
            f.io.failures["unregisterCapture"] = [2]
            let failure = try expectFailure { try f.access.transition(96_000) }
            let state = f.access.state()
            try expect(!failure.recovered && !state.started && state.hasIOProc, "late target flow failure preserves failed teardown handle")
            try expect(f.io.counts["createTap"] == 2 && f.io.registeredDevice == state.aggregate,
                       "late teardown barrier forbids rollback installer")
            try record("late-flow-teardown-failure", f)
        }
        for duringRollback in [false, true] {
            let f = try Fixture(); defer { try? f.close() }
            let installation = duringRollback ? 3 : 2
            if duringRollback { f.suppressCaptureEpochs = [2] }
            f.io.failures["startCapture"] = [installation]
            f.io.failures["unregisterCapture"] = [installation]
            let failure = try expectFailure { try f.access.transition(96_000) }
            let state = f.access.state()
            print("GraphChecks nested-cleanup canary: recovered=\(failure.recovered) createTap=\(f.io.counts["createTap"]!) hasIOProc=\(state.hasIOProc) resets=\(state.resets)")
            try expect(!failure.recovered && !state.started && state.hasIOProc && state.resets == UInt64(installation - 1),
                       "failed target-installer cleanup is an unrecoverable barrier for this transaction")
            try expect(f.io.counts["createTap"] == installation && f.io.counts["unregisterCapture"] == installation,
                       "outer transaction must not implicitly retry nested teardown or reinstall")
            try record("\(duringRollback ? "rollback" : "target")-install-nested-teardown-barrier", f)
        }
        var automaticBarrierFailures: [String] = []
        for nested in [false, true] {
            let f = try Fixture(); defer { try? f.close() }
            if nested { f.io.failures["startCapture"] = [2] }
            f.io.failures["unregisterCapture"] = [nested ? 2 : 1]
            let failure = try expectFailure { try f.access.automaticTransition(96_000) }
            let state = f.access.state()
            let expectedInstallations = nested ? 2 : 1
            print("GraphChecks automatic-barrier canary: nested=\(nested) recovered=\(failure.recovered) started=\(state.started) createTap=\(f.io.counts["createTap"]!) restore=\(String(describing: state.automaticRestoreRate)) resets=\(state.resets)")
            let checks = [!failure.recovered, !state.started, state.hasIOProc,
                          state.automaticRestoreRate == 48_000,
                          state.resets == UInt64(expectedInstallations - 1),
                          f.io.counts["createTap"] == expectedInstallations,
                          f.io.counts["unregisterCapture"] == expectedInstallations]
            assertions += checks.count
            if checks.allSatisfy({ $0 }) {
                try record("automatic-\(nested ? "nested-cleanup" : "initial-teardown")-barrier", f)
            } else {
                automaticBarrierFailures.append(nested ? "nested-cleanup" : "initial-teardown")
                try f.close()
            }
        }
        try expect(automaticBarrierFailures.isEmpty,
                   "automatic wrapper must preserve failed barriers: \(automaticBarrierFailures)")
        do {
            let f = try Fixture(); defer { try? f.close() }
            try f.access.automaticTransition(96_000)
            try expect(f.access.state().automaticRestoreRate == 48_000, "automatic source change retains original rate")
            f.io.failures["createTap"] = [3]
            let failure = try expectFailure { try f.access.automaticTransition(44_100) }
            try expect(failure.recovered && f.access.state().automaticRestoreRate == nil,
                       "successfully recovered target failure still restores original automatic rate")
            try expect(f.io.rateRequests == [96_000, 44_100, 96_000, 48_000],
                       "normal automatic failure preserves immediate rollback then original-rate policy")
            try assertActive(f, rate: 48_000, ratio: 1)
            try record("automatic-recovered-failure-original-rate", f)
        }
        do {
            let f = try Fixture(); defer { try? f.close() }
            let before = f.access.state()
            let gate = f.access.captureGate()!
            try expect(lc_callback_gate_try_enter(gate) != nil, "hold actual capture admission")
            let failure = try expectFailure { try f.access.transition(96_000) }
            lc_callback_gate_leave(gate)
            let after = f.access.state()
            try expect(!failure.recovered && after.resets == before.resets && after.tap == before.tap && after.hasIOProc,
                       "actual in-flight timeout preserves handles and forbids reset")
            try expect(f.io.counts["createTap"] == 1 && lc_callback_gate_try_enter(gate) == nil,
                       "disabled actual gate rejects late input and no reinstall follows")
            try record("actual-admitted-capture-quiescence-timeout", f)
        }

        if let path = ProcessInfo.processInfo.environment["LOWEND_GRAPH_TRACE"] {
            try (trace.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        print("AudioGraphChecks: \(cases) integrated cases, \(assertions) assertions; actual SAP transition/installers/IOProc input/gates/rings/conditioning; named external IO and output schedule simulated; no start(), HardwareTracker or CoreAudio device calls")
    }
}
