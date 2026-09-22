import AudioRingBufferC
import Foundation

/// The C gate owns an explicit retain until all admitted callbacks have left.
/// A failed IOProc removal leaves a disabled C tombstone, never a dangling
/// clientData address. Only manager code calls the methods below; callbacks use
/// the C entry/leave functions directly.
final class AudioCallbackLifetime: @unchecked Sendable {
    let handle: OpaquePointer
    private var retainedOwner: UnsafeMutableRawPointer?
    private var disabled = false
    private var quiescenceConfirmed = false
    private var sourceRemoved = false

    init(retaining owner: AnyObject) throws {
        let retained = Unmanaged.passRetained(owner).toOpaque()
        guard let gate = lc_callback_gate_create(retained) else {
            Unmanaged<AnyObject>.fromOpaque(retained).release()
            throw AppError.message("Could not allocate a lock-free audio callback gate.")
        }
        handle = gate
        retainedOwner = retained
    }

    func disable() {
        lc_callback_gate_disable(handle)
        disabled = true
    }

    /// Disabling prevents later entries from touching userdata. A zero count
    /// then proves that every callback which could use the owner has returned.
    func waitForQuiescence(timeout: TimeInterval = 0.5) throws {
        precondition(disabled)
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(timeout, 0) * 1_000_000_000)
        while lc_callback_gate_in_flight(handle) != 0 {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                throw AppError.message(L10n.string("runtime.callback.timeout"))
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        quiescenceConfirmed = true
    }

    /// Release on a later manager turn, never inside stop()/deinit or a callback.
    /// If quiescence times out this is not called, preserving the owner's entire
    /// graph even if the UI releases its last reference.
    func releaseOwnerAfterQuiescence(on queue: DispatchQueue) {
        precondition(disabled && quiescenceConfirmed)
        guard let retainedOwner else { return }
        self.retainedOwner = nil
        let address = UInt(bitPattern: retainedOwner)
        queue.async { Unmanaged<AnyObject>.fromOpaque(UnsafeMutableRawPointer(bitPattern: address)!).release() }
    }

    /// Call only after IOProc removal succeeded, or after the output source was
    /// detached. Output closures retain this object until their final release.
    func markSourceRemoved() { sourceRemoved = true }

    deinit {
        // With a live retain the owner normally also owns this lifetime, so an
        // admitted callback cannot cause owner deinit. Conservatively leak a
        // tombstone if removal or quiescence was not established.
        if sourceRemoved && disabled && retainedOwner == nil && lc_callback_gate_in_flight(handle) == 0 {
            lc_callback_gate_destroy(handle)
        }
    }
}

struct AudioTeardownFailure: Error, CustomStringConvertible {
    let operation: String
    let status: Int32
    var description: String { L10n.format("runtime.callback.failure", operation, status) }
}

/// Production Core Audio calls and failure-injection checks use this adapter.
/// Handles are cleared only by the success closure, never on an error status.
enum AudioTeardownAdapter {
    @discardableResult
    static func unregisterIOProc(stop: () -> Int32, destroy: () -> Int32,
                                 didUnregister: () -> Void) throws -> Int32 {
        let stopStatus = stop()
        let destroyStatus = destroy()
        guard destroyStatus == 0 else {
            throw AudioTeardownFailure(operation: "AudioDeviceDestroyIOProcID (stop=\(stopStatus))", status: destroyStatus)
        }
        // Successful removal is a stronger guarantee than a successful Stop.
        // Return a Stop error for explicit diagnostics even if removal succeeded.
        didUnregister()
        return stopStatus
    }

    static func destroy(_ operation: String, call: () -> Int32,
                        didDestroy: () -> Void) throws {
        let result = call()
        guard result == 0 else { throw AudioTeardownFailure(operation: operation, status: result) }
        didDestroy()
    }
}

enum AudioLifecyclePolicy {
    /// Manager-side entry gate shared by live settings. A stopped processor may
    /// retain failed restoration state; editing settings must not retry it or
    /// start a graph. Only an explicit Stop retry consumes that state.
    @discardableResult
    static func withRunningProcessor(isStarted: Bool, _ operation: () -> Void) -> Bool {
        guard isStarted else { return false }
        operation()
        return true
    }

    static func validateUnityRoute(captureRate: Double, outputRate: Double) throws {
        guard captureRate.isFinite, outputRate.isFinite, abs(captureRate - outputRate) < 1 else {
            throw AppError.message(L10n.string("runtime.format.mismatch"))
        }
    }

    static func needsStop(hasResources: Bool, automaticRestoreRate: Double?, liveRestoreRate: Double?) -> Bool {
        hasResources || automaticRestoreRate != nil || liveRestoreRate != nil
    }

    static func restoreRate(_ requested: Double, apply: () throws -> Double, didRestore: () -> Void) throws {
        let confirmed = try apply()
        guard confirmed.isFinite, abs(confirmed - requested) < 1 else {
            throw AppError.message(L10n.string("runtime.format.restoreUnconfirmed"))
        }
        didRestore()
    }
}
