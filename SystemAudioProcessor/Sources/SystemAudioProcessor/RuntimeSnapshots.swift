import Foundation

/// A short value copy, never used by an audio callback. The manager must publish
/// after doing slow device work, rather than holding this lock during that work.
final class RuntimeSnapshotBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func load() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ next: Value) { lock.lock(); value = next; lock.unlock() }
}

struct ManagerDisplayState {
    var deviceID: UInt32 = 0
    var outputSampleRate: Double = 48_000
    var tapSampleRate: Double = 48_000
    var restartCount: UInt64 = 0
    var captureTarget = L10n.string("runtime.target.system")
    var audioFlowGeneration: UInt64 = 0
    var ringWrittenAtCaptureStart: UInt64 = 0
    var ringReadAtCaptureStart: UInt64 = 0
}

final class HardwareObservationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func invalidate() { lock.lock(); active = false; lock.unlock() }
}

/// Manager delivery re-reads current state. A rate captured on the listener
/// queue may already have been rolled back by the time management is available.
enum HardwareObservationDelivery {
    static func deliver(deviceID: UInt32, token: HardwareObservationToken,
                        currentDevice: () -> UInt32?, currentRate: () -> Double?,
                        onChange: (UInt32, Double) -> Void) {
        guard token.isValid, currentDevice() == deviceID,
              let actual = currentRate(), actual.isFinite else { return }
        onChange(deviceID, actual)
    }
}

/// Many UI edits occupy one slot while the manager is busy negotiating a DAC.
/// The UI returns immediately; the manager checks the slot at 60 Hz.
final class SpatialSubmissionBox: @unchecked Sendable {
    struct Submission {
        var settings: SpatialSettings
        var revision: UInt64
    }
    private let lock = NSLock()
    private var latest: Submission
    init(_ settings: SpatialSettings) { latest = Submission(settings: settings, revision: 0) }
    @discardableResult
    func submit(_ settings: SpatialSettings) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        latest.revision &+= 1
        latest.settings = settings
        return latest.revision
    }
    func load() -> Submission { lock.lock(); defer { lock.unlock() }; return latest }
}
