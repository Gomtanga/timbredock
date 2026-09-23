import Foundation

/// Read the tap's own membership, never infer capture from all running apps.
/// A process can disappear between the membership and identity reads; fail the
/// observation instead of presenting a partial list as the complete target.
enum CaptureTargetSummary {
    struct Identity {
        let pid: Int32
        let bundleID: String
    }

    static func read(processes: () throws -> [UInt32],
                     identity: (UInt32) throws -> Identity) throws -> String {
        let ids = try Set(processes()).sorted()
        guard !ids.isEmpty else { return L10n.string("runtime.capture.noProcesses") }
        return try ids.map { id in
            let process = try identity(id)
            guard id != 0, process.pid > 0, !process.bundleID.isEmpty else {
                throw AppError.message(L10n.string("runtime.capture.invalid"))
            }
            return "\(process.bundleID) (pid \(process.pid))"
        }.joined(separator: ", ")
    }
}

/// Counts actual PCM since this capture graph was installed. Underrun padding
/// is excluded by the ring's read counter, while legitimate silent PCM counts.
struct AudioFlowProgress: Sendable, Equatable {
    var generation: UInt64 = 0
    var producedSamples: UInt64 = 0
    var consumedSamples: UInt64 = 0

    var isConfirmed: Bool { generation > 0 && producedSamples > 0 && consumedSamples > 0 }
    var displayText: String {
        if isConfirmed { return L10n.string("runtime.flow.confirmed") }
        if producedSamples > 0 { return L10n.string("runtime.flow.waitingOutput") }
        return L10n.string("runtime.flow.waitingAudio")
    }
    static let waitingHelp = L10n.string("runtime.flow.help")
}

struct AudioDiagnosticsSnapshot: Sendable {
    let outputUnderrunSamples: UInt64
    let outputDroppedSamples: UInt64
    let visualizerDroppedSamples: UInt64
    let engineRestartCount: UInt64
    let captureTarget: String
    let audioFlow: AudioFlowProgress

    var displayText: String {
        "XRuns out \(outputUnderrunSamples) / drop \(outputDroppedSamples) / analysis \(visualizerDroppedSamples) | restart \(engineRestartCount) | \(captureTarget)"
    }
}
