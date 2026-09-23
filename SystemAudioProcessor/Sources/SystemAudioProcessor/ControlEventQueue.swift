import AudioRingBufferC
import Foundation
import LowEndSupport

struct ToneControlReceipt {
    let model: Settings.DSPModel
    let intensity: Double
    let body: Double
}

final class LockFreeControlEventQueue {
    private let handle: OpaquePointer
    private var sampleRate: Float
    private var pendingDSP: LCControlEvent?
    private var pendingSpatial: LCControlEvent?
    private var pendingConditioning: LCControlEvent?
    static let callbackDrainBudget = 8

    init(capacity: Int = 16, sampleRate: Float) throws {
        guard let handle = lc_control_event_queue_create(UInt32(max(capacity, 16))) else {
            throw AppError.message("Could not allocate audio control event queue.")
        }
        self.handle = handle
        self.sampleRate = sampleRate
    }

    deinit {
        lc_control_event_queue_destroy(handle)
    }

    func updateSampleRate(_ sampleRate: Float) {
        // Both audio callbacks must be quiescent. Stored events were precomputed
        // at the old rate and must not overwrite the rebuild's latest snapshot.
        drain()
        self.sampleRate = sampleRate
        pendingDSP = nil; pendingSpatial = nil; pendingConditioning = nil
        acknowledgeDSP(0)
    }

    func pushDSP(intensity: Float,
                 body: Float,
                 outputDb: Float,
                 dspModel: Settings.DSPModel,
                 exciterOversamplingMode: ExciterOversamplingMode) {
        var event = LCControlEvent()
        event.type = UInt32(LC_CONTROL_EVENT_DSP)
        event.dsp = DSPPrecompute.makeDSPSettings(
            sampleRate: sampleRate,
            intensity: intensity,
            body: body,
            outputDb: outputDb,
            dspModel: dspModel,
            exciterOversamplingMode: exciterOversamplingMode
        )
        // DSP events use their otherwise-unused revision word as a diagnostic
        // payload. Quantize on the manager, never inside the callback.
        event.revision = Self.receiptWord(for: event.dsp)
        pendingDSP = event
        flushPending()
    }

    func pushSpatial(_ settings: SpatialSettings, revision: UInt64 = 0) {
        var event = LCControlEvent()
        event.type = UInt32(LC_CONTROL_EVENT_SPATIAL)
        event.revision = revision
        event.spatial = DSPPrecompute.makeSpatialSettings(sampleRate: sampleRate, settings: settings)
        pendingSpatial = event
        flushPending()
    }

    func pushConditioning(_ parameters: OutputConditioningParameters) {
        var event = LCControlEvent()
        event.type = UInt32(LC_CONTROL_EVENT_OUTPUT_CONDITIONING)
        event.conditioning = LCOutputConditioningSettings(
            enabled: parameters.isEnabled ? 1 : 0,
            outputMode: parameters.outputMode.rawValue,
            oversamplingFactor: UInt32(parameters.oversamplingFactor),
            filterMode: parameters.filterMode.rawValue,
            headroomGain: parameters.headroomGain,
            ditherEnabled: parameters.ditherEnabled ? 1 : 0,
            noiseShapingEnabled: parameters.noiseShapingEnabled ? 1 : 0,
            dsdMode: parameters.dsdMode.rawValue
        )
        pendingConditioning = event
        flushPending()
    }

    /// Manager-only. A failed push retains the newest value for the next tick.
    func flushPending() {
        if var event = pendingDSP, withUnsafePointer(to: &event, { lc_control_event_queue_push(handle, $0) }) != 0 { pendingDSP = nil }
        if var event = pendingSpatial, withUnsafePointer(to: &event, { lc_control_event_queue_push(handle, $0) }) != 0 { pendingSpatial = nil }
        if var event = pendingConditioning, withUnsafePointer(to: &event, { lc_control_event_queue_push(handle, $0) }) != 0 { pendingConditioning = nil }
    }

    static func receiptWord(for settings: LCDSPSettings) -> UInt64 {
        func quantize(_ value: Float) -> UInt64 {
            value.isFinite ? UInt64((min(max(Double(value), 0), 1) * 10_000).rounded()) : 0
        }
        return (UInt64(1) << 63) | (UInt64(settings.dspModel) << 32)
            | (quantize(settings.intensity) << 16) | quantize(settings.body)
    }

    func acknowledgeDSP(_ receipt: UInt64) { lc_control_event_queue_publish_dsp_receipt(handle, receipt) }
    var receivedTone: ToneControlReceipt? {
        let word = lc_control_event_queue_dsp_receipt(handle)
        guard word >> 63 == 1 else { return nil }
        let modelID = (word >> 32) & 0xff
        guard modelID <= 2 else { return nil }
        return ToneControlReceipt(model: modelID == 0 ? .clean : modelID == 1 ? .circuit : .highExciter,
            intensity: Double((word >> 16) & 0xffff) / 100,
            body: Double(word & 0xffff) / 100)
    }

    func acknowledgeSpatial(_ revision: UInt64) { lc_control_event_queue_acknowledge(handle, revision) }
    var appliedSpatialRevision: UInt64 { lc_control_event_queue_applied_revision(handle) }

    func pop(into event: UnsafeMutablePointer<LCControlEvent>) -> Bool {
        lc_control_event_queue_pop(handle, event) != 0
    }

    func drain() {
        var event = LCControlEvent()
        while pop(into: &event) {}
    }
}
