import Foundation

enum AppLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case korean = "ko"

    var nativeName: String { self == .english ? "English" : "한국어" }
    static let preferenceKey = "appLanguage"
    // A language change is saved for the next launch; it never restarts audio.
    static let current = fromStoredValue(UserDefaults.standard.string(forKey: preferenceKey))

    static func fromStoredValue(_ value: String?) -> AppLanguage {
        value.flatMap(AppLanguage.init(rawValue:)) ?? .english
    }
}

enum L10n {
    private static let tables = ["Main", "Spatial", "Runtime", "Localizable"]
    private static let resourceBundles: [Bundle] = {
        let name = "SystemAudioProcessor_SystemAudioProcessor.bundle"
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL.deletingLastPathComponent()
        let urls = [
            Bundle.main.url(forResource: "SystemAudioProcessor_SystemAudioProcessor", withExtension: "bundle"),
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            executableDirectory.appendingPathComponent(name)
        ].compactMap { $0 }
        return urls.compactMap(Bundle.init(url:)) + [Bundle.main]
    }()

    static func string(_ key: String, language: AppLanguage = .current) -> String {
        for locale in language == .english ? ["en"] : ["ko", "en"] {
            for bundle in resourceBundles {
                guard let url = bundle.url(forResource: locale, withExtension: "lproj"),
                      let localized = Bundle(url: url) else { continue }
                for table in tables {
                    let value = localized.localizedString(forKey: key, value: key, table: table)
                    if value != key { return value }
                }
            }
        }
        // Remain usable when running an unbundled diagnostic executable.
        if key == "analysis.unavailable" {
            return language == .korean ? "스펙트럼을 표시할 수 없습니다. 오디오 처리는 계속 사용할 수 있습니다."
                : "The spectrum is unavailable. Audio processing remains available."
        }
        return key
    }

    static func format(_ key: String, _ arguments: CVarArg..., language: AppLanguage = .current) -> String {
        String(format: string(key, language: language), locale: Locale(identifier: language.rawValue), arguments: arguments)
    }

    static func runOfflineChecks() throws {
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "TimbreDockLocalization", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try require(AppLanguage.fromStoredValue(nil) == .english, "English must be the first-launch default")
        try require(AppLanguage.fromStoredValue("invalid") == .english, "Invalid locale must fall back to English")
        try require(AppLanguage.fromStoredValue("ko") == .korean, "Korean preference must be preserved")
        try require(string("analysis.unavailable", language: .english).contains("spectrum"), "English resource/fallback missing")
        try require(string("analysis.unavailable", language: .korean).contains("스펙트럼"), "Korean resource/fallback missing")
        for language in AppLanguage.allCases {
            for key in ["main.page.sound", "spatial.page.title", "runtime.model.circuit", "runtime.target.system"] {
                try require(string(key, language: language) != key,
                            "Missing bundled \(language.rawValue) resource: \(key)")
            }
        }
        for (key, english, korean) in [
            ("main.page.sound", "Sound", "사운드"),
            ("spatial.page.title", "Spatial Audio", "공간 음향"),
            ("runtime.target.system", "System Audio", "전체 시스템")
        ] {
            try require(string(key, language: .english) == english, "English table failed: \(key)")
            try require(string(key, language: .korean) == korean, "Korean table failed: \(key)")
        }
        let suite = "TimbreDockLanguageCheck.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        defer { store.removePersistentDomain(forName: suite) }
        for language in AppLanguage.allCases {
            store.set(language.rawValue, forKey: AppLanguage.preferenceKey)
            try require(store.synchronize(), "Language preference could not be persisted")
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            child.arguments = ["read", suite, AppLanguage.preferenceKey]
            let output = Pipe(); child.standardOutput = output
            try child.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
            let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try require(child.terminationStatus == 0 && raw == language.rawValue,
                        "A separate process did not read the saved language")
        }
        try require(string("main.sound.treble.drive", language: .korean) == "배음 강도", "Korean sound controls must be translated")
        print("LocalizationChecks: defaults, bundled en/ko tables and separate-process preference reads passed")
    }
}
