import Foundation
import LowEndSupport

struct SpatialSettings: Sendable {
    var enabled: Bool = false
    var listenerX: Float = 0.0
    var listenerZ: Float = 0.0
    var speakerWidth: Float = 1.65
    var amount: Float = 35.0
}

enum DSPModelID {
    static let clean: UInt32 = 0
    static let circuit: UInt32 = 1
    static let highExciter: UInt32 = 2
}

struct Settings {
    var mode: Mode = .all
    var intensity: Float = 55.0
    var body: Float = 30.0
    var outputDb: Float = -1.5
    var dspModel: DSPModel = .circuit
    var exciterOversamplingMode: ExciterOversamplingMode = .auto
    var automaticRateMatchingEnabled = false
    var spatial: SpatialSettings = SpatialSettings()

    func normalized() -> Settings {
        var result = self
        func finiteClamp(_ value: Float, _ lower: Float, _ upper: Float, _ fallback: Float) -> Float {
            value.isFinite ? min(max(value, lower), upper) : fallback
        }
        result.intensity = finiteClamp(intensity, 0, 100, 55)
        result.body = finiteClamp(body, 0, 100, 30)
        result.outputDb = finiteClamp(outputDb, -18, 6, -1.5)
        result.spatial.listenerX = finiteClamp(spatial.listenerX, -3, 3, 0)
        result.spatial.listenerZ = finiteClamp(spatial.listenerZ, -2.8, 2.8, 0)
        result.spatial.speakerWidth = finiteClamp(spatial.speakerWidth, 0.6, 3, 1.65)
        result.spatial.amount = finiteClamp(spatial.amount, 0, 100, 35)
        return result
    }

    enum Mode {
        case all
        case bundleIDs([String])
        case listApps
        case selfTest
    }

    enum DSPModel: String {
        case clean
        case circuit
        case highExciter = "highexciter"

        var controlID: UInt32 {
            switch self {
            case .clean: return DSPModelID.clean
            case .circuit: return DSPModelID.circuit
            case .highExciter: return DSPModelID.highExciter
            }
        }

        var displayName: String {
            switch self {
            case .clean: return L10n.string("runtime.model.clean")
            case .circuit: return L10n.string("runtime.model.circuit")
            case .highExciter: return L10n.string("runtime.model.exciter")
            }
        }

        static func fromArgument(_ value: String) -> DSPModel? {
            let normalized = value
                .lowercased()
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: " ", with: "")
            switch normalized {
            case "clean": return .clean
            case "circuit": return .circuit
            case "highexciter", "exciter": return .highExciter
            default: return nil
            }
        }
    }
}
