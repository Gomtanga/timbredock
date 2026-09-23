import Foundation

// Deterministic, narrowly-scoped UserDefaults migration for the TimbreDock
// redesign preferences. Only the keys below are written; tonal/spatial and other
// user numeric values are never erased, and re-running migrate is idempotent.
// `outputMigrationNoticePending` is set true here and cleared only by the UI.
struct RedesignPreferences {
    struct Migration {
        let model: Settings.DSPModel
        let outputMode: OutputRateMode
        let filter: ResamplingFilterMode
        let gainDB: Double
        let noticeRequired: Bool
    }

    enum Keys {
        static let selectedModelID = "selectedModelID", legacyModel = "selectedModel"
        static let outputRateMode = "outputRateMode", noticePending = "outputMigrationNoticePending"
        static let enabled = "outputConditioningEnabled", mode = "outputConditioningMode"
        static let factor = "outputConditioningFactor", filter = "outputConditioningFilter"
        static let headroom = "outputConditioningHeadroomDB"
        static let auto = "automaticRateMatchingEnabled"
        static let dither = "outputConditioningDither", noise = "outputConditioningNoiseShape"
        static let dsd = "outputConditioningDSD"
    }

    static let defaultGainDB = -3.0
    static let gainDBRange: ClosedRange<Double> = -12...0

    static func migrate(_ store: UserDefaults) -> Migration {
        let model = migrateModel(store)
        let (filter, filterNotice) = resolveFilter(store)
        let (mode, modeNotice) = resolveOutputMode(store)
        persistRateKeys(store, mode: mode)
        let gain = normalizedGain(store.object(forKey: Keys.headroom) as? Double)
        store.set(gain, forKey: Keys.headroom)
        if filterNotice || modeNotice { store.set(true, forKey: Keys.noticePending) }
        return Migration(
            model: model,
            outputMode: mode,
            filter: filter,
            gainDB: gain,
            noticeRequired: store.bool(forKey: Keys.noticePending)
        )
    }
    /// A valid `selectedModelID` raw string wins; otherwise the legacy
    /// `selectedModel` index (0 clean / 1 circuit / 2 high exciter, anything
    /// else circuit) migrates; a fresh install keeps the circuit default.
    private static func migrateModel(_ store: UserDefaults) -> Settings.DSPModel {
        let model: Settings.DSPModel
        if let raw = store.string(forKey: Keys.selectedModelID), let valid = Settings.DSPModel(rawValue: raw) {
            model = valid
        } else {
            let index = store.object(forKey: Keys.legacyModel) as? Int ?? 1
            model = index == 0 ? .clean : (index == 2 ? .highExciter : .circuit)
        }
        store.set(model.rawValue, forKey: Keys.selectedModelID)
        return model
    }
    /// Legacy minimum phase stored the same effective algorithm as Short, so it
    /// normalizes to Short and raises the one-time notice.
    private static func resolveFilter(_ store: UserDefaults) -> (ResamplingFilterMode, Bool) {
        let stored = store.object(forKey: Keys.filter) as? Int
        let filter: ResamplingFilterMode = stored == 1 ? .linearPhaseLong : .linearPhaseShort
        store.set(Int(filter.rawValue), forKey: Keys.filter)
        return (filter, stored == 2)
    }
    /// A valid new `outputRateMode` string wins. Otherwise legacy state decides:
    /// unsupported mode/factor or dither/noise-shape/DSD -> Standard + notice
    /// (never MatchSource); else enabled PCM 2x, else automatic -> MatchSource.
    private static func resolveOutputMode(_ store: UserDefaults) -> (OutputRateMode, Bool) {
        if let raw = store.string(forKey: Keys.outputRateMode) {
            return OutputRateMode(rawValue: raw).map { ($0, false) } ?? (.standard, true)
        }
        let bypass = Int(OutputConditioningMode.bypass.rawValue)
        let pcm2x = Int(OutputConditioningMode.pcmOversampling.rawValue)
        let enabled = store.bool(forKey: Keys.enabled)
        let mode = store.object(forKey: Keys.mode) as? Int ?? bypass
        let factor = store.object(forKey: Keys.factor) as? Int ?? 2
        let dsd = store.object(forKey: Keys.dsd) as? Int ?? Int(DSDMode.off.rawValue)
        let unsupported = (mode != bypass && mode != pcm2x)
            || factor != 2
            || store.bool(forKey: Keys.dither)
            || store.bool(forKey: Keys.noise)
            || dsd != Int(DSDMode.off.rawValue)
        if unsupported { return (.standard, true) }
        if enabled && mode == pcm2x { return (.upsample2x, false) }
        if store.bool(forKey: Keys.auto) { return (.matchSource, false) }
        return (.standard, false)
    }
    /// Normalizes the legacy keys to the resolved mode: enabled/PCM 1/factor 2
    /// only for 2x, the automatic flag only for MatchSource, otherwise disabled
    /// and bypass. Unsupported hidden options are normalized to their safe defaults.
    private static func persistRateKeys(_ store: UserDefaults, mode: OutputRateMode) {
        let is2x = mode == .upsample2x
        let factor = 2
        store.set(false, forKey: Keys.dither)
        store.set(false, forKey: Keys.noise)
        store.set(Int(DSDMode.off.rawValue), forKey: Keys.dsd)
        store.set(is2x, forKey: Keys.enabled)
        store.set(is2x ? Int(OutputConditioningMode.pcmOversampling.rawValue)
                       : Int(OutputConditioningMode.bypass.rawValue), forKey: Keys.mode)
        store.set(factor, forKey: Keys.factor)
        store.set(mode == .matchSource, forKey: Keys.auto)
        store.set(mode.rawValue, forKey: Keys.outputRateMode)
    }
    /// Absent or non-finite -> the default; finite -> clamped to
    /// `gainDBRange`; valid in-range numbers pass through untouched.
    static func normalizedGain(_ stored: Double?) -> Double {
        guard let value = stored, value.isFinite else { return defaultGainDB }
        return min(max(value, gainDBRange.lowerBound), gainDBRange.upperBound)
    }

    struct CheckError: Error, CustomStringConvertible {
        let label: String
        var description: String { "RedesignPreferences offline check failed: \(label)" }
    }

    /// Network-free, UI-free checks against an isolated UserDefaults suite removed on exit.
    static func runOfflineChecks() throws {
        let suite = "RedesignPreferencesChecks." + UUID().uuidString
        guard let store = UserDefaults(suiteName: suite) else { throw CheckError(label: "no suite") }
        defer { store.removePersistentDomain(forName: suite) }
        func reset() { store.removePersistentDomain(forName: suite) }
        func expect(_ condition: Bool, _ label: String) throws { if !condition { throw CheckError(label: label) } }
        func write(_ value: Any, _ key: String) { store.set(value, forKey: key) }
        func legacy(enabled: Bool, mode: Int = 0, factor: Int? = nil, filter: Int? = nil) {
            write(enabled, Keys.enabled)
            write(mode, Keys.mode)
            if let factor { write(factor, Keys.factor) }
            if let filter { write(filter, Keys.filter) }
        }

        // 1. Fresh install: defaults, no notice.
        reset()
        var result = migrate(store)
        try expect(result.model == .circuit && result.outputMode == .standard
            && result.filter == .linearPhaseShort && result.gainDB == defaultGainDB
            && !result.noticeRequired, "fresh install defaults")
        try expect(store.string(forKey: Keys.outputRateMode) == "standard", "fresh install persisted mode")

        // 2. Legacy model mapping and canonical raw string.
        for (index, model) in [(0, Settings.DSPModel.clean), (1, .circuit), (2, .highExciter)] {
            reset()
            write(index, Keys.legacyModel)
            try expect(migrate(store).model == model, "legacy model \(index)")
        }
        reset()
        write(2, Keys.legacyModel)
        _ = migrate(store)
        try expect(store.string(forKey: Keys.selectedModelID) == "highexciter", "canonical model raw string")

        // 3. Enabled PCM 2x beats a simultaneous automatic flag and normalizes.
        reset()
        legacy(enabled: true, mode: 1, factor: 2)
        write(true, Keys.auto)
        result = migrate(store)
        try expect(result.outputMode == .upsample2x && !result.noticeRequired, "2x precedence over auto")
        try expect(store.integer(forKey: Keys.mode) == 1 && store.integer(forKey: Keys.factor) == 2
            && store.bool(forKey: Keys.enabled) && !store.bool(forKey: Keys.auto), "2x normalized legacy keys")

        // 4. Subsequent launch: the valid new mode wins; repeat is idempotent.
        write(true, Keys.auto)
        result = migrate(store)
        let again = migrate(store)
        try expect(result.outputMode == .upsample2x && !result.noticeRequired, "subsequent launch mode")
        try expect(!store.bool(forKey: Keys.auto), "subsequent launch recalibrates auto")
        try expect(again.model == result.model && again.outputMode == result.outputMode
            && again.filter == result.filter && again.gainDB == result.gainDB
            && again.noticeRequired == result.noticeRequired, "idempotent repeat")

        // 5. Invalid new mode string -> Standard + notice.
        reset()
        write("bogus", Keys.outputRateMode)
        write(true, Keys.auto)
        result = migrate(store)
        try expect(result.outputMode == .standard && result.noticeRequired, "invalid new mode string")
        try expect(store.string(forKey: Keys.outputRateMode) == "standard", "invalid new mode normalized")

        // 6. Unsupported legacy state -> Standard + notice, never MatchSource.
        reset()
        legacy(enabled: true, mode: 1, factor: 4)
        write(true, Keys.auto)
        result = migrate(store)
        try expect(result.outputMode == .standard && result.noticeRequired && !store.bool(forKey: Keys.auto),
                   "unsupported factor")
        reset()
        legacy(enabled: true, mode: 3)
        write(128, Keys.dsd)
        result = migrate(store)
        try expect(result.outputMode == .standard && result.noticeRequired, "unsupported DSD")
        reset()
        write(true, Keys.dither)
        write(true, Keys.noise)
        result = migrate(store)
        try expect(result.outputMode == .standard && result.noticeRequired, "dither/noise shape")

        // 7. Legacy minimum phase -> Short + notice; PCM 2x still resolves.
        reset()
        write(2, Keys.filter)
        result = migrate(store)
        try expect(result.filter == .linearPhaseShort && result.noticeRequired, "minimum phase notice")
        try expect(store.integer(forKey: Keys.filter) == 0, "minimum phase normalized")
        reset()
        legacy(enabled: true, mode: 1, factor: 2, filter: 2)
        result = migrate(store)
        try expect(result.outputMode == .upsample2x && result.noticeRequired, "minimum phase alongside 2x")

        // 8. Automatic flag alone -> MatchSource, quiet.
        reset()
        write(true, Keys.auto)
        result = migrate(store)
        try expect(result.outputMode == .matchSource && !result.noticeRequired, "auto flag alone")
        try expect(store.string(forKey: Keys.outputRateMode) == "matchSource", "auto flag persisted")

        // 9. Gain normalization, and the stored number is left untouched.
        try expect(normalizedGain(nil) == defaultGainDB, "gain absent")
        try expect(normalizedGain(-20) == -12 && normalizedGain(3) == 0, "gain clamped")
        try expect(normalizedGain(-12) == -12 && normalizedGain(0) == 0 && normalizedGain(-6.5) == -6.5,
                   "gain bounds and valid value")
        for bad in [Double.nan, .infinity, -.infinity] {
            let value = normalizedGain(bad)
            try expect(value == defaultGainDB && value.isFinite, "gain non-finite")
        }
        reset()
        write(-20.0, Keys.headroom)
        try expect(migrate(store).gainDB == -12, "gain store clamped")
        try expect(store.double(forKey: Keys.headroom) == -12, "gain store normalized")
        reset()
        try expect(migrate(store).gainDB == defaultGainDB, "gain store absent")

        // 10. Tone and spatial numeric sentinels survive untouched.
        reset()
        write(55.5, "intensity")
        write(-1.25, "outputDb")
        write(35.0, "spatialAmount")
        write(1234.5, "toneSentinel")
        legacy(enabled: true, mode: 1, factor: 2)
        _ = migrate(store)
        try expect((store.object(forKey: "intensity") as? Double) == 55.5
            && (store.object(forKey: "outputDb") as? Double) == -1.25
            && (store.object(forKey: "spatialAmount") as? Double) == 35.0
            && (store.object(forKey: "toneSentinel") as? Double) == 1234.5, "numeric sentinels preserved")

        // 11. Notice lifecycle: raised once, kept until the UI clears it.
        reset()
        write(2, Keys.filter)
        result = migrate(store)
        try expect(result.noticeRequired && store.bool(forKey: Keys.noticePending), "notice raised")
        try expect(migrate(store).noticeRequired, "notice survives helper rerun")
        write(false, Keys.noticePending)
        try expect(!migrate(store).noticeRequired, "acknowledged notice not re-raised")
    }
}
