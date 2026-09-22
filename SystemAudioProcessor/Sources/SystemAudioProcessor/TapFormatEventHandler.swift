import Foundation

/// Manager-only event dispatch shared by the actual Tap listener and offline
/// action-injection checks. It does not claim to simulate Core Audio itself.
enum TapFormatEventHandler {
    struct State {
        var previousSampleRate: Double
        var isStarted: Bool
        var isAutomaticTransition: Bool
        var isLivePCM2x: Bool
    }
    enum Outcome: Equatable {
        case ignoredRegistration, displayOnly, rebuilt, requestedLivePCM2xDeactivation, failed
    }
    enum FailurePhase: Equatable { case read, reconfigure }
    struct InvalidSampleRate: Error, CustomStringConvertible {
        let rate: Double
        var description: String { L10n.format("runtime.format.range", rate) }
    }
    struct Operations {
        var isCurrentRegistration: () -> Bool
        var readCurrentSampleRate: () throws -> Double
        var acceptSampleRate: (Double) -> Void
        var rebuildNormalGraph: () throws -> Void
        var deactivateLivePCM2x: () throws -> Void
        var reportFailure: (Error, FailurePhase) -> Void
        var publishState: () -> Void
    }

    @discardableResult
    static func handle(state: State, operations: Operations) -> Outcome {
        guard operations.isCurrentRegistration() else { return .ignoredRegistration }
        let rate: Double
        do {
            rate = try operations.readCurrentSampleRate()
            guard rate.isFinite, (8_000...768_000).contains(rate) else { throw InvalidSampleRate(rate: rate) }
        } catch {
            guard operations.isCurrentRegistration() else { return .ignoredRegistration }
            operations.reportFailure(error, .read)
            operations.publishState()
            return .failed
        }
        // A read must not deliver a rate for a registration retired meanwhile.
        guard operations.isCurrentRegistration() else { return .ignoredRegistration }
        operations.acceptSampleRate(rate)
        guard state.isStarted, !state.isAutomaticTransition,
              abs(state.previousSampleRate - rate) > 0.5 else {
            operations.publishState()
            return .displayOnly
        }
        do {
            if state.isLivePCM2x {
                try operations.deactivateLivePCM2x()
                operations.publishState()
                return .requestedLivePCM2xDeactivation
            }
            try operations.rebuildNormalGraph()
            operations.publishState()
            return .rebuilt
        } catch {
            // A rebuild may legitimately replace its own registration before
            // failing. Its failure must still be reported after retirement.
            operations.reportFailure(error, .reconfigure)
            operations.publishState()
            return .failed
        }
    }
}
