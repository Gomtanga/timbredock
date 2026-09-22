import AppKit
import Accelerate
import AudioToolbox
import AVFoundation
import AudioRingBufferC
import Combine
import CoreAudio
import Darwin
import Foundation
import LowEndSupport
import Metal
import MetalKit
import SceneKit
import SwiftUI

fileprivate extension Array {
    /// Bounds-checked subscript used by the output-conditioning pickers.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Read-only app discovery for the header target picker. It lists regular
/// running applications and their icons on demand; it never queries CoreAudio,
/// opens a tap or changes an audio setting.
struct DiscoveredAudioApp: Equatable {
    let name: String
    let bundleID: String
    let pid: pid_t
}

enum AudioProcessDiscovery {
    static func runningApps() -> [DiscoveredAudioApp] {
        NSWorkspace.shared.runningApplications
            .compactMap { app -> DiscoveredAudioApp? in
                guard app.activationPolicy != .prohibited,
                      let bundleID = app.bundleIdentifier else { return nil }
                return DiscoveredAudioApp(
                    name: app.localizedName ?? bundleID,
                    bundleID: bundleID,
                    pid: app.processIdentifier
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?.icon
    }
}

/// The draft capture target shown in the header. Selecting a target never
/// retargets audio on its own; only Apply turns the draft into a live request.
enum CaptureTarget: Equatable {
    case system
    case app(bundleID: String, name: String?)

    var bundleID: String? {
        if case .app(let bundleID, _) = self { return bundleID }
        return nil
    }

    /// Persisted form: an empty string means system audio.
    var persistedValue: String { bundleID ?? "" }

    func displayName() -> String {
        switch self {
        case .system:
            return L10n.string("main.header.target.system")
        case .app(let bundleID, let name):
            return L10n.format("main.header.target.app", name ?? bundleID)
        }
    }

    static func fromPersisted(_ value: String?, name: String?) -> CaptureTarget {
        guard let value, !value.isEmpty else { return .system }
        return .app(bundleID: value, name: name)
    }
}

/// The single mutually exclusive output rate mode exposed by the Output page.
enum OutputRateMode: String, CaseIterable {
    case standard
    case upsample2x
    case matchSource

    var title: String {
        switch self {
        case .standard: return L10n.string("main.output.mode.standard")
        case .upsample2x: return L10n.string("main.output.mode.upsample2x")
        case .matchSource: return L10n.string("main.output.mode.matchSource")
        }
    }

    var detail: String {
        switch self {
        case .standard: return L10n.string("main.output.mode.standard.detail")
        case .upsample2x: return L10n.string("main.output.mode.upsample2x.detail")
        case .matchSource: return L10n.string("main.output.mode.matchSource.detail")
        }
    }
}

enum AppError: Error, CustomStringConvertible {
    case message(String)
    case osStatus(String, OSStatus)

    var description: String {
        switch self {
        case .message(let value):
            return value
        case .osStatus(let label, let status):
            return "\(label) failed: \(status) \(fourCC(status))"
        }
    }
}

enum RateMatchPhase: String, Sendable {
    case idle
    case fadingOut
    case stopping
    case changingDeviceRate
    case rebuilding
    case waitingForCapture
    case fadingIn
    case running
    case rollback
    case aborted
}


private struct DynamicsMeterView: View {
    @ObservedObject var model: DynamicsMeterModel

    var body: some View {
        VStack(spacing: 4) {
            horizontalLevelBar(title: "Peak", db: model.levels.peak, color: Color.secondary, showValue: false)
            horizontalLevelBar(title: "RMS", db: model.levels.rms, color: Color.secondary, showValue: false)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: GlassDesign.surface))
    }

    private func horizontalLevelBar(title: String, db: Float, color: Color, showValue: Bool) -> some View {
        let normalized = max(0, min(1, Double((db + 60) / 60)))
        return HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: showValue ? 42 : 28, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(2, proxy.size.width * normalized))
                }
            }
            .frame(height: showValue ? 14 : 6)
            if showValue {
                Text(formatDbText(db))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 72, alignment: .trailing)
            }
        }
    }

}

@available(macOS 14.4, *)
private struct MonitorAxisView: View {
    let sampleRate: Double?

    private static let axisMinHz: Double = 20
    private static let axisMaxHz: Double = 20_000
    private static let fftSize: Double = 16_384
    private static let ticks: [Double] = [20, 100, 1_000, 10_000, 20_000]

    private var nyquist: Double? {
        guard let sampleRate, sampleRate >= 8_000 else { return nil }
        return sampleRate / 2
    }

    private func position(_ hertz: Double) -> Double {
        let upper = min(Self.axisMaxHz, nyquist ?? Self.axisMaxHz)
        let clamped = min(max(hertz, Self.axisMinHz), upper)
        return log(clamped / Self.axisMinHz) / log(upper / Self.axisMinHz)
    }

    private func tickLabel(_ hertz: Double) -> String {
        hertz >= 1_000
            ? String(format: "%.0fk", hertz / 1_000)
            : String(format: "%.0f", hertz)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            ZStack(alignment: .topLeading) {
                if let nyquist {
                    let lowEdge = sampleRate.map { $0 / Self.fftSize } ?? Self.axisMinHz
                    if lowEdge > Self.axisMinHz {
                        shading(left: 0, width: width * position(lowEdge), height: height)
                    }
                    let highestBin = nyquist * (1 - 2 / Self.fftSize)
                    if highestBin < Self.axisMaxHz {
                        let start = width * position(highestBin)
                        shading(left: start, width: max(width - start, 0), height: height)
                    }
                }
                ForEach(Self.ticks, id: \.self) { tick in
                    if tick <= (nyquist ?? Self.axisMaxHz) || tick < 1_000 {
                        let x = width * position(tick)
                        Rectangle()
                            .fill(Color(white: 0.7))
                            .frame(width: 1, height: 6)
                            .offset(x: max(min(x, width - 1), 0), y: 0)
                        Text(tickLabel(tick))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.7))
                            .fixedSize()
                            .offset(x: min(max(x - 12, 0), max(width - 26, 0)), y: 8)
                    }
                }
                ForEach([250.0, 4_000.0], id: \.self) { boundary in
                    let x = width * position(boundary)
                    Rectangle()
                        .fill(Color(white: 0.7))
                        .frame(width: 1, height: height)
                        .offset(x: min(max(x, 0), width - 1))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func shading(left: CGFloat, width: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.42))
            .frame(width: width, height: height)
            .offset(x: left)
    }
}

/// Signal Monitor page: dynamics from the shared analysis model plus the
/// frequency display with our own logarithmic axis overlay.
@available(macOS 14.4, *)
private struct MonitorPageView: View {
    @ObservedObject var dynamicsModel: DynamicsMeterModel
    let spectrumModel: SpectrumModel
    let isActive: Bool
    private var sampleRate: Double? { dynamicsModel.sampleRate > 0 ? Double(dynamicsModel.sampleRate) : nil }

    private var stateText: String {
        switch dynamicsModel.state {
        case .stopped: return L10n.string("main.monitor.state.stopped")
        case .measuring: return L10n.string("main.monitor.state.measuring")
        case .active: return L10n.string("main.monitor.state.active")
        case .silence: return L10n.string("main.monitor.state.silence")
        case .waiting: return L10n.string("main.monitor.state.waiting")
        case .interrupted: return L10n.string("main.monitor.state.interrupted")
        }
    }

    private var numbersAvailable: Bool {
        switch dynamicsModel.state {
        case .active, .silence: return true
        default: return false
        }
    }

    private var crestAvailable: Bool {
        numbersAvailable && dynamicsModel.levels.crestAvailable && dynamicsModel.state == .active
    }

    private func dbText(_ value: Float) -> String {
        numbersAvailable ? (value <= -100 ? "< −100" : String(format: "%.1f", Double(value))) : L10n.string("main.monitor.unavailable")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L10n.string("main.monitor.title"))
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                ContextualHelp(text: L10n.string("main.monitor.point") + "\n\n" + L10n.string("main.monitor.frequency.note") + "\n\n" + L10n.string("main.monitor.frequency.bands"), title: L10n.string("main.monitor.title"))
                    .frame(width: 28, height: 28)
                Text(stateText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: GlassDesign.surface))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 6)
            }

            HStack(alignment: .top, spacing: 10) {
                Text(L10n.string("main.monitor.dynamics"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                Spacer()
                if numbersAvailable && dynamicsModel.levels.peak >= 0 {
                    Text(L10n.string("main.monitor.sampleFullScale"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .help(L10n.string("main.monitor.sampleFullScale.help"))
                }
            }

            HStack(spacing: 10) {
                metricCard(title: L10n.string("main.monitor.peak"),
                           value: dbText(dynamicsModel.levels.peak),
                           detail: numbersAvailable ? "dBFS" : nil,
                           accent: Color.primary)
                metricCard(title: L10n.string("main.monitor.rms"),
                           value: dbText(dynamicsModel.levels.rms),
                           detail: numbersAvailable ? "dBFS" : nil,
                           accent: Color.primary)
                metricCard(title: L10n.string("main.monitor.crest"),
                           value: crestAvailable
                                ? String(format: "%.1f", Double(dynamicsModel.levels.crestFactor))
                                : L10n.string("main.monitor.unavailable"),
                           detail: crestAvailable ? "dB" : nil,
                           accent: Color.primary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("main.monitor.frequency"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                ZStack(alignment: .topLeading) {
                    MetalSpectrumView(model: spectrumModel, isActive: isActive)
                    MonitorAxisView(sampleRate: sampleRate)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxHeight: .infinity)


        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: GlassDesign.surface))
    }

    private func metricCard(title: String, value: String, detail: String?, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.secondary)
            Text(value)
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: GlassDesign.well))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private func fourCC(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let chars = [
        Character(UnicodeScalar((value >> 24) & 255) ?? " "),
        Character(UnicodeScalar((value >> 16) & 255) ?? " "),
        Character(UnicodeScalar((value >> 8) & 255) ?? " "),
        Character(UnicodeScalar(value & 255) ?? " ")
    ]
    let text = String(chars)
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "'\(text)'"
}

func check(_ status: OSStatus, _ label: String) throws {
    guard status == noErr else { throw AppError.osStatus(label, status) }
}

func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}

/// Format a dB value to one decimal place, collapsing negative zero so that a
/// value which rounds to zero renders as "0.0 dB" instead of "-0.0 dB". This
/// matters for sliders that span 0 (e.g. Output -18…+6, headroom -12…0): a
/// reading like -0.04 would otherwise print "-0.0 dB" alongside "0.0 dB".
/// Display-only — the gain path (pow(10, db/20)) is unaffected.
private func formatDbText(_ db: Double) -> String {
    let tenths = (db * 10).rounded(.toNearestOrAwayFromZero)
    let normalized = tenths == 0 ? 0.0 : tenths / 10
    return String(format: "%.1f dB", normalized)
}

private func formatDbText(_ db: Float) -> String {
    formatDbText(Double(db))
}

private func parseArguments() throws -> Settings {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let diagnostics = ["--list-apps", "--self-test", "--ui-self-test", "--benchmark-output-conditioning"]
    guard arguments.count == 1 || !arguments.contains(where: diagnostics.contains) else {
        throw AppError.message("Diagnostic commands must be used on their own.")
    }
    var settings = Settings()
    var bundleIDs: [String] = []
    var captureAll = false
    var iterator = arguments.makeIterator()

    while let arg = iterator.next() {
        switch arg {
        case "--all":
            captureAll = true
            settings.mode = .all
        case "--bundle-id":
            guard let value = iterator.next(), !value.isEmpty else {
                throw AppError.message("--bundle-id needs a value")
            }
            bundleIDs.append(value)
        case "--intensity":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--intensity needs a number")
            }
            settings.intensity = number
        case "--body":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--body needs a number")
            }
            settings.body = number
        case "--output":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--output needs a number")
            }
            settings.outputDb = number
        case "--model":
            guard let value = iterator.next(), let model = Settings.DSPModel.fromArgument(value) else {
                throw AppError.message("--model needs clean, circuit, or highexciter")
            }
            settings.dspModel = model
        case "--exciter-os":
            guard let value = iterator.next() else {
                throw AppError.message("--exciter-os needs auto, 1x, 2x, or 4x")
            }
            switch value.lowercased() {
            case "auto": settings.exciterOversamplingMode = .auto
            case "1", "1x": settings.exciterOversamplingMode = .one
            case "2", "2x": settings.exciterOversamplingMode = .two
            case "4", "4x": settings.exciterOversamplingMode = .four
            default:
                throw AppError.message("--exciter-os needs auto, 1x, 2x, or 4x")
            }
        case "--spatial":
            guard let value = iterator.next() else {
                throw AppError.message("--spatial needs on or off")
            }
            switch value.lowercased() {
            case "on", "true", "1", "yes": settings.spatial.enabled = true
            case "off", "false", "0", "no": settings.spatial.enabled = false
            default: throw AppError.message("--spatial needs on or off")
            }
        case "--listener-x":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--listener-x needs a number")
            }
            settings.spatial.listenerX = number
        case "--listener-z":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--listener-z needs a number")
            }
            settings.spatial.listenerZ = number
        case "--stage-width":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--stage-width needs a number")
            }
            settings.spatial.speakerWidth = number
        case "--space":
            guard let value = iterator.next(), let number = Float(value), number.isFinite else {
                throw AppError.message("--space needs a number")
            }
            settings.spatial.amount = number
        case "--list-apps":
            settings.mode = .listApps
        case "--self-test":
            settings.mode = .selfTest
        case "--help", "-h":
            printUsageAndExit()
        default:
            throw AppError.message("Unknown argument: \(arg)")
        }
    }

    if !bundleIDs.isEmpty {
        guard !captureAll else { throw AppError.message("Choose --all or --bundle-id, not both.") }
        settings.mode = .bundleIDs(bundleIDs)
    }

    return settings.normalized()
}

@available(macOS 14.4, *)
@MainActor
private final class NativeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private enum AppPage: Int, CaseIterable {
        case sound
        case spatial
        case monitor
        case output
        case settings

        var title: String {
            switch self {
            case .sound: return L10n.string("main.page.sound")
            case .spatial: return L10n.string("main.page.spatial")
            case .monitor: return L10n.string("main.page.monitor")
            case .output: return L10n.string("main.page.output")
            case .settings: return L10n.string("main.page.settings")
            }
        }

        var symbolName: String {
            switch self {
            case .sound: return "slider.horizontal.3"
            case .spatial: return "move.3d"
            case .monitor: return "waveform.path.ecg"
            case .output: return "speaker.wave.2.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    private var headerView: NSView!
    private var sessionView: NSView!
    private var modelScroll: NSScrollView!
    private var modelDocument: TopAlignedDocument!
    private var pageHostView: NSView!
    private var headerTargetCaption: NSTextField!
    private var headerTargetPopup: NSPopUpButton!
    private var headerChooseButton: NSButton!
    private var headerClearButton: NSButton!
    private var headerApplyButton: NSButton!
    private var headerStopButton: NSButton!
    private var headerActiveTargetLabel: NSTextField!
    private var headerOutputLabel: NSTextField!
    private var headerTargetEntryBundleIDs: [String?] = []
    private var headerTargetEntryNames: [String] = []
    private var headerTargetEntryIsSeparator: [Bool] = []
    private var draftTarget: CaptureTarget = .system
    private var activeTarget: CaptureTarget?
    private var pendingTarget: CaptureTarget?
    private var initialModel: Settings.DSPModel = .circuit
    private var outputRateMode: OutputRateMode = .standard
    private var outputDocument: NSView!
    private var outputScroll: NSScrollView!
    private enum OutputPageTag: Int { case page = 9100, title, subtitle, modeCaption, filterCaption, filterDetail, gainNote }
    private var outputRateModePopup: NSPopUpButton!
    private var outputModeDetailLabel: NSTextField!
    private var outputMigrationNoticeLabel: NSTextField!
    private var outputMigrationDismissButton: NSButton!
    private var languagePopup: NSPopUpButton!
    private var languageStatusLabel: NSTextField!
    private var toneReceiptLabel: NSTextField!
    private var settingsScroll: NSScrollView!
    private var settingsDocument: TopAlignedDocument!
    private var advancedSettingsView: TopAlignedDocument!

    private var window: NSWindow!
    private var rootView: NSView!
    private var sidebarView: NSView!
    private var pageContainerView: NSView!
    private var analysisContainerView: NSView!
    private var formatHeaderView: NSView!
    private var analysisRailView: NSHostingView<AnyView>!
    private var pageViews: [AppPage: NSView] = [:]
    private var sidebarButtons: [NSButton] = []
    private var selectedPage: AppPage = .sound
    private var allSystemButton: NSButton!
    private var modelExplanationView: NSView!
    private var modelControlsView: NSView!
    private var modelPresetsView: NSView!
    private var routingAppsScrollView: NSScrollView!
    private var routingStartAppButton: NSButton!
    private var statusLabel: NSTextField!
    private var sourceFormatLabel: NSTextField!
    private var formatLabel: NSTextField!
    private var oversamplingLabel: NSTextField!
    private var rateMatchPreviewLabel: NSTextField!
    private var compactSourceTitleLabel: NSTextField!
    private var compactSourceValueLabel: NSTextField!
    private var compactOutputLabel: NSTextField!
    private var compactModelLabel: NSTextField!
    private var diagnosticsLabel: NSTextField!
    private var automaticRateMatchButton: NSButton!
    private var expertModeButton: NSButton!
    private var bundleField: NSTextField!
    private var appsView: NSTextView!
    private var intensitySlider: NSSlider!
    private var bodySlider: NSSlider!
    private var outputSlider: NSSlider!
    private var intensityNameLabel: NSTextField!
    private var bodyNameLabel: NSTextField!
    private var outputNameLabel: NSTextField!
    private var intensityValueLabel: NSTextField!
    private var bodyValueLabel: NSTextField!
    private var outputValueLabel: NSTextField!
    private var modelSelector: NSSegmentedControl!
    private var preferenceStore: UserDefaults = .standard
    private var oversamplingModeLabel: NSTextField!
    private var oversamplingModeControl: NSSegmentedControl!
    private var presetButtons: [NSButton] = []
    private var processor: SystemAudioProcessor?
    private enum AudioOperationPhase { case replacing, creating, starting, stopping }
    private struct PendingAudioOperation {
        let id = UUID()
        var phase: AudioOperationPhase
        var stopRequested = false
        var quitRequested = false
    }
    // Main owns the token and processor. The serial worker retains each
    // blocking call until it really returns; elapsed time never retires it.
    private var pendingAudioOperation: PendingAudioOperation?
    private let audioLifecycleWorker = GUIAudioLifecycleWorker()
    private var audioLifecycleIO = GUIAudioLifecycleIO()
    private var lifecycleStartsDiagnosticsTimer = true
    private var finishRequestedQuit: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    private var spectrumAnalyzer: AudioSpectrumAnalyzer?
    private var sourceFormatTracker: SourceFormatTracker?
    private var lastSourceSnapshot: SourceFormatSnapshot?
    private var lastSourceObservation: SourceFormatSnapshot?
    private var lastSpatialSubmissionRevision: UInt64 = 0
    private var diagnosticsTimer: Timer?
    private let dynamicsMeterModel = DynamicsMeterModel()
    private let spectrumModel = SpectrumModel()
    private let spatialControlModel = SpatialControlModel()
    private var currentProcessingSampleRate: Double?
    private var currentSourceSampleRate: Double?
    private var currentDeviceSampleRate: Double?
    private var currentSourcePlayerName: String?
    private var currentSourceBitDepth: Int?
    private var currentOutputSampleFormat = "32-bit Float"

    // Live pipeline state mirrored from AudioFormatNotifications for the
    // read-only Diagnostics panel. Populated in audioFormatDidChange (main).
    private var currentTapSampleRate: Double?
    private var currentLivePCM2xActive = false
    private var currentLivePCM2xFallback = ""
    private var currentStopFailure: String?
    private var currentProcessingFailure: String?
    private var pendingHeadroomEdit = false
    private var supportedDeviceSampleRates: [Double] = []
    private var isDeviceSampleRateSettable = false
    private var automaticRateMatchingEnabled = UserDefaults.standard.bool(
        forKey: "automaticRateMatchingEnabled"
    )
    private var expertModeEnabled = UserDefaults.standard.bool(
        forKey: "expertModeEnabled"
    )
    private var rateMatchStatusText = L10n.string("runtime.rate.off")
    private var exciterOversamplingMode: ExciterOversamplingMode = {
        let rawValue = UInt32(clamping: UserDefaults.standard.integer(forKey: "exciterOversamplingMode"))
        return ExciterOversamplingMode(rawValue: rawValue) ?? .auto
    }()

    // Output Conditioning (experimental) UI state, persisted via UserDefaults.
    private var outputConditioningEnabled = UserDefaults.standard.bool(
        forKey: "outputConditioningEnabled"
    )
    private var outputConditioningModeRaw: UInt32 = {
        let stored = UInt32(clamping: UserDefaults.standard.integer(forKey: "outputConditioningMode"))
        return OutputConditioningMode(rawValue: stored)?.rawValue ?? OutputConditioningMode.bypass.rawValue
    }()
    private var outputConditioningFactor: Int = {
        let stored = UserDefaults.standard.integer(forKey: "outputConditioningFactor")
        return OutputConditioningParameters.allowedOversamplingFactors.contains(stored) ? stored : 2
    }()
    private var outputConditioningFilterRaw: UInt32 = {
        let stored = UInt32(clamping: UserDefaults.standard.integer(forKey: "outputConditioningFilter"))
        return ResamplingFilterMode(rawValue: stored)?.rawValue ?? ResamplingFilterMode.linearPhaseShort.rawValue
    }()
    private var outputConditioningHeadroomDB: Double = {
        if let value = UserDefaults.standard.object(forKey: "outputConditioningHeadroomDB") as? Double {
            return value
        }
        return -3.0
    }()
    private var outputConditioningDither = UserDefaults.standard.bool(
        forKey: "outputConditioningDither"
    )
    private var outputConditioningNoiseShape = UserDefaults.standard.bool(
        forKey: "outputConditioningNoiseShape"
    )
    private var outputConditioningDSDRaw: UInt32 = {
        let stored = UInt32(clamping: UserDefaults.standard.integer(forKey: "outputConditioningDSD"))
        return DSDMode(rawValue: stored)?.rawValue ?? DSDMode.off.rawValue
    }()
    private var outputConditioningCapability: OutputConditioningCapability?
    private var outputConditioningEnableButton: NSButton!
    private var outputConditioningModePopup: NSPopUpButton!
    private var outputConditioningFactorPopup: NSPopUpButton!
    private var outputConditioningFilterPopup: NSPopUpButton!
    private var outputConditioningHeadroomSlider: NSSlider!
    private var outputConditioningHeadroomCaption: NSTextField!
    private var outputConditioningHeadroomValueLabel: NSTextField!
    private var outputConditioningRuntimeLabel: NSTextField!
    private var outputConditioningDitherButton: NSButton!
    private var outputConditioningNoiseShapeButton: NSButton!
    private var outputConditioningDSDPopup: NSPopUpButton!
    private var outputConditioningStatusLabel: NSTextField!

    // Diagnostics panel — read-only value labels, updated by refreshDiagnosticsPanel.
    private var diagTapValue: NSTextField!
    private var diagEngineValue: NSTextField!
    private var diagDeviceValue: NSTextField!
    private var diagFormatValue: NSTextField!
    private var diagConditioningValue: NSTextField!
    private var diagFallbackValue: NSTextField!
    private var diagHighExciterValue: NSTextField!
    private var diagXRunValue: NSTextField!
    private var diagRestartValue: NSTextField!
    private var diagDeviceNameValue: NSTextField!
    private var diagCaptureValue: NSTextField!
    private var diagAudioFlowValue: NSTextField!

    // Device name is resolved from CoreAudio only when the device changes (it
    // rarely does mid-session), avoiding a main-thread IPC on every 1 Hz tick.
    private var diagCachedDeviceID: AudioObjectID = kAudioObjectUnknown
    private var diagCachedDeviceName: String = "—"

    func applicationDidFinishLaunching(_ notification: Notification) {
        rateMatchStatusText = automaticRateMatchingEnabled
            ? L10n.string("runtime.rate.waiting")
            : L10n.string("runtime.rate.off")
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioFormatDidChange(_:)),
            name: AudioFormatNotifications.didChange,
            object: nil
        )
        buildWindow()
        refreshRateMatchDeviceCapabilities()
        refreshOutputConditioningCapability()
        startSourceFormatTracking()
    }

    deinit {
        sourceFormatTracker?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if pendingAudioOperation == nil && processor == nil { return .terminateNow }
        requestStopAudio(quit: true)
        // Keep the event loop usable even if HAL takes a long time to return.
        // A confirmed asynchronous Stop will request termination again.
        window?.makeKeyAndOrderFront(nil)
        return .terminateCancel
    }

    private func buildWindow(showWindow: Bool = true) {
        migrateLegacyOutputConditioningPreferences()
        rateMatchStatusText = automaticRateMatchingEnabled ? L10n.string("runtime.rate.waiting") : L10n.string("runtime.rate.off")
        print("Opening TimbreDock control window.")
        let rect = NSRect(x: 0, y: 0, width: 1180, height: 780)
        window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("main.window.title")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = GlassDesign.canvas
        window.minSize = NSSize(width: 940, height: 640)
        window.autorecalculatesKeyViewLoop = true
        window.delegate = self
        window.center()

        let content = MonochromeSurface(frame: rect, radius: 0, canvas: true)
        content.autoresizingMask = [.width, .height]
        content.wantsLayer = true

        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView(frame: rect)
            container.spacing = 0
            container.contentView = content
            window.contentView = container
        } else { window.contentView = content }
        rootView = content

        let sidebar = GlassPanel(frame: NSRect(x: 0, y: 0, width: 184, height: rect.height), radius: 20)
        sidebarView = sidebar
        sidebarView.wantsLayer = true

        content.addSubview(sidebarView)

        let brand = makeLabel(L10n.string("main.brand.name"), size: 20, weight: .bold)
        brand.textColor = GlassDesign.ink
        brand.lineBreakMode = .byTruncatingTail
        brand.frame = NSRect(x: 20, y: rect.height - 54, width: 150, height: 28)
        brand.autoresizingMask = [.minYMargin]
        sidebar.content.addSubview(brand)

        for (index, page) in AppPage.allCases.enumerated() {
            let button = makeSidebarButton(page: page)
            button.frame = NSRect(x: 10, y: rect.height - 146 - CGFloat(index) * 50, width: 164, height: 42)
            button.autoresizingMask = [.minYMargin]
            sidebar.content.addSubview(button)
            sidebarButtons.append(button)
        }

        allSystemButton = NSButton(
            image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil) ?? NSImage(),
            target: self,
            action: #selector(startAllAudio)
        )
        allSystemButton.bezelStyle = .texturedRounded
        allSystemButton.imageScaling = .scaleProportionallyDown
        allSystemButton.contentTintColor = GlassDesign.secondary
        allSystemButton.isHidden = true
        allSystemButton.frame = NSRect(x: 64, y: 22, width: 42, height: 42)
        allSystemButton.setAccessibilityLabel(L10n.string("main.status.applySystem.accessibility"))
        allSystemButton.toolTip = L10n.string("main.status.applySystem.tooltip")
        sidebar.content.addSubview(allSystemButton)

        pageContainerView = NSView(frame: NSRect(x: 170, y: 0, width: 620, height: rect.height))
        pageContainerView.wantsLayer = true

        content.addSubview(pageContainerView)

        sessionView = NSView(frame: .zero)
        pageContainerView.addSubview(sessionView)
        headerView = makeCommonHeader()
        pageContainerView.addSubview(headerView)

        pageHostView = MonochromeSurface(frame: NSRect(x: 0, y: 0, width: 620, height: rect.height - 120))
        pageHostView.wantsLayer = true
        pageHostView.layer?.masksToBounds = true

        pageContainerView.addSubview(pageHostView)

        pageViews[.sound] = makeModelPage()
        pageViews[.spatial] = makeSpatialPage()
        pageViews[.monitor] = makeMonitorPage()
        pageViews[.output] = makeOutputConditioningPage()
        pageViews[.settings] = makeSettingsPage()
        for page in AppPage.allCases {
            guard let pageView = pageViews[page] else { continue }
            pageView.frame = pageHostView.bounds
            pageView.isHidden = page != selectedPage
            pageHostView.addSubview(pageView)
        }

        loadCaptureTargetPreferences()
        rebuildHeaderTargetMenu()
        updateFormatHeaderMode()
        updateCompactFormatSummary()
        refreshHeaderPresentation()
        layoutApplication()
        updateSelectedPage()
        refreshAudioOperationPresentation()
        if showWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowDidResize(_ notification: Notification) {
        layoutApplication()
    }

    private func layoutApplication() {
        guard let content = window?.contentView else { return }
        let bounds = content.bounds
        let margin: CGFloat = 12
        let sidebarWidth: CGFloat = 184
        let gap: CGFloat = 12
        let headerHeight: CGFloat = 68
        let sessionHeight: CGFloat = 64
        sidebarView.frame = NSRect(x: margin, y: margin, width: sidebarWidth, height: max(bounds.height - margin * 2, 1))
        pageContainerView.frame = NSRect(x: margin + sidebarWidth + gap, y: margin,
            width: max(bounds.width - sidebarWidth - gap - margin * 2, 1), height: max(bounds.height - margin * 2, 1))
        let size = pageContainerView.bounds.size
        headerView.frame = NSRect(x: 0, y: max(size.height - headerHeight, 0), width: size.width, height: headerHeight)
        sessionView.frame = NSRect(x: 0, y: 0, width: size.width, height: sessionHeight)
        pageHostView.frame = NSRect(x: 0, y: sessionHeight + gap, width: size.width,
            height: max(size.height - headerHeight - sessionHeight - gap * 2, 1))
        headerView.layoutSubtreeIfNeeded()
        layoutCommonHeader()
        for pageView in pageViews.values { pageView.frame = pageHostView.bounds }
        layoutModelPage()
        layoutOutputConditioningPage()
        layoutSettingsPage()
    }

    private func makeCommonHeader() -> NSView {
        let view = GlassPanel(frame: NSRect(x: 0, y: 0, width: 620, height: 68), radius: 18)
        view.wantsLayer = true

        headerTargetCaption = makeLabel(L10n.string("main.header.target.label"), size: 11, weight: .semibold)
        headerTargetCaption.isHidden = true
        view.content.addSubview(headerTargetCaption)

        headerTargetPopup = StudioPopUpButton(frame: NSRect(x: 74, y: 82, width: 210, height: 26), pullsDown: false)
        headerTargetPopup.target = self
        headerTargetPopup.action = #selector(headerTargetChanged)
        headerTargetPopup.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTargetPopup.focusRingType = .none
        headerTargetPopup.setAccessibilityLabel(L10n.string("main.a11y.target"))
        headerTargetPopup.toolTip = L10n.string("main.target.discovery.tooltip")
        view.content.addSubview(headerTargetPopup)

        headerChooseButton = makeButton(L10n.string("main.header.target.choose"), action: #selector(chooseTargetApp))
        headerChooseButton.font = .systemFont(ofSize: 12, weight: .semibold)
        headerChooseButton.frame = NSRect(x: 292, y: 82, width: 110, height: 26)
        headerChooseButton.image = NSImage(systemSymbolName: "plus.app", accessibilityDescription: nil)
        headerChooseButton.imagePosition = .imageOnly
        headerChooseButton.setAccessibilityLabel(headerChooseButton.title)
        headerChooseButton.toolTip = headerChooseButton.title
        view.content.addSubview(headerChooseButton)

        headerClearButton = makeButton(L10n.string("main.header.target.clear"), action: #selector(clearTargetApp))
        headerClearButton.font = .systemFont(ofSize: 12, weight: .regular)
        headerClearButton.frame = NSRect(x: 408, y: 82, width: 118, height: 26)
        headerClearButton.toolTip = L10n.string("main.target.clear.tooltip")
        headerClearButton.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        headerClearButton.imagePosition = .imageOnly
        headerClearButton.setAccessibilityLabel(headerClearButton.title)
        view.content.addSubview(headerClearButton)

        headerApplyButton = makeButton(L10n.string("main.button.apply"), action: #selector(applyDraftTarget))
        headerApplyButton.keyEquivalent = "\r"
        (headerApplyButton as? StudioButton)?.prominent = true
        headerApplyButton.setAccessibilityLabel(L10n.string("main.a11y.apply"))
        headerApplyButton.autoresizingMask = []
        headerApplyButton.frame = NSRect(x: 620 - 196, y: 82, width: 86, height: 26)
        view.content.addSubview(headerApplyButton)
        // The lifecycle presentation enables/disables Apply through this
        // existing property so the tested machinery keeps one owner.
        routingStartAppButton = headerApplyButton

        headerStopButton = makeButton(L10n.string("main.button.stop"), action: #selector(stopAudio))
        headerStopButton.setAccessibilityLabel(L10n.string("main.a11y.stop"))
        headerStopButton.autoresizingMask = []
        headerStopButton.frame = NSRect(x: 620 - 104, y: 82, width: 96, height: 26)
        view.content.addSubview(headerStopButton)

        statusLabel = makeLabel(L10n.string("main.status.ready"), size: 12.5, weight: .semibold)
        statusLabel.textColor = GlassDesign.ink
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.autoresizingMask = []
        sessionView.addSubview(statusLabel)

        headerActiveTargetLabel = makeLabel(L10n.string("main.header.active.none"), size: 11.5, weight: .medium)
        headerActiveTargetLabel.textColor = GlassDesign.secondary
        headerActiveTargetLabel.lineBreakMode = .byTruncatingTail
        headerActiveTargetLabel.setAccessibilityLabel(L10n.string("main.a11y.activeTarget"))
        headerActiveTargetLabel.autoresizingMask = []
        sessionView.addSubview(headerActiveTargetLabel)

        compactSourceTitleLabel = makeLabel(L10n.string("main.format.sourceTitle"), size: 10.5, weight: .semibold)
        compactSourceTitleLabel.textColor = GlassDesign.secondary
        compactSourceTitleLabel.lineBreakMode = .byTruncatingTail
        sessionView.addSubview(compactSourceTitleLabel)

        compactSourceValueLabel = makeLabel(L10n.string("main.format.sourceWaiting"), size: 13, weight: .bold)
        compactSourceValueLabel.font = .systemFont(ofSize: 11, weight: .medium)
        compactSourceValueLabel.textColor = GlassDesign.ink
        compactSourceValueLabel.lineBreakMode = .byTruncatingTail
        sessionView.addSubview(compactSourceValueLabel)

        compactModelLabel = makeLabel(
            L10n.format("main.sound.summary.model", selectedDSPModel().displayName),
            size: 11, weight: .semibold
        )
        compactModelLabel.textColor = GlassDesign.secondary
        compactModelLabel.lineBreakMode = .byTruncatingTail
        compactModelLabel.isHidden = true
        sessionView.addSubview(compactModelLabel)

        compactOutputLabel = makeLabel(L10n.string("main.format.outputWaiting"), size: 11, weight: .medium)
        compactOutputLabel.textColor = GlassDesign.secondary
        compactOutputLabel.lineBreakMode = .byTruncatingMiddle
        sessionView.addSubview(compactOutputLabel)

        headerOutputLabel = makeLabel(L10n.string("main.header.output.waiting"), size: 11, weight: .medium)
        headerOutputLabel.textColor = GlassDesign.secondary
        headerOutputLabel.lineBreakMode = .byTruncatingTail
        headerOutputLabel.autoresizingMask = []
        sessionView.addSubview(headerOutputLabel)

        return view
    }

    private func layoutCommonHeader() {
        let width = headerView.bounds.width
        headerTargetPopup.frame = NSRect(x: 14, y: 14, width: width - 300, height: 40)
        let next = headerTargetPopup.frame.maxX + 8
        headerChooseButton.frame = NSRect(x: next, y: 14, width: 40, height: 40)
        headerClearButton.frame = NSRect(x: next + 46, y: 14, width: 40, height: 40)
        headerApplyButton.frame = NSRect(x: width - 178, y: 14, width: 88, height: 40)
        headerStopButton.frame = NSRect(x: width - 84, y: 14, width: 70, height: 40)
        let column = (width - 64) / 3
        statusLabel.frame = NSRect(x: 16, y: 32, width: column, height: 19)
        headerActiveTargetLabel.frame = NSRect(x: 16, y: 10, width: column, height: 17)
        compactSourceTitleLabel.frame = NSRect(x: column + 32, y: 32, width: column, height: 19)
        compactSourceValueLabel.frame = NSRect(x: column + 32, y: 10, width: column, height: 17)
        headerOutputLabel.frame = NSRect(x: column * 2 + 48, y: 32, width: column, height: 19)
        compactOutputLabel.frame = NSRect(x: column * 2 + 48, y: 10, width: column, height: 17)
    }

    private func loadCaptureTargetPreferences() {
        let stored = preferenceStore.string(forKey: "captureTargetBundleID")
        let name = preferenceStore.string(forKey: "captureTargetName")
        draftTarget = CaptureTarget.fromPersisted(stored, name: name)
        bundleField?.stringValue = draftTarget.bundleID ?? ""
    }

    private func persistDraftTarget() {
        preferenceStore.set(draftTarget.persistedValue, forKey: "captureTargetBundleID")
        if case .app(_, let name) = draftTarget {
            preferenceStore.set(name ?? "", forKey: "captureTargetName")
        } else {
            preferenceStore.set("", forKey: "captureTargetName")
        }
    }

    private func setDraftTarget(_ target: CaptureTarget) {
        draftTarget = target
        persistDraftTarget()
        bundleField?.stringValue = target.bundleID ?? ""
        rebuildHeaderTargetMenu()
        refreshHeaderPresentation()
    }

    private func rebuildHeaderTargetMenu(discoveredApps: [DiscoveredAudioApp]? = nil) {
        guard let popup = headerTargetPopup else { return }
        popup.removeAllItems()
        headerTargetEntryBundleIDs = []
        headerTargetEntryNames = []
        headerTargetEntryIsSeparator = []

        popup.addItem(withTitle: L10n.string("main.header.target.system"))
        popup.lastItem?.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
        headerTargetEntryBundleIDs.append(nil)
        headerTargetEntryNames.append(L10n.string("main.header.target.system"))
        headerTargetEntryIsSeparator.append(false)

        popup.menu?.addItem(.separator())
        headerTargetEntryBundleIDs.append(nil)
        headerTargetEntryNames.append("")
        headerTargetEntryIsSeparator.append(true)

        var apps = discoveredApps ?? AudioProcessDiscovery.runningApps()
        if case .app(let bundleID, let name) = draftTarget,
           !apps.contains(where: { $0.bundleID == bundleID }) {
            apps.insert(DiscoveredAudioApp(name: name ?? bundleID, bundleID: bundleID, pid: 0), at: 0)
        }
        for app in apps {
            let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
            item.representedObject = app.bundleID
            item.image = AudioProcessDiscovery.icon(forBundleID: app.bundleID)
                ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            popup.menu?.addItem(item)
            headerTargetEntryBundleIDs.append(app.bundleID)
            headerTargetEntryNames.append(app.name)
            headerTargetEntryIsSeparator.append(false)
        }
        syncHeaderTargetSelection()
    }

    private func syncHeaderTargetSelection() {
        guard let popup = headerTargetPopup else { return }
        let wanted = draftTarget.bundleID
        for (index, bundleID) in headerTargetEntryBundleIDs.enumerated() {
            if headerTargetEntryIsSeparator.indices.contains(index), headerTargetEntryIsSeparator[index] { continue }
            if bundleID == wanted {
                popup.selectItem(at: index)
                return
            }
        }
        popup.selectItem(at: 0)
    }

    @objc private func headerTargetChanged() {
        let index = headerTargetPopup.indexOfSelectedItem
        guard headerTargetEntryBundleIDs.indices.contains(index),
              !headerTargetEntryIsSeparator[index] else { return }
        if let bundleID = headerTargetEntryBundleIDs[index] {
            draftTarget = .app(bundleID: bundleID, name: headerTargetEntryNames[index])
        } else {
            draftTarget = .system
        }
        persistDraftTarget()
        bundleField?.stringValue = draftTarget.bundleID ?? ""
        refreshHeaderPresentation()
    }

    @objc private func chooseTargetApp() {
        let apps = AudioProcessDiscovery.runningApps()
        guard !apps.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L10n.string("main.header.target.label")
        alert.informativeText = L10n.string("main.target.discovery.tooltip")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for app in apps {
            let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
            item.representedObject = app.bundleID
            item.image = AudioProcessDiscovery.icon(forBundleID: app.bundleID)
                ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            popup.menu?.addItem(item)
        }
        popup.selectItem(at: 0)
        alert.accessoryView = popup
        alert.addButton(withTitle: L10n.string("main.header.target.choose"))
        alert.addButton(withTitle: L10n.string("main.alert.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = popup.indexOfSelectedItem
        guard apps.indices.contains(index) else { return }
        setDraftTarget(.app(bundleID: apps[index].bundleID, name: apps[index].name))
    }

    @objc private func clearTargetApp() {
        setDraftTarget(.system)
    }

    @objc private func commitBundleTarget() {
        let value = bundleField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            setDraftTarget(.system)
            return
        }
        let name = AudioProcessDiscovery.runningApps().first { $0.bundleID == value }?.name
        setDraftTarget(.app(bundleID: value, name: name))
    }

    @objc private func applyDraftTarget() {
        guard pendingAudioOperation == nil else {
            refreshAudioOperationPresentation()
            return
        }
        let target = draftTarget
        pendingTarget = target
        start(settings(for: target.bundleID.map { .bundleIDs([$0]) } ?? .all))
    }

    private func refreshHeaderPresentation() {
        statusLabel?.toolTip = statusLabel?.stringValue
        if let activeTarget {
            headerActiveTargetLabel?.stringValue =
                L10n.format("main.header.active.some", activeTarget.displayName())
        } else {
            headerActiveTargetLabel?.stringValue = L10n.string("main.header.active.none")
        }
        headerActiveTargetLabel?.toolTip = L10n.string("main.header.pending")
        if diagCachedDeviceName != "—" {
            let name = diagCachedDeviceName
            headerOutputLabel?.stringValue = L10n.format("main.header.output.format", name)
        } else {
            headerOutputLabel?.stringValue = L10n.string("main.header.output.waiting")
        }
        headerOutputLabel?.toolTip = headerOutputLabel?.stringValue
    }

    private func makeMonitorPage() -> NSView {
        analysisRailView = NSHostingView(rootView: AnyView(MonitorPageView(
            dynamicsModel: dynamicsMeterModel, spectrumModel: spectrumModel, isActive: selectedPage == .monitor)))
        analysisRailView.frame = pageHostView.bounds
        return analysisRailView
    }

    private func outputString(_ key: String, _ fallback: String) -> String {
        L10n.string(key)
    }

    private func makeOutputWrappingLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = makeLabel(text, size: size, weight: weight)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func layoutOutputConditioningPage(_ page: NSView? = nil) {
        guard let page = page ?? outputDocument else { return }
        let notice = preferenceStore.bool(forKey: RedesignPreferences.Keys.noticePending)
        let offset: CGFloat = notice ? 80 : 0
        page.setFrameSize(NSSize(width: max(outputScroll?.contentSize.width ?? page.frame.width, 1),
                                 height: max(outputScroll?.contentSize.height ?? 0, 620 + offset)))
        let width = page.bounds.width
        let left: CGFloat = 28
        let inner: CGFloat = 48
        let available = width - 96
        func set(_ view: NSView?, x: CGFloat = 48, top: CGFloat, width: CGFloat, height: CGFloat) {
            view?.frame = NSRect(x: x, y: top, width: max(1, width), height: height)
        }
        func tagged(_ tag: OutputPageTag) -> NSView? { page.viewWithTag(tag.rawValue) }
        set(tagged(.title), x: left, top: 24, width: width - 100, height: 34)
        for (tag, top, h) in [(9921, CGFloat(90), CGFloat(100)), (9922, 206 + offset, 100), (9923, 322 + offset, 112)] {
            set(page.viewWithTag(tag), x: left, top: top, width: width - left * 2, height: h)
        }
        set(tagged(.modeCaption), top: 108, width: available - 32, height: 20)
        set(outputRateModePopup, x: inner - 2, top: 136, width: min(440, available), height: 40)
        set(tagged(.filterCaption), top: 224 + offset, width: available - 32, height: 20)
        set(outputConditioningFilterPopup, x: inner - 2, top: 252 + offset, width: min(240, available), height: 40)
        set(outputConditioningHeadroomCaption, top: 340 + offset, width: available - 32, height: 20)
        set(outputConditioningHeadroomSlider, top: 382 + offset, width: available - 100, height: 28)
        set(outputConditioningHeadroomValueLabel, x: width - 136, top: 380 + offset, width: 88, height: 30)
        if notice {
            set(outputMigrationNoticeLabel, x: left, top: 202, width: width - 230, height: 62)
            set(outputMigrationDismissButton, x: width - 188, top: 216, width: 160, height: 30)
        } else {
            outputMigrationNoticeLabel?.frame = .zero; outputMigrationDismissButton?.frame = .zero
        }
        set(outputConditioningStatusLabel, x: left, top: 454 + offset, width: width - 56, height: 36)
        set(outputConditioningRuntimeLabel, x: left, top: 498 + offset, width: width - 56, height: 86)
        for view in [tagged(.subtitle), outputModeDetailLabel, tagged(.filterDetail), tagged(.gainNote)] { view?.frame = .zero }
        for (tag, caption) in [(9901, tagged(.title)), (9902, tagged(.modeCaption)),
                                (9903, tagged(.filterCaption)), (9904, outputConditioningHeadroomCaption)] {
            if let help = page.viewWithTag(tag), let caption {
                help.frame = NSRect(x: width - (tag == 9901 ? 56 : 76), y: caption.frame.midY - 14, width: 28, height: 28)
            }
        }
        for view in page.subviews { view.autoresizingMask = [] }
    }

    private func refreshOutputRateModeSelection() {
        if let index = OutputRateMode.allCases.firstIndex(of: outputRateMode) {
            outputRateModePopup?.selectItem(at: index)
        }
        outputModeDetailLabel?.stringValue = outputRateMode.detail
        (outputDocument?.viewWithTag(9902) as? GlassHelpButton)?.message = outputRateMode.detail
        outputRateModePopup?.toolTip = outputRateMode.detail
        refreshOutputGainNote()
    }

    private func refreshOutputGainNote() {
        guard let note = outputDocument?
            .viewWithTag(OutputPageTag.gainNote.rawValue) as? NSTextField else { return }
        let state = outputGainStateText
        note.stringValue = String(
            format: outputString("main.output.gain.tooltip", "%@. Requested %@. It attenuates level only on the actual 2x output."),
            state,
            formatDbText(outputConditioningHeadroomDB))
        (outputDocument?.viewWithTag(9904) as? GlassHelpButton)?.message = note.stringValue
    }

    private func layoutSettingsPage() {
        guard let settingsScroll, let settingsDocument else { return }
        settingsDocument.frame.size = NSSize(width: settingsScroll.contentSize.width,
            height: expertModeEnabled ? 1280 : max(settingsScroll.contentSize.height, 320))
        advancedSettingsView?.frame.size.width = settingsScroll.contentSize.width
        advancedSettingsView?.isHidden = !expertModeEnabled
    }

    @objc private func languageChanged() {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: raw) else { return }
        preferenceStore.set(language.rawValue, forKey: AppLanguage.preferenceKey)
        // Flush this infrequent explicit preference change before the user quits.
        if preferenceStore.synchronize() {
            refreshLanguagePresentation()
        } else {
            languageStatusLabel?.stringValue = L10n.string("main.settings.language.saveFailed")
        }
    }

    private func refreshLanguagePresentation() {
        let saved = AppLanguage.fromStoredValue(preferenceStore.string(forKey: AppLanguage.preferenceKey))
        languageStatusLabel?.stringValue = saved == AppLanguage.current
            ? L10n.format("main.settings.language.current", AppLanguage.current.nativeName)
            : L10n.format("main.settings.language.pending", saved.nativeName, AppLanguage.current.nativeName)
    }

    private func migrateLegacyOutputConditioningPreferences() {
        let migrated = RedesignPreferences.migrate(preferenceStore)
        initialModel = migrated.model
        outputRateMode = migrated.outputMode
        outputConditioningEnabled = migrated.outputMode == .upsample2x
        outputConditioningModeRaw = outputConditioningEnabled ? OutputConditioningMode.pcmOversampling.rawValue : OutputConditioningMode.bypass.rawValue
        outputConditioningFactor = 2
        outputConditioningFilterRaw = migrated.filter.rawValue
        outputConditioningHeadroomDB = migrated.gainDB
        outputConditioningDither = false; outputConditioningNoiseShape = false; outputConditioningDSDRaw = DSDMode.off.rawValue
        automaticRateMatchingEnabled = migrated.outputMode == .matchSource
    }

    @objc private func outputRateModeChanged() {
        guard let popup = outputRateModePopup, OutputRateMode.allCases.indices.contains(popup.indexOfSelectedItem) else { return }
        outputRateMode = OutputRateMode.allCases[popup.indexOfSelectedItem]
        preferenceStore.set(outputRateMode.rawValue, forKey: "outputRateMode")
        // Normalize the stored and in-memory legacy representation together.
        migrateLegacyOutputConditioningPreferences()
        rateMatchStatusText = automaticRateMatchingEnabled ? L10n.string("runtime.rate.waiting") : L10n.string("runtime.rate.off")
        refreshOutputRateModeSelection()
        applyOutputConditioningControlEnabledState()
        // Also refresh the Diagnostics rows. updateOutputConditioningStatus
        // only owns the main status label, so a stopped 2x session followed
        // by a Standard/Match Source switch could leave a stale
        // "PCM 2x pending" row until something else called this.
        refreshDiagnosticsPanel()
        pushOutputConditioningSettings()
        if pendingAudioOperation == nil, currentStopFailure == nil, currentProcessingFailure == nil {
            processor?.setAutomaticRateMatchingEnabled(automaticRateMatchingEnabled)
        }
        rateMatchStatusText = automaticRateMatchingEnabled ? L10n.string("runtime.rate.waiting") : L10n.string("runtime.rate.off")
        updateRateMatchPreview()
    }

    private func makeSidebarButton(page: AppPage) -> NSButton {
        let button = NavigationPill(title: page.title, target: self, action: #selector(sidebarPageChanged(_:)))
        button.tag = page.rawValue
        button.bezelStyle = .recessed
        button.isBordered = false
        button.navigation = true
        button.focusRingType = .none
        button.refusesFirstResponder = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.image = NSImage(systemSymbolName: page.symbolName, accessibilityDescription: page.title)
        button.imagePosition = .imageLeading
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        return button
    }

    @objc private func sidebarPageChanged(_ sender: NSButton) {
        guard let page = AppPage(rawValue: sender.tag) else { return }
        selectedPage = page
        updateSelectedPage()
    }

    private func updateSelectedPage() {
        spectrumModel.setAnalysisActive(selectedPage == .monitor)
        analysisRailView?.rootView = AnyView(MonitorPageView(dynamicsModel: dynamicsMeterModel,
            spectrumModel: spectrumModel, isActive: selectedPage == .monitor))
        for page in AppPage.allCases {
            pageViews[page]?.isHidden = page != selectedPage
            guard let button = sidebarButtons.first(where: { $0.tag == page.rawValue }) else {
                continue
            }
            let selected = page == selectedPage
            button.state = selected ? .on : .off
            button.contentTintColor = selected ? .labelColor : .secondaryLabelColor
            button.font = .systemFont(ofSize: 13, weight: selected ? .bold : .medium)
        }
    }

    private func makeModelPage() -> NSView {
        let bounds = pageHostView?.bounds ?? NSRect(x: 0, y: 0, width: 769, height: 520)
        modelScroll = NSScrollView(frame: bounds)
        modelScroll.hasVerticalScroller = true
        modelScroll.drawsBackground = false
        modelScroll.autoresizingMask = [.width, .height]
        let page = TopAlignedDocument(frame: NSRect(x: 0, y: 0, width: bounds.width, height: 552))
        modelDocument = page; modelScroll.documentView = page
        if statusLabel == nil { statusLabel = makeLabel(L10n.string("main.status.ready"), size: 12, weight: .medium) }
        if diagnosticsLabel == nil { diagnosticsLabel = makeLabel("", size: 10, weight: .regular) }
        let title = makeLabel(L10n.string("main.page.sound"), size: 26, weight: .bold)
        title.frame = NSRect(x: 28, y: 24, width: 400, height: 34)
        page.addSubview(title)
        modelSelector = StudioSegmentedControl(labels: [Settings.DSPModel.clean, .circuit, .highExciter].map(\.displayName),
            trackingMode: .selectOne, target: self, action: #selector(modelChanged))
        modelSelector.focusRingType = .none
        modelSelector.font = .systemFont(ofSize: 13, weight: .semibold)
        modelSelector.selectedSegment = initialModel == .clean ? 0 : initialModel == .circuit ? 1 : 2
        modelSelector.setAccessibilityLabel(L10n.string("main.page.sound"))
        page.addSubview(modelSelector)
        toneReceiptLabel = makeLabel("", size: 11, weight: .regular)
        toneReceiptLabel.textColor = .secondaryLabelColor
        toneReceiptLabel.lineBreakMode = .byWordWrapping
        toneReceiptLabel.maximumNumberOfLines = 2
        toneReceiptLabel.setAccessibilityIdentifier("sound.audioReceipt")
        page.addSubview(toneReceiptLabel)
        refreshToneReceiptPresentation()
        modelExplanationView = makeExplanationSection(); modelExplanationView.isHidden = true; page.addSubview(modelExplanationView)
        let help = GlassHelpButton([L10n.string("main.detail.5224898d4f"), L10n.string("main.detail.c5653f1038"), L10n.string("main.detail.9dc3b9005a")].joined(separator: "\n\n"), context: L10n.string("main.page.sound"))
        help.tag = 9801; page.addSubview(help)
        modelControlsView = makeControlSection(); page.addSubview(modelControlsView)
        let presetCaption = makeLabel(L10n.string("main.sound.presets"), size: 11, weight: .semibold)
        presetCaption.textColor = .secondaryLabelColor; presetCaption.tag = 9802; page.addSubview(presetCaption)
        modelPresetsView = makePresetSection(); page.addSubview(modelPresetsView)
        return modelScroll
    }

    private func makeSpatialPage() -> NSView {
        let view = NSHostingView(rootView: AnyView(
            SpatialPageView(
                spatialModel: spatialControlModel,
                onSpatialChange: { [weak self] settings in
                    self?.updateSpatialControls(from: settings, notifyProcessor: true)
                }
            )
        ))
        view.frame = pageContainerView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 700)
        return view
    }



    private func makeSettingsPage() -> NSView {
        settingsScroll = NSScrollView(frame: pageHostView.bounds)
        settingsScroll.hasVerticalScroller = true
        settingsScroll.drawsBackground = false
        settingsScroll.autoresizingMask = [.width, .height]
        settingsDocument = TopAlignedDocument(frame: NSRect(x: 0, y: 0, width: pageHostView.bounds.width, height: 340))
        settingsScroll.documentView = settingsDocument
        let languageSurface = MonochromeSurface(frame: NSRect(x: 28, y: 108, width: pageHostView.bounds.width - 56, height: 124), radius: 14, well: true)
        languageSurface.autoresizingMask = [.width]; settingsDocument.addSubview(languageSurface)
        let title = makeLabel(L10n.string("main.settings.title"), size: 26, weight: .bold)
        title.frame = NSRect(x: 28, y: 24, width: 500, height: 32); settingsDocument.addSubview(title)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "LCBuildID") as? String ?? "Development"
        let versionLabel = makeLabel("TimbreDock \(version) · \(build)", size: 11, weight: .medium)
        versionLabel.frame = NSRect(x: 28, y: 66, width: 680, height: 22)
        versionLabel.lineBreakMode = .byTruncatingMiddle; versionLabel.autoresizingMask = [.width]
        settingsDocument.addSubview(versionLabel)
        let language = makeLabel(L10n.string("main.settings.language.label"), size: 13, weight: .semibold)
        language.frame = NSRect(x: 48, y: 128, width: 160, height: 24); settingsDocument.addSubview(language)
        languagePopup = StudioPopUpButton(frame: NSRect(x: 220, y: 120, width: 220, height: 40), pullsDown: false)
        for language in AppLanguage.allCases {
            languagePopup.addItem(withTitle: language.nativeName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.selectItem(at: AppLanguage.fromStoredValue(preferenceStore.string(forKey: AppLanguage.preferenceKey)) == .english ? 0 : 1)
        languagePopup.target = self; languagePopup.action = #selector(languageChanged)
        languagePopup.setAccessibilityLabel(L10n.string("main.settings.language.accessibility"))
        settingsDocument.addSubview(languagePopup)
        languageStatusLabel = makeLabel("", size: 12, weight: .regular)
        languageStatusLabel.frame = NSRect(x: 48, y: 178, width: 632, height: 38)
        languageStatusLabel.lineBreakMode = .byWordWrapping; languageStatusLabel.maximumNumberOfLines = 0
        languageStatusLabel.autoresizingMask = [.width]
        languageStatusLabel.setAccessibilityIdentifier("settings.language.status")
        settingsDocument.addSubview(languageStatusLabel)
        refreshLanguagePresentation()
        let languageHelp = GlassHelpButton(L10n.string("main.settings.language.note"), context: L10n.string("main.settings.language.label"))
        languageHelp.frame = NSRect(x: 452, y: 126, width: 28, height: 28)
        settingsDocument.addSubview(languageHelp)
        expertModeButton = NSButton(checkboxWithTitle: L10n.string("main.settings.advanced"), target: self, action: #selector(expertModeChanged))
        expertModeButton.state = expertModeEnabled ? .on : .off
        expertModeButton.frame = NSRect(x: 28, y: 252, width: 240, height: 28)
        expertModeButton.toolTip = L10n.string("main.settings.advanced.tooltip")
        settingsDocument.addSubview(expertModeButton)
        advancedSettingsView = TopAlignedDocument(frame: NSRect(x: 4, y: 302, width: 720, height: 970))
        settingsDocument.addSubview(advancedSettingsView)
        let bundleCaption = makeLabel(L10n.string("main.header.target.advanced"), size: 12, weight: .semibold)
        bundleCaption.frame = NSRect(x: 24, y: 0, width: 600, height: 22); advancedSettingsView.addSubview(bundleCaption)
        bundleField = NSTextField(frame: NSRect(x: 24, y: 30, width: 470, height: 28))
        bundleField.placeholderString = L10n.string("main.header.target.bundlePlaceholder")
        bundleField.target = self; bundleField.action = #selector(commitBundleTarget)
        bundleField.toolTip = L10n.string("main.bundleField.tooltip")
        bundleField.setAccessibilityLabel(L10n.string("main.bundleField.accessibility"))
        advancedSettingsView.addSubview(bundleField)
        let use = makeButton(L10n.string("main.button.useBundleID"), action: #selector(commitBundleTarget))
        use.frame = NSRect(x: 506, y: 28, width: 190, height: 30); advancedSettingsView.addSubview(use)
        sourceFormatLabel = makeLabel("Source: unknown", size: 11, weight: .medium)
        formatLabel = makeLabel("Tap / Engine / DAC: —", size: 11, weight: .medium)
        oversamplingLabel = makeLabel("", size: 11, weight: .medium)
        rateMatchPreviewLabel = makeLabel("", size: 11, weight: .medium)
        diagnosticsLabel = makeLabel("", size: 10, weight: .regular)
        for (i, label) in [sourceFormatLabel!, formatLabel!, oversamplingLabel!, rateMatchPreviewLabel!, diagnosticsLabel!].enumerated() {
            label.frame = NSRect(x: 24, y: 80 + CGFloat(i) * 22, width: 672, height: 20)
            label.lineBreakMode = .byTruncatingMiddle; label.autoresizingMask = [.width]
            advancedSettingsView.addSubview(label)
        }
        let diagnostics = makeDiagnosticsPage()
        diagnostics.frame = NSRect(x: 0, y: 202, width: 720, height: 720)
        diagnostics.autoresizingMask = [.width]; advancedSettingsView.addSubview(diagnostics)
        layoutSettingsPage()
        return settingsScroll
    }

    // MARK: - Output Conditioning page

    private func makeOutputConditioningPage() -> NSView {
        let page = TopAlignedDocument(frame: NSRect(x: 0, y: 0, width: pageHostView?.bounds.width ?? 769, height: 660))
        outputDocument = page
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor.clear.cgColor

        for tag in 9921...9923 {
            let section = MonochromeSurface(frame: .zero, radius: 14, well: true)
            section.tag = tag; page.addSubview(section)
        }
        let title = makeLabel(outputString("main.output.title", "Output"), size: 26, weight: .bold)
        title.textColor = GlassDesign.ink
        title.tag = OutputPageTag.title.rawValue
        page.addSubview(title)

        let subtitle = makeOutputWrappingLabel(
            outputString("main.output.subtitle", "One output rate mode at a time. Standard is the default."),
            size: 12, weight: .regular)
        subtitle.tag = OutputPageTag.subtitle.rawValue
        page.addSubview(subtitle)

        // Rate mode — exactly one of standard / upsample2x / matchSource.
        let modeCaption = makeLabel(outputString("main.output.mode.label", "Output Rate Mode"), size: 12, weight: .semibold)
        modeCaption.tag = OutputPageTag.modeCaption.rawValue
        page.addSubview(modeCaption)

        outputRateModePopup = StudioPopUpButton(frame: .zero, pullsDown: false)
        outputRateModePopup.addItems(withTitles: OutputRateMode.allCases.map { $0.title })
        outputRateModePopup.target = self
        outputRateModePopup.action = #selector(outputRateModeChanged)
        if let index = OutputRateMode.allCases.firstIndex(of: outputRateMode) {
            outputRateModePopup.selectItem(at: index)
        }
        page.addSubview(outputRateModePopup)

        outputModeDetailLabel = makeOutputWrappingLabel(outputRateMode.detail, size: 11, weight: .regular)
        outputModeDetailLabel.textColor = GlassDesign.secondary
        page.addSubview(outputModeDetailLabel)

        outputMigrationNoticeLabel = makeOutputWrappingLabel("", size: 11, weight: .regular)
        outputMigrationNoticeLabel.textColor = GlassDesign.secondary
        page.addSubview(outputMigrationNoticeLabel)
        outputMigrationDismissButton = NSButton(title: L10n.string("main.output.notice.dismiss"),
            target: self, action: #selector(dismissOutputMigrationNotice))
        outputMigrationDismissButton.bezelStyle = .rounded
        page.addSubview(outputMigrationDismissButton)

        // Filter — Short/Long only (linearPhaseShort, linearPhaseLong).
        let filterCaption = makeLabel(outputString("main.output.filter.label", "Filter"), size: 12, weight: .semibold)
        filterCaption.tag = OutputPageTag.filterCaption.rawValue
        page.addSubview(filterCaption)

        outputConditioningFilterPopup = makeConditioningPopup(
            titles: [outputString("main.output.filter.short", "Short"),
                     outputString("main.output.filter.long", "Long")],
            action: #selector(outputConditioningFilterChanged),
            y: 0)
        outputConditioningFilterPopup.toolTip = outputString(
            "main.output.filter.tooltip",
            "Polyphase interpolation filter for 2x upsampling. Short has lower latency; Long cuts sharper with more attenuation.")
        // minimumPhase (raw 2) is no longer offered; it displays as Short and the
        // migration notice below explains that, matching main.output.notice.legacyMinimumPhase.
        let filterIndex = outputConditioningFilterRaw == ResamplingFilterMode.linearPhaseLong.rawValue ? 1 : 0
        outputConditioningFilterPopup.selectItem(at: filterIndex)
        if outputConditioningFilterRaw != 0 && outputConditioningFilterRaw != 1 {
            outputMigrationNoticeLabel.stringValue = outputString(
                "main.output.notice.legacyMinimumPhase",
                "The saved minimum-phase filter was migrated to Short.")
        }
        page.addSubview(outputConditioningFilterPopup)

        let filterDetail = makeOutputWrappingLabel(
            outputString("main.output.filter.tooltip",
                         "Polyphase interpolation filter for 2x upsampling. Short has lower latency; Long cuts sharper with more attenuation."),
            size: 11, weight: .regular)
        filterDetail.textColor = GlassDesign.secondary
        filterDetail.tag = OutputPageTag.filterDetail.rawValue
        page.addSubview(filterDetail)

        // Upsampling gain (-12…0 dB, existing stored value).
        outputConditioningHeadroomCaption = makeLabel(outputString("main.output.gain.label", "Upsampling Gain"), size: 12, weight: .semibold)
        page.addSubview(outputConditioningHeadroomCaption)

        outputConditioningHeadroomSlider = NSSlider(
            value: outputConditioningHeadroomDB,
            minValue: -12,
            maxValue: 0,
            target: self,
            action: #selector(outputConditioningHeadroomChanged))
        outputConditioningHeadroomSlider.isContinuous = true
        outputConditioningHeadroomSlider.trackFillColor = .labelColor
        outputConditioningHeadroomSlider.setAccessibilityLabel(outputString("main.output.gain.accessibility", "Upsampling gain"))
        page.addSubview(outputConditioningHeadroomSlider)

        outputConditioningHeadroomValueLabel = makeLabel(formatDbText(outputConditioningHeadroomDB), size: 12, weight: .regular)
        outputConditioningHeadroomValueLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        outputConditioningHeadroomValueLabel.alignment = .right
        page.addSubview(outputConditioningHeadroomValueLabel)

        let gainNote = makeOutputWrappingLabel("", size: 11, weight: .regular)
        gainNote.textColor = GlassDesign.secondary
        gainNote.tag = OutputPageTag.gainNote.rawValue
        page.addSubview(gainNote)

        // Status + runtime text: content is produced by the existing root handlers.
        outputConditioningStatusLabel = makeOutputWrappingLabel("", size: 12, weight: .regular)
        outputConditioningStatusLabel.textColor = GlassDesign.secondary
        page.addSubview(outputConditioningStatusLabel)

        outputConditioningRuntimeLabel = makeOutputWrappingLabel("", size: 12, weight: .semibold)
        page.addSubview(outputConditioningRuntimeLabel)

        refreshOutputGainNote()
        layoutOutputConditioningPage(page)
        subtitle.isHidden = true
        outputModeDetailLabel.isHidden = true
        filterDetail.isHidden = true
        gainNote.isHidden = true
        for (tag, message) in [(9901, subtitle.stringValue), (9902, outputRateMode.detail),
                               (9903, filterDetail.stringValue), (9904, gainNote.stringValue)] {
            let context = tag == 9901 ? title.stringValue : tag == 9902 ? modeCaption.stringValue
                : tag == 9903 ? filterCaption.stringValue : outputConditioningHeadroomCaption.stringValue
            let help = GlassHelpButton(message, context: context); help.tag = tag; page.addSubview(help)
        }
        outputScroll = NSScrollView(frame: pageHostView?.bounds ?? NSRect(x: 0, y: 0, width: 769, height: 490))
        outputScroll.hasVerticalScroller = true
        outputScroll.drawsBackground = false
        outputScroll.autoresizingMask = [.width, .height]
        outputScroll.documentView = page
        outputScroll.contentView.scroll(to: .zero)
        return outputScroll
    }

    /// Read-only Diagnostics/Status page. Every value is sourced from existing
    /// off-callback state (NotificationCenter mirror + diagnosticsSnapshot() +
    /// ExciterOversamplingPolicy.resolve + a CoreAudio device-name query). The
    /// realtime render callback is never touched.
    private func makeDiagnosticsPage() -> NSView {
        let page = NSView(frame: pageContainerView?.bounds ?? NSRect(x: 0, y: 0, width: 620, height: 700))
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor.clear.cgColor

        let title = makeLabel(L10n.string("main.detail.771f6e8e1a"), size: 24, weight: .bold)
        title.textColor = GlassDesign.ink
        title.frame = NSRect(x: 24, y: 636, width: 320, height: 32)
        title.autoresizingMask = [.minYMargin]
        page.addSubview(title)

        let intro = makeLabel(
            L10n.string("main.detail.03c9cc221a"),
            size: 11, weight: .regular
        )
        intro.textColor = GlassDesign.secondary
        intro.lineBreakMode = .byWordWrapping
        intro.maximumNumberOfLines = 0
        intro.frame = NSRect(x: 24, y: 614, width: 540, height: 28)
        intro.autoresizingMask = [.minYMargin, .width]
        intro.isHidden = true
        page.addSubview(intro)
        let help = GlassHelpButton(intro.stringValue, context: L10n.string("main.detail.771f6e8e1a"))
        help.frame = NSRect(x: page.bounds.width - 54, y: 636, width: 28, height: 28)
        help.autoresizingMask = [.minXMargin, .minYMargin]; page.addSubview(help)

        page.addSubview(makeDiagSection(L10n.string("main.detail.296644b48a"), y: 584))
        diagTapValue = addDiagRow(to: page, caption: L10n.string("main.detail.3fd630b245"), value: "—", y: 560)
        diagEngineValue = addDiagRow(to: page, caption: L10n.string("main.detail.8e6ea54dd2"), value: "—", y: 536)
        diagDeviceValue = addDiagRow(to: page, caption: L10n.string("main.detail.3c8628cb58"), value: "—", y: 512)
        diagFormatValue = addDiagRow(to: page, caption: L10n.string("main.detail.add87c3d28"), value: "—", y: 488)

        page.addSubview(makeDiagSection("Output Conditioning", y: 452))
        diagConditioningValue = addDiagRow(to: page, caption: L10n.string("main.detail.e10195a123"), value: "Off", y: 428)
        diagFallbackValue = addDiagRow(to: page, caption: L10n.string("main.detail.45a644b1c7"), value: "—", y: 404)
        diagFallbackValue.lineBreakMode = .byWordWrapping
        diagFallbackValue.maximumNumberOfLines = 0
        diagFallbackValue.frame = NSRect(x: 320, y: 392, width: max(200, page.bounds.width - 344), height: 36)

        page.addSubview(makeDiagSection(L10n.string("main.detail.259721cf3b"), y: 372))
        diagHighExciterValue = addDiagRow(to: page, caption: L10n.string("main.diag.mode"), value: "—", y: 348)

        page.addSubview(makeDiagSection(L10n.string("main.diag.section.xrun"), y: 312))
        diagXRunValue = addDiagRow(to: page, caption: L10n.string("main.diag.xrun"), value: "0 / 0 / 0", y: 288)
        diagRestartValue = addDiagRow(to: page, caption: L10n.string("main.diag.restarts"), value: "0", y: 264)

        page.addSubview(makeDiagSection(L10n.string("main.diag.section.device"), y: 224))
        diagDeviceNameValue = addDiagRow(to: page, caption: L10n.string("main.diag.deviceName"), value: "—", y: 200)

        page.addSubview(makeDiagSection(L10n.string("main.diag.section.capture"), y: 160))
        diagCaptureValue = addDiagRow(to: page, caption: L10n.string("main.diag.capture"), value: "—", y: 136)
        diagAudioFlowValue = addDiagRow(to: page, caption: L10n.string("main.diag.audioFlow"), value: "—", y: 108)

        refreshDiagnosticsPanel()
        refreshAudioFlowPresentation()
        return page
    }

    private func makeDiagSection(_ text: String, y: CGFloat) -> NSTextField {
        let label = makeLabel(text, size: 13, weight: .semibold)
        label.textColor = GlassDesign.secondary
        label.frame = NSRect(x: 24, y: y, width: 540, height: 20)
        label.autoresizingMask = [.minYMargin, .width]
        return label
    }

    @discardableResult
    private func addDiagRow(to page: NSView, caption: String, value: String, y: CGFloat) -> NSTextField {
        let cap = makeLabel(caption, size: 12, weight: .regular)
        cap.textColor = GlassDesign.secondary
        cap.frame = NSRect(x: 24, y: y, width: 280, height: 18)
        cap.tag = 9970
        cap.autoresizingMask = [.minYMargin]
        page.addSubview(cap)
        let val = makeLabel(value, size: 12, weight: .regular)
        val.frame = NSRect(x: 320, y: y, width: max(200, page.bounds.width - 344), height: 18)
        val.autoresizingMask = [.minYMargin, .width]
        val.lineBreakMode = .byTruncatingTail
        page.addSubview(val)
        return val
    }

    /// Refresh the format / conditioning / HighExciter rows of the Diagnostics
    /// panel from main-cached state. Safe to call before the page is built and
    /// before the engine starts. Counters + device identity are filled by
    /// updateDiagnostics (1 Hz); this handles the notification-driven rows.
    private func refreshDiagnosticsPanel() {
        // Refresh all output labels even when Diagnostics was never opened.
        refreshToneReceiptPresentation()
        updateOutputConditioningStatus()
        guard diagTapValue != nil else { return }
        diagTapValue.stringValue = formatDiagRate(currentTapSampleRate)
        diagEngineValue.stringValue = formatDiagRate(currentProcessingSampleRate)
        diagDeviceValue.stringValue = formatDiagRate(currentDeviceSampleRate)
        diagFormatValue.stringValue =
            currentProcessingSampleRate == nil ? "—" : currentOutputSampleFormat

        // Separate the selected offline options from the actual live state.
        let isPCM2xArmed = outputConditioningEnabled
            && OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling
            && outputConditioningFactor == 2
        // A fallback reason only applies to the 2×-armed path; if the user has
        // since switched to a non-2× selection, drop the stale reason so it does
        // not linger on the panel.
        if !isPCM2xArmed, !currentLivePCM2xFallback.isEmpty {
            currentLivePCM2xFallback = ""
        }
        let conditioningText: String
        if currentStopFailure != nil {
            conditioningText = L10n.string("main.state.stopFailed")
        } else if currentProcessingFailure != nil {
            conditioningText = L10n.string("main.state.processingFailed")
        } else if !outputConditioningEnabled {
            conditioningText = "Off"
        } else if currentLivePCM2xActive {
            conditioningText = "PCM 2× active"
        } else if !currentLivePCM2xFallback.isEmpty {
            conditioningText = L10n.string("main.state.notApplied")
        } else {
            conditioningText = isPCM2xArmed ? L10n.string("main.state.pcm2xPending") : L10n.string("main.state.bypass")
        }
        diagConditioningValue.stringValue = conditioningText
        let reason = currentStopFailure ?? currentProcessingFailure ?? currentLivePCM2xFallback
        let hasFallback = !reason.isEmpty
        diagFallbackValue.stringValue = hasFallback ? reason : "—"
        diagFallbackValue.textColor = hasFallback
            ? GlassDesign.secondary
            : GlassDesign.secondary

        diagHighExciterValue.stringValue = highExciterDiagnosticsText()
    }

    /// HighExciter resolved oversampling mode (1× / 2× / 4× / safety-limited),
    /// computed from the cached engine sample rate + the selected oversampling
    /// mode via the same pure policy used by updateOversamplingIndicator.
    private func highExciterDiagnosticsText() -> String {
        guard selectedDSPModel() == .highExciter else { return "—" }
        guard let sampleRate = currentTapSampleRate else { return L10n.string("main.diag.highExciter.waiting") }
        let resolution = ExciterOversamplingPolicy.resolve(
            processingSampleRate: sampleRate,
            mode: exciterOversamplingMode
        )
        let internalText = formatDiagRate(resolution.internalSampleRate)
        if resolution.isSafetyLimited {
            return L10n.format("main.diag.highExciter.safety", String(describing: resolution.requestedFactor), String(describing: resolution.effectiveFactor), String(describing: internalText))
        }
        return "\(resolution.effectiveFactor)× (\(internalText))"
    }

    private func formatDiagRate(_ rate: Double?) -> String {
        AudioFormatStatus.rateText(rate)
    }

    /// Single source for the XRun row format (underrun / drop / analysis-drop),
    /// shared by updateDiagnostics (live) and stopAudio (zero reset) so the two
    /// cannot drift.
    private func formatXRunCounts(underrun: UInt64, drop: UInt64, vis: UInt64) -> String {
        "\(underrun) / \(drop) / \(vis)"
    }

    private func makeConditioningCaption(_ text: String, y: CGFloat) -> NSTextField {
        let label = makeLabel(text, size: 12, weight: .semibold)
        label.frame = NSRect(x: 24, y: y, width: 260, height: 20)
        label.autoresizingMask = [.minYMargin]
        return label
    }

    private func makeConditioningPopup(titles: [String], action: Selector, y: CGFloat) -> NSPopUpButton {
        let width = max(220, (pageContainerView?.bounds.width ?? 620) - 48)
        let popup = StudioPopUpButton(frame: NSRect(x: 24, y: y, width: width, height: 26), pullsDown: false)
        popup.autoresizingMask = [.minYMargin, .width]
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = action
        return popup
    }

    private func selectConditioningPopup(_ popup: NSPopUpButton, forRaw raw: UInt32, in rawValues: [UInt32]) {
        if let index = rawValues.firstIndex(of: raw) {
            popup.selectItem(at: index)
        }
    }

    private func applyOutputConditioningControlEnabledState() {
        outputRateModePopup?.isEnabled = pendingAudioOperation == nil
        outputConditioningFilterPopup?.isEnabled = outputConditioningEnabled && pendingAudioOperation == nil
        refreshOutputConditioningHeadroomState()
    }

    private var outputGainStateText: String {
        let requests2x = outputConditioningEnabled
            && OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling
            && outputConditioningFactor == 2
        let failed = !currentLivePCM2xActive && !currentLivePCM2xFallback.isEmpty
        let state: String
        if pendingAudioOperation != nil {
            state = L10n.string("main.output.state.pendingOperation")
        } else if currentStopFailure != nil {
            state = L10n.string("main.output.state.stopFailed")
        } else if currentProcessingFailure != nil {
            state = L10n.string("main.output.state.processingFailed")
        } else if currentLivePCM2xActive && !requests2x {
            state = L10n.string("main.output.state.release2x")
        } else if !outputConditioningEnabled {
            state = L10n.string("main.output.state.off")
        } else if !requests2x {
            state = L10n.string("main.detail.05cdaf26c6")
        } else if currentLivePCM2xActive {
            state = L10n.string("main.output.state.active")
        } else if failed {
            state = L10n.string("main.output.state.failed")
        } else {
            state = L10n.string("main.output.state.armed")
        }
        return state
    }

    private func refreshOutputConditioningHeadroomState() {
        guard let slider = outputConditioningHeadroomSlider else { return }
        let requests2x = outputConditioningEnabled
            && OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling
            && outputConditioningFactor == 2
        if !requests2x { currentLivePCM2xFallback = "" }
        let failed = !currentLivePCM2xActive && !currentLivePCM2xFallback.isEmpty
        // The requested gain remains editable for the next successful run.
        // Editing an inactive route saves it without retrying a device transition.
        slider.isEnabled = outputConditioningEnabled
        let state = outputGainStateText
        outputConditioningHeadroomCaption?.stringValue = L10n.format("main.detail.66cab52f8e", String(describing: state))
        // The number is the requested setting, not a callback acknowledgement.
        let detail = L10n.format("main.detail.ad04b97380", String(describing: state), String(describing: formatDbText(outputConditioningHeadroomDB)))
        slider.toolTip = detail
        outputConditioningHeadroomValueLabel?.toolTip = detail
        outputConditioningHeadroomCaption?.toolTip = failed ? currentLivePCM2xFallback : detail
        let failure = currentStopFailure ?? currentProcessingFailure
        if pendingAudioOperation != nil {
            outputConditioningRuntimeLabel?.stringValue = L10n.string("main.output.runtime.pending")
            outputConditioningRuntimeLabel?.toolTip = nil
        } else if let failure {
            outputConditioningRuntimeLabel?.stringValue = L10n.string("main.detail.c4261b4bf6")
            outputConditioningRuntimeLabel?.toolTip = failure
        } else if failed {
            outputConditioningRuntimeLabel?.stringValue = L10n.string("main.detail.1b6ec0e8ef")
            outputConditioningRuntimeLabel?.toolTip = currentLivePCM2xFallback
        } else {
            outputConditioningRuntimeLabel?.stringValue = ""
            outputConditioningRuntimeLabel?.toolTip = nil
        }
    }

    @objc private func outputConditioningEnableChanged() {
        outputConditioningEnabled = outputConditioningEnableButton.state == .on
        preferenceStore.set(outputConditioningEnabled, forKey: "outputConditioningEnabled")
        applyOutputConditioningControlEnabledState()
        updateOutputConditioningStatus()
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningModeChanged() {
        let index = outputConditioningModePopup.indexOfSelectedItem
        let mode = OutputConditioningMode.allCases[safe: index] ?? .bypass
        outputConditioningModeRaw = mode.rawValue
        preferenceStore.set(Int(mode.rawValue), forKey: "outputConditioningMode")
        updateOutputConditioningStatus()
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningFactorChanged() {
        let index = outputConditioningFactorPopup.indexOfSelectedItem
        let factor = OutputConditioningParameters.allowedOversamplingFactors[safe: index] ?? 2
        outputConditioningFactor = factor
        preferenceStore.set(factor, forKey: "outputConditioningFactor")
        updateOutputConditioningStatus()
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningFilterChanged() {
        let index = outputConditioningFilterPopup.indexOfSelectedItem
        let mode = ResamplingFilterMode.allCases[safe: index] ?? .linearPhaseShort
        outputConditioningFilterRaw = mode.rawValue
        preferenceStore.set(Int(mode.rawValue), forKey: "outputConditioningFilter")
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningHeadroomChanged() {
        outputConditioningHeadroomDB = Double(outputConditioningHeadroomSlider.doubleValue)
        pendingHeadroomEdit = true
        preferenceStore.set(outputConditioningHeadroomDB, forKey: "outputConditioningHeadroomDB")
        outputConditioningHeadroomValueLabel.stringValue = formatDbText(outputConditioningHeadroomDB)
        updateOutputConditioningStatus()
        if currentLivePCM2xActive { pushActiveHeadroomSettings() }
    }

    @objc private func outputConditioningDitherChanged() {
        outputConditioningDither = outputConditioningDitherButton.state == .on
        preferenceStore.set(outputConditioningDither, forKey: "outputConditioningDither")
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningNoiseShapeChanged() {
        outputConditioningNoiseShape = outputConditioningNoiseShapeButton.state == .on
        preferenceStore.set(outputConditioningNoiseShape, forKey: "outputConditioningNoiseShape")
        pushOutputConditioningSettings()
    }

    @objc private func outputConditioningDSDChanged() {
        let index = outputConditioningDSDPopup.indexOfSelectedItem
        let mode = DSDMode.allCases[safe: index] ?? .off
        outputConditioningDSDRaw = mode.rawValue
        preferenceStore.set(Int(mode.rawValue), forKey: "outputConditioningDSD")
        // The unsupported-mode warning depends on the selected mode, so refresh it.
        updateOutputConditioningStatus()
        pushOutputConditioningSettings()
    }

    private func currentOutputConditioningParameters() -> OutputConditioningParameters {
        var params = OutputConditioningParameters()
        params.isEnabled = outputConditioningEnabled
        params.outputMode = OutputConditioningMode(rawValue: outputConditioningModeRaw) ?? .bypass
        params.oversamplingFactor = outputConditioningFactor
        params.filterMode = ResamplingFilterMode(rawValue: outputConditioningFilterRaw) ?? .linearPhaseShort
        params.headroomDB = Float(outputConditioningHeadroomDB)
        params.ditherEnabled = outputConditioningDither
        params.noiseShapingEnabled = outputConditioningNoiseShape
        params.dsdMode = DSDMode(rawValue: outputConditioningDSDRaw) ?? .off
        return params
    }

    private func pushOutputConditioningSettings() {
        guard pendingAudioOperation == nil, currentStopFailure == nil, currentProcessingFailure == nil, let processor else { return }
        pendingHeadroomEdit = false
        processor.updateOutputConditioning(currentOutputConditioningParameters())
    }

    private func pushActiveHeadroomSettings() {
        guard pendingAudioOperation == nil, currentStopFailure == nil, currentProcessingFailure == nil, let processor else { return }
        let parameters = currentOutputConditioningParameters()
        guard parameters.isEnabled, parameters.outputMode == .pcmOversampling,
              parameters.oversamplingFactor == 2 else { return }
        pendingHeadroomEdit = false
        processor.updateActiveLivePCM2xParameters(parameters)
    }

    private func refreshOutputConditioningCapability() {
        outputConditioningCapability = OutputConditioningCapabilityQuery.queryDefaultOutput()
        if isViewLoadedConditioningPage() {
            updateOutputConditioningStatus()
        }
    }

    private func isViewLoadedConditioningPage() -> Bool { outputRateModePopup != nil }

    private func updateOutputConditioningStatus() {
        applyOutputConditioningControlEnabledState()
        guard let label = outputConditioningStatusLabel else { return }
        if let failure = currentStopFailure {
            label.stringValue = L10n.format("main.status.stopIncomplete", failure)
        } else if let failure = currentProcessingFailure {
            label.stringValue = L10n.format("main.status.startFailed", failure)
        } else if pendingAudioOperation != nil {
            label.stringValue = L10n.string("main.output.state.pendingOperation")
        } else if currentLivePCM2xActive {
            label.stringValue = L10n.format("main.output.state.activeRates", Self.rateText(currentTapSampleRate ?? 0), Self.rateText(currentProcessingSampleRate ?? 0))
        } else if outputRateMode == .upsample2x, !currentLivePCM2xFallback.isEmpty {
            label.stringValue = L10n.format("main.output.state.unavailableReason", currentLivePCM2xFallback)
        } else if outputRateMode == .upsample2x, let capability = outputConditioningCapability,
                  !(capability.canAttemptLivePCM2x(tapRate: currentTapSampleRate ?? 44_100)
                    || (currentTapSampleRate == nil && capability.canAttemptLivePCM2x(tapRate: 48_000))) {
            label.stringValue = L10n.string("main.output.capability.unsupportedDevice")
        } else {
            label.stringValue = outputRateMode == .matchSource ? rateMatchStatusText : L10n.string("main.status.ready")
        }
        label.toolTip = label.stringValue
        let noticePending = preferenceStore.bool(forKey: RedesignPreferences.Keys.noticePending)
        outputMigrationNoticeLabel?.stringValue = noticePending ? L10n.string("main.output.notice.migrated") : ""
        outputMigrationNoticeLabel?.isHidden = !noticePending
        outputMigrationDismissButton?.isHidden = !noticePending
        refreshOutputGainNote()
    }

    @objc private func dismissOutputMigrationNotice() {
        preferenceStore.set(false, forKey: RedesignPreferences.Keys.noticePending)
        updateOutputConditioningStatus()
        layoutOutputConditioningPage()
    }



    private static func rateText(_ sampleRate: Double) -> String {
        sampleRate >= 1000
            ? String(format: "%.1f kHz", sampleRate / 1000)
            : String(format: "%.0f Hz", sampleRate)
    }

    private func layoutModelPage() {
        guard let page = modelDocument, let modelScroll else { return }
        page.setFrameSize(NSSize(width: modelScroll.contentSize.width, height: max(552, modelScroll.contentSize.height)))
        let width = page.bounds.width
        let isOff = selectedDSPModel() == .clean
        let inset: CGFloat = 28
        let contentWidth = width - inset * 2
        modelSelector.frame = NSRect(x: inset, y: 80, width: contentWidth, height: 44)
        page.viewWithTag(9801)?.frame = NSRect(x: width - inset - 28, y: 28, width: 28, height: 28)
        modelExplanationView.frame = .zero
        modelControlsView.frame = NSRect(x: inset, y: 148, width: contentWidth, height: 248)
        page.viewWithTag(9802)?.frame = NSRect(x: inset, y: 420, width: contentWidth, height: 18)
        modelPresetsView.frame = NSRect(x: inset, y: 446, width: contentWidth, height: 38)
        toneReceiptLabel.frame = NSRect(x: inset, y: 504, width: contentWidth, height: 34)
        modelPresetsView.isHidden = isOff
        page.viewWithTag(9802)?.isHidden = isOff
        if isOff { toneReceiptLabel.frame.origin.y = 420 }
        for view in [intensityNameLabel, bodyNameLabel, intensityValueLabel, bodyValueLabel, intensitySlider, bodySlider,
                     modelControlsView.viewWithTag(9810), modelControlsView.viewWithTag(9811)] { view?.isHidden = isOff }
        if let bypass = modelControlsView.viewWithTag(9814) {
            bypass.isHidden = !isOff; bypass.frame = modelControlsView.bounds
            bypass.subviews[0].frame = NSRect(x: (contentWidth - 40) / 2, y: 146, width: 40, height: 40)
            bypass.subviews[1].frame = NSRect(x: 24, y: 98, width: contentWidth - 48, height: 30)
            bypass.subviews[2].frame = NSRect(x: (contentWidth - 28) / 2, y: 52, width: 28, height: 28)
        }
        let cardWidth = (contentWidth - 16) / 2
        for (index, controls) in [(intensityNameLabel!, intensityValueLabel!, intensitySlider!),
                                  (bodyNameLabel!, bodyValueLabel!, bodySlider!)].enumerated() {
            let x = CGFloat(index) * (cardWidth + 16)
            modelControlsView.viewWithTag(9810 + index)?.frame = NSRect(x: x, y: 100, width: cardWidth, height: 148)
            controls.0.frame = NSRect(x: x + 22, y: 210, width: cardWidth - 44, height: 20)
            controls.1.frame = NSRect(x: x + 22, y: 156, width: cardWidth - 44, height: 44)
            controls.2.frame = NSRect(x: x + 22, y: 118, width: cardWidth - 44, height: 26)
        }
        modelControlsView.viewWithTag(9812)?.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 84)
        outputNameLabel.frame = NSRect(x: 22, y: 52, width: contentWidth - 164, height: 20)
        outputValueLabel.frame = NSRect(x: contentWidth - 142, y: 47, width: 120, height: 30)
        outputSlider.frame = NSRect(x: 22, y: 14, width: contentWidth - 44, height: 26)
        // The label has its own line; it never competes with Auto / 1× / 2× / 4×.
        oversamplingModeLabel.frame = NSRect(x: 22, y: 54, width: contentWidth - 72, height: 20)
        oversamplingModeControl.frame = NSRect(x: 18, y: 8, width: min(360, contentWidth - 36), height: 36)
        modelControlsView.viewWithTag(9813)?.frame = NSRect(x: contentWidth - 50, y: 48, width: 28, height: 28)
        let presetWidth = (contentWidth - 8 * 4) / 5
        for (index, button) in presetButtons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * (presetWidth + 8), y: 0, width: presetWidth, height: 38)
        }
        for view in modelControlsView.subviews { view.autoresizingMask = [] }
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = GlassDesign.ink
        return label
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = StudioButton(title: title, target: self, action: action)
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        return button
    }

    private func makeExplanationSection() -> NSView {
        let view = MonochromeSurface(frame: NSRect(x: 0, y: 0, width: 520, height: 78), radius: 18)
        view.wantsLayer = true

        let lines = [
            L10n.string("main.detail.5224898d4f"),
            L10n.string("main.detail.c5653f1038"),
            L10n.string("main.detail.9dc3b9005a")
        ]

        for (index, line) in lines.enumerated() {
            let label = makeLabel(line, size: 12.5, weight: index == 0 ? .semibold : .regular)
            label.frame = NSRect(x: 18, y: 48.0 - CGFloat(index) * 22.0, width: 484, height: 20)
            label.autoresizingMask = [.width]
            label.lineBreakMode = .byTruncatingTail
            view.addSubview(label)
        }

        return view
    }

    private func makeControlSection() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 248))
        for index in 0..<3 {
            let well = MonochromeSurface(frame: .zero, radius: 14, well: true)
            well.tag = 9810 + index; view.addSubview(well)
        }
        view.wantsLayer = true

        let bypass = MonochromeSurface(frame: .zero, radius: 14, well: true)
        bypass.tag = 9814
        let bypassImage = NSImageView(image: NSImage(systemSymbolName: "waveform.slash", accessibilityDescription: nil) ?? NSImage())
        bypassImage.contentTintColor = .secondaryLabelColor
        let bypassTitle = makeLabel(L10n.string("main.sound.offTitle"), size: 20, weight: .medium)
        bypassTitle.alignment = .center
        let bypassHelp = GlassHelpButton(L10n.string("main.sound.offHelp"), context: L10n.string("main.sound.offTitle"))
        bypass.addSubview(bypassImage); bypass.addSubview(bypassTitle); bypass.addSubview(bypassHelp)
        view.addSubview(bypass)

        intensitySlider = makeSlider(value: 55, min: 0, max: 100)
        bodySlider = makeSlider(value: 30, min: 0, max: 100)
        outputSlider = makeSlider(value: -1.5, min: -18, max: 6)

        applySliderValues(loadSliderValues(for: selectedDSPModel()))

        intensityValueLabel = makeLabel("", size: 13, weight: .semibold)
        bodyValueLabel = makeLabel("", size: 13, weight: .semibold)
        outputValueLabel = makeLabel("", size: 13, weight: .semibold)

        intensityNameLabel = addSliderRow(to: view, y: 86, title: "LowEnd", slider: intensitySlider, valueLabel: intensityValueLabel)
        bodyNameLabel = addSliderRow(to: view, y: 48, title: "Body", slider: bodySlider, valueLabel: bodyValueLabel)
        outputNameLabel = addSliderRow(to: view, y: 10, title: "Output", slider: outputSlider, valueLabel: outputValueLabel)

        oversamplingModeLabel = makeLabel(L10n.string("main.sound.oversampling"), size: 13, weight: .semibold)
        oversamplingModeLabel.frame = NSRect(x: 16, y: 10, width: 100, height: 24)
        oversamplingModeControl = StudioSegmentedControl(
            labels: ExciterOversamplingMode.allCases.map(\.title),
            trackingMode: .selectOne,
            target: self,
            action: #selector(oversamplingModeChanged)
        )
        oversamplingModeControl.focusRingType = .none
        oversamplingModeControl.frame = NSRect(x: 120, y: 7, width: 310, height: 28)
        oversamplingModeControl.autoresizingMask = [.width]
        oversamplingModeControl.selectedSegment = segmentIndex(for: exciterOversamplingMode)
        oversamplingModeControl.toolTip = L10n.string("main.detail.7d5886ba07")
        view.addSubview(oversamplingModeLabel)
        view.addSubview(oversamplingModeControl)
        let help = GlassHelpButton(L10n.string("main.detail.7d5886ba07"), context: L10n.string("main.sound.oversampling"))
        help.tag = 9813; view.addSubview(help)
        intensityValueLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        bodyValueLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .medium)
        outputValueLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        outputValueLabel.alignment = .right
        configureControlsForSelectedModel()
        return view
    }

    private func makePresetSection() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 38))
        presetButtons = [
            makeButton("IEM", action: #selector(applyIEMPreset)),
            makeButton("Gentle", action: #selector(applyGentlePreset)),
            makeButton("LowEnd", action: #selector(applyLowEndPreset)),
            makeButton("Deep", action: #selector(applyDeepPreset)),
            makeButton("Clear", action: #selector(applyClearPreset))
        ]

        let gap: CGFloat = 10
        let width = (520.0 - gap * 4) / 5
        for index in 0..<presetButtons.count {
            presetButtons[index].frame = NSRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: 36)
            view.addSubview(presetButtons[index])
        }
        configurePresetButtons()

        return view
    }

    private func makeSlider(value: Double, min: Double, max: Double) -> NSSlider {
        let slider = NSSlider(value: value, minValue: min, maxValue: max, target: self, action: #selector(sliderChanged))
        slider.isContinuous = true
        slider.trackFillColor = .labelColor
        return slider
    }

    @discardableResult
    private func addSliderRow(to view: NSView, y: CGFloat, title: String, slider: NSSlider, valueLabel: NSTextField) -> NSTextField {
        let label = makeLabel(title, size: 13, weight: .semibold)
        label.frame = NSRect(x: 18, y: y, width: 96, height: 24)
        slider.frame = NSRect(x: 120, y: y, width: 300, height: 24)
        slider.autoresizingMask = [.width]
        valueLabel.frame = NSRect(x: 430, y: y, width: 72, height: 24)
        valueLabel.autoresizingMask = [.minXMargin]
        view.addSubview(label)
        view.addSubview(slider)
        view.addSubview(valueLabel)
        return label
    }

    private func refreshToneReceiptPresentation() {
        guard let label = toneReceiptLabel else { return }
        guard pendingAudioOperation == nil, currentStopFailure == nil, currentProcessingFailure == nil,
              let processor else {
            label.stringValue = L10n.string("main.sound.receipt.inactive"); return
        }
        guard let receipt = processor.receivedTone, receipt.model == selectedDSPModel(),
              abs(receipt.intensity - (intensitySlider?.doubleValue ?? 0)) <= 0.011,
              abs(receipt.body - (bodySlider?.doubleValue ?? 0)) <= 0.011 else {
            label.stringValue = L10n.string("main.sound.receipt.pending"); return
        }
        label.stringValue = L10n.format("main.sound.receipt.received", receipt.model.displayName, receipt.intensity, receipt.body)
        label.toolTip = L10n.string("main.sound.receipt.help")
    }

    @objc private func sliderChanged() {
        updateSliderLabels()
        updateOversamplingIndicator()
        refreshToneReceiptPresentation()
        let model = selectedDSPModel()
        if model != .clean {
            saveSliderValues(
                SliderValues(
                    intensity: intensitySlider.doubleValue,
                    body: bodySlider.doubleValue,
                    outputDb: outputSlider.doubleValue
                ),
                for: model
            )
        }
        guard pendingAudioOperation == nil else { return }
        processor?.updateDSP(intensity: Float(intensitySlider.doubleValue),
                             body: Float(bodySlider.doubleValue),
                             outputDb: Float(outputSlider.doubleValue),
                             dspModel: model,
                             exciterOversamplingMode: exciterOversamplingMode)
    }

    @objc private func oversamplingModeChanged() {
        let modes = ExciterOversamplingMode.allCases
        let index = oversamplingModeControl.selectedSegment
        guard modes.indices.contains(index) else { return }
        exciterOversamplingMode = modes[index]
        preferenceStore.set(
            Int(exciterOversamplingMode.rawValue),
            forKey: "exciterOversamplingMode"
        )
        sliderChanged()
    }

    @objc private func automaticRateMatchChanged() {
        automaticRateMatchingEnabled = automaticRateMatchButton.state == .on
        preferenceStore.set(
            automaticRateMatchingEnabled,
            forKey: "automaticRateMatchingEnabled"
        )
        rateMatchStatusText = automaticRateMatchingEnabled ? L10n.string("runtime.rate.waiting") : L10n.string("runtime.rate.off")
        updateRateMatchPreview()
        if pendingAudioOperation == nil && currentStopFailure == nil {
            processor?.setAutomaticRateMatchingEnabled(automaticRateMatchingEnabled)
        }
    }

    @objc private func expertModeChanged() {
        expertModeEnabled = expertModeButton.state == .on
        preferenceStore.set(expertModeEnabled, forKey: "expertModeEnabled")
        // "자세히 보기" only toggles the detailed format header; 자동 Rate Match is
        // independent and stays available regardless of this setting.
        updateFormatHeaderMode()
        layoutApplication()
    }

    @objc private func modelChanged() {
        let model = selectedDSPModel()
        preferenceStore.set(modelSelector.selectedSegment, forKey: "selectedModel")
        preferenceStore.set(model.rawValue, forKey: "selectedModelID")
        applySliderValues(loadSliderValues(for: model))
        configureControlsForSelectedModel()
        sliderChanged()
        updateCompactFormatSummary()
        statusLabel.stringValue = currentProcessingFailure == nil
            ? L10n.format("main.detail.96a754696e", String(describing: model.displayName))
            : L10n.format("main.detail.71a627f296", String(describing: model.displayName))
        refreshAudioOperationPresentation()
        layoutModelPage()
    }

    private func configureControlsForSelectedModel() {
        guard intensitySlider != nil,
              bodySlider != nil,
              outputSlider != nil,
              intensityNameLabel != nil,
              bodyNameLabel != nil,
              outputNameLabel != nil else { return }

        switch selectedDSPModel() {
        case .clean:
            intensityNameLabel.stringValue = L10n.string("main.sound.value.bypass")
            bodyNameLabel.stringValue = L10n.string("main.sound.value.bypass")
            outputNameLabel.stringValue = L10n.string("main.sound.bass.trim")
            intensitySlider.isEnabled = false
            bodySlider.isEnabled = false
            outputSlider.isEnabled = false
            intensitySlider.toolTip = L10n.string("main.detail.17b8f25465")
            bodySlider.toolTip = L10n.string("main.detail.17b8f25465")
            outputSlider.toolTip = L10n.string("main.detail.eb88e941c9")
            setOversamplingControlsVisible(false)
        case .circuit:
            intensityNameLabel.stringValue = L10n.string("main.sound.bass.amount")
            bodyNameLabel.stringValue = L10n.string("main.sound.bass.fullness")
            outputNameLabel.stringValue = L10n.string("main.sound.bass.trim")
            intensitySlider.isEnabled = true
            bodySlider.isEnabled = true
            outputSlider.isEnabled = true
            intensitySlider.toolTip = L10n.string("main.sound.bass.amount.tooltip")
            bodySlider.toolTip = L10n.string("main.sound.bass.fullness.tooltip")
            outputSlider.toolTip = L10n.string("main.detail.0686783f85")
            setOversamplingControlsVisible(false)
        case .highExciter:
            intensityNameLabel.stringValue = L10n.string("main.sound.treble.drive")
            bodyNameLabel.stringValue = L10n.string("main.sound.treble.added")
            outputNameLabel.stringValue = L10n.string("main.sound.bass.trim")
            intensitySlider.isEnabled = true
            bodySlider.isEnabled = true
            outputSlider.isEnabled = false
            intensitySlider.toolTip = L10n.string("main.sound.treble.drive.tooltip")
            bodySlider.toolTip = L10n.string("main.detail.9028ce10ac")
            outputSlider.toolTip = L10n.string("main.detail.358d013f41")
            setOversamplingControlsVisible(true)
        }

        intensitySlider.setAccessibilityLabel(intensityNameLabel.stringValue)
        bodySlider.setAccessibilityLabel(bodyNameLabel.stringValue)
        outputSlider.setAccessibilityLabel(outputNameLabel.stringValue)
        configurePresetButtons()
        updateSliderLabels()
    }

    private func setOversamplingControlsVisible(_ isVisible: Bool) {
        oversamplingModeLabel?.isHidden = !isVisible || !expertModeEnabled
        oversamplingModeControl?.isHidden = !isVisible || !expertModeEnabled
        let hidesOutput = selectedDSPModel() != .circuit
        outputNameLabel?.isHidden = hidesOutput
        outputSlider?.isHidden = hidesOutput
        outputValueLabel?.isHidden = hidesOutput
        modelControlsView?.viewWithTag(9812)?.isHidden = hidesOutput && (!isVisible || !expertModeEnabled)
        modelControlsView?.viewWithTag(9813)?.isHidden = !isVisible || !expertModeEnabled
    }

    private func segmentIndex(for mode: ExciterOversamplingMode) -> Int {
        ExciterOversamplingMode.allCases.firstIndex(of: mode) ?? 0
    }

    private struct ModelPreset {
        let name: String
        let primary: Double
        let secondary: Double
        let outputDb: Double?
        let toolTip: String
    }

    private func presets(for model: Settings.DSPModel) -> [ModelPreset] {
        switch model {
        case .clean:
            return []
        case .circuit:
            return [
                ModelPreset(name: L10n.string("main.sound.preset.softBass"), primary: 30, secondary: 8, outputDb: -2.0,
                            toolTip: L10n.string("main.sound.preset.softBass.tooltip")),
                ModelPreset(name: L10n.string("main.sound.preset.lightBass"), primary: 22, secondary: 8, outputDb: -1.0,
                            toolTip: L10n.string("main.sound.preset.lightBass.tooltip")),
                ModelPreset(name: L10n.string("main.sound.preset.fullBass"), primary: 42, secondary: 18, outputDb: -1.8,
                            toolTip: L10n.string("main.sound.preset.fullBass.tooltip")),
                ModelPreset(name: L10n.string("main.sound.preset.deepBass"), primary: 54, secondary: 22, outputDb: -2.8,
                            toolTip: L10n.string("main.sound.preset.deepBass.tooltip")),
                ModelPreset(name: L10n.string("main.sound.preset.neutral"), primary: 0, secondary: 0, outputDb: 0,
                            toolTip: L10n.string("main.detail.7dac23f220"))
            ]
        case .highExciter:
            return [
                ModelPreset(name: L10n.string("main.sound.preset.subtle"), primary: 12, secondary: 4, outputDb: nil,
                            toolTip: L10n.string("main.sound.preset.subtle.tooltip")),
                ModelPreset(name: L10n.string("main.sound.preset.light"), primary: 22, secondary: 7, outputDb: nil,
                            toolTip: L10n.string("main.sound.preset.light.tooltip")),
                ModelPreset(name: L10n.string("main.sound.preset.medium"), primary: 35, secondary: 11, outputDb: nil,
                            toolTip: L10n.string("main.sound.preset.medium.tooltip")),
                ModelPreset(name: L10n.string("main.sound.preset.strong"), primary: 50, secondary: 16, outputDb: nil,
                            toolTip: L10n.string("main.sound.preset.strong.tooltip")),
                ModelPreset(name: L10n.string("main.sound.preset.off"), primary: 0, secondary: 0, outputDb: nil,
                            toolTip: L10n.string("main.detail.7cc2a70db8"))
            ]
        }
    }

    private func configurePresetButtons() {
        guard !presetButtons.isEmpty else { return }

        let model = selectedDSPModel()
        let modelPresets = presets(for: model)
        for index in 0..<presetButtons.count {
            let button = presetButtons[index]
            guard index < modelPresets.count else {
                button.title = "-"
                button.isEnabled = false
                button.toolTip = L10n.string("main.detail.3dad704241")
                continue
            }

            button.title = modelPresets[index].name
            button.state = .off
            button.isEnabled = true
            button.toolTip = modelPresets[index].toolTip
        }
    }

    private func updateSliderLabels() {
        let modelPresets = presets(for: selectedDSPModel())
        for (index, button) in presetButtons.enumerated() {
            guard modelPresets.indices.contains(index) else { button.state = .off; continue }
            let preset = modelPresets[index]
            let matches = abs(intensitySlider.doubleValue - preset.primary) < 0.01
                && abs(bodySlider.doubleValue - preset.secondary) < 0.01
                && (preset.outputDb == nil || abs(outputSlider.doubleValue - preset.outputDb!) < 0.01)
            button.state = matches ? .on : .off
        }
        switch selectedDSPModel() {
        case .clean:
            intensityValueLabel.stringValue = "Off"
            bodyValueLabel.stringValue = "Off"
            outputValueLabel.stringValue = L10n.string("main.sound.value.bypass")
        case .circuit:
            intensityValueLabel.stringValue = "\(Int(intensitySlider.doubleValue.rounded()))%"
            bodyValueLabel.stringValue = "\(Int(bodySlider.doubleValue.rounded()))%"
            outputValueLabel.stringValue = formatDbText(outputSlider.doubleValue)
        case .highExciter:
            intensityValueLabel.stringValue = String(format: "%.2f", intensitySlider.doubleValue / 100)
            bodyValueLabel.stringValue = String(format: "%.2f", bodySlider.doubleValue / 100)
            outputValueLabel.stringValue = L10n.string("main.sound.value.bypass")
        }
    }

    private func updateOversamplingIndicator() {
        guard oversamplingLabel != nil else { return }
        guard expertModeEnabled, selectedDSPModel() == .highExciter else {
            oversamplingLabel.isHidden = true
            return
        }

        oversamplingLabel.isHidden = false
        let driveActive = intensitySlider.doubleValue >= 0.01
        let wetActive = bodySlider.doubleValue >= 0.01
        guard driveActive && wetActive else {
            oversamplingLabel.stringValue = "HighExciter | Oversampling idle"
            oversamplingLabel.textColor = GlassDesign.secondary
            return
        }

        guard let sampleRate = currentTapSampleRate else {
            oversamplingLabel.stringValue = "HighExciter | Oversampling format waiting"
            oversamplingLabel.textColor = GlassDesign.secondary
            return
        }

        let resolution = ExciterOversamplingPolicy.resolve(
            processingSampleRate: sampleRate,
            mode: exciterOversamplingMode
        )
        oversamplingLabel.stringValue = ExciterOversamplingPolicy.indicator(resolution)
        oversamplingLabel.textColor = GlassDesign.secondary
    }

    private func updateFormatHeaderMode() {
        advancedSettingsView?.isHidden = !expertModeEnabled
        setOversamplingControlsVisible(selectedDSPModel() == .highExciter)
        updateOversamplingIndicator()
        layoutSettingsPage()
    }

    private func updateCompactFormatSummary() {
        guard compactSourceTitleLabel != nil else { return }

        if let playerName = currentSourcePlayerName {
            compactSourceTitleLabel.stringValue = L10n.format("main.detail.d7ef4ef64f", String(describing: playerName))
        } else {
            compactSourceTitleLabel.stringValue = L10n.string("main.format.sourceTitle")
        }

        if let sourceRate = currentSourceSampleRate {
            let depthText = currentSourceBitDepth.map { "\($0)-bit" } ?? L10n.string("main.detail.16562e0220")
            compactSourceValueLabel.stringValue = "\(formatSampleRate(sourceRate)) / \(depthText)"
        } else {
            compactSourceValueLabel.stringValue = L10n.string("main.format.sourceWaiting")
        }

        if let outputRate = currentDeviceSampleRate {
            compactOutputLabel.stringValue =
                L10n.format("main.detail.95befb4293", String(describing: formatSampleRate(outputRate)), String(describing: currentOutputSampleFormat))
        } else {
            compactOutputLabel.stringValue = L10n.string("main.format.outputWaiting")
        }
        compactModelLabel.stringValue = L10n.format("main.detail.ec880746c8", String(describing: selectedDSPModel().displayName))
    }

    private func formatSampleRate(_ sampleRate: Double) -> String {
        sampleRate >= 1_000
            ? String(format: "%.1f kHz", sampleRate / 1_000)
            : String(format: "%.0f Hz", sampleRate)
    }

    private func spatialSettingsFromControls() -> SpatialSettings {
        spatialControlModel.settings
    }

    private func updateSpatialControls(from settings: SpatialSettings, notifyProcessor: Bool) {
        spatialControlModel.update(settings)
        if notifyProcessor, pendingAudioOperation == nil, let processor {
            lastSpatialSubmissionRevision = processor.updateSpatial(spatialControlModel.settings)
            spatialControlModel.appliedStatusText = L10n.format("main.detail.da50097e05", String(describing: lastSpatialSubmissionRevision))
        } else if processor == nil {
            spatialControlModel.appliedStatusText = L10n.string("main.detail.3734a4ef34")
        }
    }

    @objc private func applyIEMPreset() {
        applyPreset(at: 0)
    }

    @objc private func applyGentlePreset() {
        applyPreset(at: 1)
    }

    @objc private func applyLowEndPreset() {
        applyPreset(at: 2)
    }

    @objc private func applyDeepPreset() {
        applyPreset(at: 3)
    }

    @objc private func applyClearPreset() {
        applyPreset(at: 4)
    }

    private func applyPreset(at index: Int) {
        let model = selectedDSPModel()
        let modelPresets = presets(for: model)
        guard model != .clean, index >= 0, index < modelPresets.count else { return }

        let preset = modelPresets[index]
        intensitySlider.doubleValue = preset.primary
        bodySlider.doubleValue = preset.secondary
        if model == .circuit, let outputDb = preset.outputDb {
            outputSlider.doubleValue = outputDb
        }
        sliderChanged()
        statusLabel.stringValue = L10n.format("main.sound.status.preset", String(describing: model.displayName), String(describing: preset.name))
        refreshAudioOperationPresentation()
    }

    @objc private func startAllAudio() {
        start(settings(for: .all))
    }

    @objc private func startSelectedApp() {
        let bundleID = bundleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            statusLabel.stringValue = L10n.string("main.status.noBundleID")
            return
        }

        start(settings(for: .bundleIDs([bundleID])))
    }

    private func settings(for mode: Settings.Mode) -> Settings {
        Settings(mode: mode,
                 intensity: Float(intensitySlider.doubleValue),
                 body: Float(bodySlider.doubleValue),
                 outputDb: Float(outputSlider.doubleValue),
                 dspModel: selectedDSPModel(),
                 exciterOversamplingMode: exciterOversamplingMode,
                 automaticRateMatchingEnabled: automaticRateMatchingEnabled,
                 spatial: spatialSettingsFromControls())
    }

    private func selectedDSPModel() -> Settings.DSPModel {
        guard let modelSelector else { return initialModel }
        switch modelSelector.selectedSegment {
        case 1:
            return .circuit
        case 2:
            return .highExciter
        default:
            return .clean
        }
    }

    private struct SliderValues: Codable {
        let intensity: Double
        let body: Double
        let outputDb: Double
    }

    private func defaultSliderValues(for model: Settings.DSPModel) -> SliderValues {
        switch model {
        case .clean: return SliderValues(intensity: 0, body: 0, outputDb: 0)
        case .circuit: return SliderValues(intensity: 55, body: 30, outputDb: -1.5)
        case .highExciter: return SliderValues(intensity: 12, body: 4, outputDb: 0)
        }
    }

    private func sliderValuesKey(for model: Settings.DSPModel) -> String {
        "sliders.\(model.rawValue)"
    }

    private func loadSliderValues(for model: Settings.DSPModel) -> SliderValues {
        let fallback = defaultSliderValues(for: model)
        guard let data = preferenceStore.data(forKey: sliderValuesKey(for: model)) else {
            return fallback
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(SliderValues.self, from: data)) ?? fallback
    }

    private func saveSliderValues(_ values: SliderValues, for model: Settings.DSPModel) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(values) {
            preferenceStore.set(data, forKey: sliderValuesKey(for: model))
        }
    }

    private func applySliderValues(_ values: SliderValues) {
        guard intensitySlider != nil,
              bodySlider != nil,
              outputSlider != nil else { return }
        intensitySlider.doubleValue = values.intensity
        bodySlider.doubleValue = values.body
        outputSlider.doubleValue = values.outputDb
    }

    private func start(_ settings: Settings) {
        if pendingAudioOperation == nil {
            switch settings.mode {
            case .all: pendingTarget = .system
            case .bundleIDs(let ids): pendingTarget = .app(bundleID: ids.first ?? "", name: nil)
            default: pendingTarget = nil
            }
        }
        guard pendingAudioOperation == nil else {
            refreshAudioOperationPresentation()
            return
        }
        let operation = PendingAudioOperation(phase: processor == nil ? .creating : .replacing)
        pendingAudioOperation = operation
        stopAnalysisPresentation()
        refreshAudioOperationPresentation()
        if let processor {
            stopOnLifecycleWorker(processor, token: operation.id, nextStart: settings)
        } else {
            clearStoppedAudioPresentation()
            createOnLifecycleWorker(settings, token: operation.id)
        }
    }

    private func createOnLifecycleWorker(_ settings: Settings, token: UUID) {
        guard pendingAudioOperation?.id == token else { return }
        if pendingAudioOperation?.stopRequested == true {
            completeAudioOperation(token: token)
            return
        }
        pendingAudioOperation?.phase = .creating
        refreshAudioOperationPresentation()
        let io = audioLifecycleIO
        audioLifecycleWorker.queue.async { [self] in
            let result = Result { try audioLifecycleWorker.make(settings, io: io) }
            DispatchQueue.main.async { [self] in
                guard pendingAudioOperation?.id == token else { return }
                switch result {
                case .failure(let error):
                    completeAudioOperation(token: token)
                    showAudioStartError(error)
                case .success(let created):
                    // Bind before Start can enqueue a format notification.
                    // The worker and this property both retain the same owner.
                    processor = created
                    if pendingAudioOperation?.stopRequested == true {
                        stopOnLifecycleWorker(created, token: token)
                    } else {
                        pendingAudioOperation?.phase = .starting
                        refreshAudioOperationPresentation()
                        let sessionID = created.notificationSessionID
                        audioLifecycleWorker.queue.async { [self] in
                            let result = Result { try io.start(created) }
                            DispatchQueue.main.async { [self] in
                                completeAudioStart(result, sessionID: sessionID, token: token)
                            }
                        }
                    }
                }
            }
        }
    }

    private func completeAudioStart(_ result: Result<Void, Error>, sessionID: String,
                                    token: UUID) {
        guard pendingAudioOperation?.id == token, let started = processor,
              started.notificationSessionID == sessionID else { return }
        switch result {
        case .failure(let error):
            if let failure = error as? AudioGraphTransitionFailure, !failure.recovered {
                // A failed cleanup is not retried by delayed completion, even
                // when a Stop/Quit was requested during the blocking call.
                pendingAudioOperation = nil
                handleAudioStartFailure(error)
                refreshAudioOperationPresentation()
                window?.makeKeyAndOrderFront(nil)
            } else {
                stopOnLifecycleWorker(started, token: token, startError: error)
            }
        case .success:
            if pendingAudioOperation?.stopRequested == true {
                stopOnLifecycleWorker(started, token: token)
                return
            }
            pendingAudioOperation = nil
            currentStopFailure = nil
            currentProcessingFailure = nil
            activeTarget = pendingTarget
            refreshHeaderPresentation()
            // UI edits were stored while Start was pending. Take the current
            // values here, never the snapshot from the earlier Apply click.
            let latest = settings(for: .all)
            started.updateDSP(intensity: latest.intensity, body: latest.body, outputDb: latest.outputDb,
                              dspModel: latest.dspModel, exciterOversamplingMode: latest.exciterOversamplingMode)
            lastSpatialSubmissionRevision = started.updateSpatial(latest.spatial)
            started.setAutomaticRateMatchingEnabled(automaticRateMatchingEnabled)
            pushOutputConditioningSettings()
            if let observation = lastSourceObservation { started.observeSourceFormats(observation.formats) }
            if let lastSourceSnapshot { updateSourceDisplay(lastSourceSnapshot) }
            let analyzer = started.makeSpectrumAnalyzer(dynamicsModel: dynamicsMeterModel, spectrumModel: spectrumModel)
            analyzer.start()
            spectrumAnalyzer = analyzer
            refreshAudioFlowPresentation()
            if lifecycleStartsDiagnosticsTimer { startDiagnosticsTimer() }
            refreshAudioOperationPresentation()
        }
    }

    private func requestStopAudio(quit: Bool = false) {
        if pendingAudioOperation != nil {
            pendingAudioOperation?.stopRequested = true
            if quit { pendingAudioOperation?.quitRequested = true }
            stopAnalysisPresentation()
            refreshAudioOperationPresentation()
            return
        }
        guard let processor else {
            clearStoppedAudioPresentation()
            return
        }
        var operation = PendingAudioOperation(phase: .stopping)
        operation.stopRequested = true
        operation.quitRequested = quit
        pendingAudioOperation = operation
        stopAnalysisPresentation()
        refreshAudioOperationPresentation()
        stopOnLifecycleWorker(processor, token: operation.id)
    }

    private func stopOnLifecycleWorker(_ stopping: SystemAudioProcessor, token: UUID,
                                       nextStart: Settings? = nil, startError: Error? = nil) {
        guard pendingAudioOperation?.id == token, processor === stopping else { return }
        pendingAudioOperation?.phase = nextStart == nil ? .stopping : .replacing
        refreshAudioOperationPresentation()
        let io = audioLifecycleIO
        let sessionID = stopping.notificationSessionID
        audioLifecycleWorker.queue.async { [self] in
            let stopped = io.stop(stopping)
            let failure = stopping.stopFailureDescription
            DispatchQueue.main.async { [self] in
                guard pendingAudioOperation?.id == token, processor?.notificationSessionID == sessionID else { return }
                if !stopped {
                    pendingAudioOperation = nil
                    showAudioStopFailure(failure)
                    refreshAudioOperationPresentation()
                    window?.makeKeyAndOrderFront(nil)
                    return
                }
                clearStoppedAudioPresentation()
                audioLifecycleWorker.retire(sessionID)
                if let nextStart, pendingAudioOperation?.stopRequested != true {
                    createOnLifecycleWorker(nextStart, token: token)
                } else {
                    completeAudioOperation(token: token)
                    if let startError { showAudioStartError(startError) }
                }
            }
        }
    }

    private func completeAudioOperation(token: UUID) {
        guard let operation = pendingAudioOperation, operation.id == token else { return }
        pendingAudioOperation = nil
        pendingTarget = nil
        refreshAudioOperationPresentation()
        if operation.quitRequested { finishRequestedQuit() }
    }

    private func refreshAudioOperationPresentation() {
        allSystemButton?.isEnabled = pendingAudioOperation == nil
        routingStartAppButton?.isEnabled = pendingAudioOperation == nil
        if let operation = pendingAudioOperation {
            let message: String
            if operation.stopRequested && operation.phase != .stopping {
                message = L10n.string("main.status.stopRequested")
            } else if operation.phase == .stopping || operation.phase == .replacing {
                message = L10n.string("main.status.stopping")
            } else {
                message = L10n.string("main.status.starting")
            }
            statusLabel?.stringValue = message
            statusLabel?.toolTip = L10n.string("main.status.operationTooltip")
            allSystemButton?.setAccessibilityLabel(message)
            allSystemButton?.toolTip = message
        } else {
            allSystemButton?.setAccessibilityLabel(L10n.string("main.detail.4ac9585a1d"))
            allSystemButton?.toolTip = L10n.string("main.status.applySystem.tooltip")
        }
        refreshAudioFlowPresentation()
        refreshToneReceiptPresentation()
        updateOutputConditioningStatus()
        headerStopButton?.isEnabled = processor != nil || pendingAudioOperation != nil
        outputRateModePopup?.isEnabled = pendingAudioOperation == nil
        refreshHeaderPresentation()
    }

    /// A successful Start owns a graph, but may still be waiting for its first
    /// audio data. Poll existing atomic counters without waiting for the manager.
    /// Failure and pending lifecycle messages always take precedence.
    private func refreshAudioFlowPresentation(_ snapshot: AudioDiagnosticsSnapshot? = nil) {
        if pendingAudioOperation != nil {
            diagAudioFlowValue?.stringValue = L10n.string("main.state.waitingDevice")
            diagAudioFlowValue?.toolTip = nil
            return
        }
        if currentStopFailure != nil || currentProcessingFailure != nil {
            diagAudioFlowValue?.stringValue = L10n.string("main.detail.17370156d9")
            diagAudioFlowValue?.toolTip = currentStopFailure ?? currentProcessingFailure
            return
        }
        guard let processor else {
            diagAudioFlowValue?.stringValue = "—"
            diagAudioFlowValue?.toolTip = nil
            return
        }
        let current = snapshot ?? processor.diagnosticsSnapshot()
        let flow = current.audioFlow
        let text = flow.isConfirmed ? L10n.format("main.state.processing", String(describing: current.captureTarget)) : flow.displayText
        if statusLabel?.stringValue != text { statusLabel?.stringValue = text }
        statusLabel?.toolTip = flow.isConfirmed ? nil : AudioFlowProgress.waitingHelp
        diagAudioFlowValue?.stringValue = flow.displayText
        diagAudioFlowValue?.toolTip = flow.isConfirmed ? nil : AudioFlowProgress.waitingHelp
    }

    private func showAudioStartError(_ error: Error) {
        statusLabel?.stringValue = L10n.format("main.status.startFailed", String(describing: error))
        if error is CaptureInstanceCompatibility.Conflict || error is CaptureSessionLease.Failure {
            let alert = NSAlert()
            alert.messageText = L10n.string("main.detail.12327a867f")
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.addButton(withTitle: L10n.string("runtime.capture.read"))
            alert.runModal()
        }
    }

    private func handleAudioStartFailure(_ error: Error) {
        let startError = L10n.format("main.status.startFailed", String(describing: error))
        if let failure = error as? AudioGraphTransitionFailure, !failure.recovered {
            // SAP already hit a failed teardown barrier. Preserve that graph
            // and its capture lease; the explicit Stop action owns retry.
            currentStopFailure = startError
            statusLabel?.stringValue = L10n.format("main.status.startFailedRetry", String(describing: startError))
            rateMatchStatusText = startError
            currentLivePCM2xFallback = startError
            refreshDiagnosticsPanel()
            updateRateMatchPreview()
        } else {
            requestStopAudio()
            statusLabel?.stringValue = startError
        }
        spectrumAnalyzer = nil
    }

    static func runCaptureSessionChecks() throws {
        try CaptureSessionChecks.run { processor in
            let owner = NativeAppDelegate()
            owner.processor = processor
            return CaptureStartFailureCheckObserver(
                handle: { owner.handleAudioStartFailure($0) },
                retainsProcessor: { owner.processor === processor },
                hasPendingFailure: { owner.currentStopFailure != nil },
                stop: { owner.stopAndWaitForCheck() })
        }
    }

    /// Actual AppKit controls and resize/state refreshes, without starting audio,
    /// showing a window or writing the user's saved settings.
    static func runRedesignWindowChecks() throws {
        let suite = "timbredock.window.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let owner = NativeAppDelegate(); owner.preferenceStore = preferences
        owner.buildWindow(showWindow: false)
        defer { owner.window.orderOut(nil) }
        var assertions = 0
        func require(_ condition: Bool, _ message: String) throws {
            assertions += 1
            if !condition { throw AppError.message("Redesign window: \(message)") }
        }
        try require(owner.draftTarget == .system && owner.activeTarget == nil, "fresh target is System Audio, unapplied")
        let apps = [DiscoveredAudioApp(name: "Same Name", bundleID: "test.first", pid: 1),
                    DiscoveredAudioApp(name: "Same Name", bundleID: "test.second", pid: 2),
                    DiscoveredAudioApp(name: "Third", bundleID: "test.third", pid: 3)]
        owner.rebuildHeaderTargetMenu(discoveredApps: apps)
        try require(owner.headerTargetPopup.numberOfItems == 5, "duplicate app titles retain all menu entries")
        for (index, app) in apps.enumerated() {
            owner.headerTargetPopup.selectItem(at: index + 2); owner.headerTargetChanged()
            try require(owner.draftTarget.bundleID == app.bundleID, "visible app maps to correct bundle ID")
            try require(owner.activeTarget == nil && owner.pendingAudioOperation == nil && owner.processor == nil,
                        "draft selection does not create or change an audio session")
        }
        owner.activeTarget = .system
        owner.setDraftTarget(.app(bundleID: "test.next", name: "Next"))
        try require(owner.activeTarget == .system, "editing draft preserves active target")
        let before = preferences.dictionaryRepresentation()
        owner.expertModeButton.state = .on; owner.expertModeChanged()
        owner.expertModeButton.state = .off; owner.expertModeChanged()
        for (key, value) in before where key != "expertModeEnabled" {
            try require(NSDictionary(dictionary: [key: value]).isEqual(to: [key: preferences.object(forKey: key)!]),
                        "Advanced must preserve setting \(key)")
        }
        let language = AppLanguage.current
        owner.languagePopup.selectItem(at: 1)
        try require(owner.languagePopup.sendAction(owner.languagePopup.action, to: owner.languagePopup.target), "actual language menu action dispatches")
        try require(owner.languageStatusLabel.stringValue.contains("한국어"), "language status confirms selected language")
        try require(preferences.string(forKey: AppLanguage.preferenceKey) == "ko" && AppLanguage.current == language,
                    "language is saved for next launch without mutating this session")
        for size in [NSSize(width: 940, height: 640), NSSize(width: 1080, height: 700)] {
            owner.window.setFrame(NSRect(origin: owner.window.frame.origin, size: size), display: false)
            owner.layoutApplication()
            owner.window.contentView?.layoutSubtreeIfNeeded()
            for page in AppPage.allCases {
                owner.selectedPage = page; owner.updateSelectedPage()
                try require(owner.pageViews.filter { !$0.value.isHidden }.count == 1, "only selected page visible")
                try require(owner.headerView.frame.minY >= owner.pageHostView.frame.maxY, "common header does not overlap page")
            }
            for control in [owner.headerTargetPopup!, owner.headerChooseButton!, owner.headerClearButton!,
                            owner.headerApplyButton!, owner.headerStopButton!] as [NSView] {
                try require(owner.headerView.bounds.contains(control.frame), "header controls fit minimum width")
            }
            try require(owner.modelPresetsView.frame.minY >= 0, "presets fit minimum height")
            let controls = [owner.headerTargetPopup!, owner.headerChooseButton!, owner.headerClearButton!,
                            owner.headerApplyButton!, owner.headerStopButton!] as [NSView]
            for pair in zip(controls, controls.dropFirst()) {
                try require(pair.0.frame.maxX <= pair.1.frame.minX, "header controls do not overlap")
            }
            try require(owner.modelExplanationView.frame.minY >= 0, "Sound explanation fits minimum height")
            owner.expertModeButton.state = .on; owner.expertModeChanged()
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            for case let caption as NSTextField in descendants(owner.advancedSettingsView) where caption.tag == 9970 {
                let measured = (caption.stringValue as NSString).size(withAttributes: [.font: caption.font!]).width
                try require(measured <= caption.frame.width, "diagnostic caption fits: \(caption.stringValue)")
            }
            for segment in 0..<3 {
                owner.modelSelector.selectedSegment = segment; owner.modelChanged()
                owner.layoutModelPage()
                for label in [owner.intensityNameLabel!, owner.bodyNameLabel!, owner.oversamplingModeLabel!] where !label.isHidden {
                    let measured = (label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width
                    try require(measured <= label.frame.width, "full control label fits: \(label.stringValue)")
                }
                try require(!owner.oversamplingModeLabel.frame.intersects(owner.oversamplingModeControl.frame),
                            "oversampling title and options occupy separate rows")
                for button in owner.presetButtons where button.isEnabled {
                    let measured = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
                    try require(measured + 20 <= button.frame.width, "preset title fits: \(button.title)")
                }
                try require(owner.modelDocument.bounds.contains(owner.modelPresetsView.frame), "presets remain reachable by scrolling")
                try require(owner.sessionView.frame.maxY <= owner.pageHostView.frame.minY, "session footer cannot cover page controls")
            }
        }
        // Preview rendering is opt-in, uses isolated preferences and never starts audio.
        if let directory = ProcessInfo.processInfo.environment["TIMBREDOCK_UI_PREVIEW_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            owner.activeTarget = nil; owner.setDraftTarget(.system)
            owner.preferenceStore.set(AppLanguage.current.rawValue, forKey: AppLanguage.preferenceKey)
            owner.languagePopup.selectItem(at: AppLanguage.current == .english ? 0 : 1)
            owner.refreshLanguagePresentation()
            func capture(_ name: String) throws {
                owner.window.contentView?.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
                if let view = owner.window.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: url.appendingPathComponent("\(name).png"))
                    }
                }
            }
            for (sizeName, size) in [("regular", NSSize(width: 1180, height: 780)), ("minimum", NSSize(width: 940, height: 618))] {
                owner.window.setContentSize(size); owner.layoutApplication()
                for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    owner.window.appearance = NSAppearance(named: appearance)
                    for page in AppPage.allCases {
                        owner.selectedPage = page; owner.updateSelectedPage()
                        if page == .sound {
                            for segment in 0..<3 {
                                owner.modelSelector.selectedSegment = segment; owner.modelChanged()
                                try capture("\(sizeName)-\(name)-sound-\(segment)")
                            }
                        } else { try capture("\(sizeName)-\(name)-\(page.rawValue)") }
                    }
                }
            }
        }
        print("Redesign window checks passed: \(assertions) assertions (draft targets, duplicate names, language, Advanced, five pages, minimum window).")
    }

    static func runOutputConditioningPresentationChecks() throws {
        let suite = "timbredock.output-ui.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let owner = NativeAppDelegate(); owner.preferenceStore = preferences
        owner.outputConditioningEnabled = false
        owner.outputConditioningHeadroomDB = -6
        let page = owner.makeOutputConditioningPage()
        var assertions = 0
        func require(_ condition: Bool, _ message: String) throws {
            assertions += 1
            if !condition { throw AppError.message("Output UI: \(message)") }
        }
        preferences.set(true, forKey: RedesignPreferences.Keys.noticePending)
        owner.updateOutputConditioningStatus()
        try require(!owner.outputMigrationDismissButton.isHidden, "migration notice remains until acknowledged")
        owner.dismissOutputMigrationNotice()
        _ = RedesignPreferences.migrate(preferences)
        owner.updateOutputConditioningStatus()
        try require(owner.outputMigrationDismissButton.isHidden && owner.outputMigrationNoticeLabel.isHidden,
                    "acknowledged migration notice stays dismissed after relaunch migration")
        try require(owner.outputRateModePopup.numberOfItems == 3, "exactly three exclusive modes")
        try require(owner.outputConditioningFilterPopup.numberOfItems == 2, "only Short/Long filters")
        try require(owner.outputConditioningDSDPopup == nil && owner.outputConditioningFactorPopup == nil,
                    "unsupported live controls are absent")
        try require(!owner.outputConditioningHeadroomSlider.isEnabled, "Standard has no applied upsampling gain")
        owner.outputRateModePopup.selectItem(at: 1); owner.outputRateModeChanged()
        try require(owner.outputConditioningEnabled && !owner.automaticRateMatchingEnabled, "2x excludes automatic matching")
        try require(owner.outputConditioningHeadroomSlider.isEnabled, "inactive 2x gain can be configured")
        try require(owner.outputConditioningHeadroomCaption.stringValue.contains(L10n.string("main.output.state.armed")), "saved is distinguished from active")
        owner.currentLivePCM2xActive = true
        owner.currentTapSampleRate = 48_000; owner.currentProcessingSampleRate = 96_000
        owner.refreshDiagnosticsPanel()
        try require(owner.outputConditioningStatusLabel.stringValue == L10n.format("main.output.state.activeRates", "48.0 kHz", "96.0 kHz"),
                    "asynchronous activation refreshes the main output status")
        let gainNote = owner.outputDocument.viewWithTag(OutputPageTag.gainNote.rawValue) as! NSTextField
        owner.currentStopFailure = "fixture restoration failure"
        owner.refreshDiagnosticsPanel()
        try require(gainNote.stringValue.contains(L10n.string("main.output.state.stopFailed")), "failed cleanup overrides stale active gain flag")
        owner.currentStopFailure = nil
        owner.refreshDiagnosticsPanel()
        try require(gainNote.stringValue.contains(L10n.string("main.output.state.active")), "gain note follows actual active state")
        owner.outputConditioningHeadroomSlider.doubleValue = -9; owner.outputConditioningHeadroomChanged()
        try require(gainNote.stringValue.contains(formatDbText(-9.0)), "gain explanation follows slider edits")
        owner.outputConditioningHeadroomSlider.doubleValue = -6; owner.outputConditioningHeadroomChanged()
        try require(owner.outputConditioningHeadroomCaption.stringValue.contains(L10n.string("main.output.state.active")), "actual active state refreshes without diagnostics page")
        owner.outputRateModePopup.selectItem(at: 2); owner.outputRateModeChanged()
        try require(!owner.outputConditioningEnabled && owner.automaticRateMatchingEnabled, "Match Source excludes 2x")
        try require(owner.outputConditioningHeadroomCaption.stringValue.contains(L10n.string("main.output.state.release2x")), "actual 2x release is pending")
        owner.currentLivePCM2xActive = false
        owner.outputRateModePopup.selectItem(at: 1); owner.outputRateModeChanged()
        owner.currentLivePCM2xFallback = "unsupported fixture"; owner.refreshDiagnosticsPanel()
        try require(owner.outputConditioningHeadroomSlider.isEnabled && owner.outputConditioningHeadroomCaption.toolTip == "unsupported fixture", "fallback preserves editable saved gain and reason")
        owner.currentStopFailure = "retained graph fixture"; owner.refreshDiagnosticsPanel()
        try require(owner.outputConditioningHeadroomSlider.isEnabled && owner.outputConditioningHeadroomCaption.stringValue.contains(L10n.string("main.output.state.stopFailed")), "failed stop preserves saved gain")
        try require(owner.outputConditioningHeadroomSlider.doubleValue == -6 && owner.outputConditioningHeadroomSlider.isContinuous, "gain preserved and continuous")
        // Regression: a Diagnostics panel must not keep a stale "PCM 2x pending"
        // row after a stopped 2x session switches back to Standard or Match
        // Source. The mode handler itself refreshes the panel, so these checks
        // deliberately never call refreshDiagnosticsPanel() after the switch.
        owner.currentStopFailure = nil; owner.currentProcessingFailure = nil; owner.pendingAudioOperation = nil
        let diagnosticsPage = owner.makeDiagnosticsPage()
        defer { withExtendedLifetime(diagnosticsPage) {} }
        try require(owner.diagConditioningValue != nil, "diagnostics panel exposes the conditioning row")
        owner.outputRateModePopup.selectItem(at: 1); owner.outputRateModeChanged()
        owner.currentLivePCM2xActive = true
        owner.currentTapSampleRate = 48_000; owner.currentProcessingSampleRate = 96_000
        owner.currentLivePCM2xFallback = ""
        owner.refreshDiagnosticsPanel()
        try require(owner.diagConditioningValue.stringValue == "PCM 2× active", "armed active 2x reports actual live state")
        // A successful Stop clears the live flag; the stopped path refreshes the
        // panel, which now shows the armed-but-inactive pending row.
        owner.currentLivePCM2xActive = false; owner.currentLivePCM2xFallback = ""
        owner.refreshDiagnosticsPanel()
        try require(owner.diagConditioningValue.stringValue == L10n.string("main.state.pcm2xPending"), "stopped armed 2x reports pending")
        owner.outputRateModePopup.selectItem(at: 0); owner.outputRateModeChanged()
        try require(owner.diagConditioningValue.stringValue == "Off", "switching to Standard clears the stale pending 2x row")
        try require(owner.outputConditioningStatusLabel.stringValue == L10n.string("main.status.ready"), "Standard returns the main status to ready")
        // Match Source excludes 2x as well; the panel must not resurrect it.
        owner.outputRateModePopup.selectItem(at: 1); owner.outputRateModeChanged()
        owner.currentLivePCM2xActive = true; owner.refreshDiagnosticsPanel()
        try require(owner.diagConditioningValue.stringValue == "PCM 2× active", "re-armed 2x reports live state before the switch")
        owner.currentLivePCM2xActive = false
        owner.outputRateModePopup.selectItem(at: 2); owner.outputRateModeChanged()
        try require(!owner.outputConditioningEnabled && owner.automaticRateMatchingEnabled, "Match Source still excludes 2x")
        try require(owner.diagConditioningValue.stringValue == "Off", "switching to Match Source clears the stale pending 2x row")

        for width: CGFloat in [730, 769, 950] {
            page.setFrameSize(NSSize(width: width, height: 490)); owner.layoutOutputConditioningPage()
            let slider = owner.outputConditioningHeadroomSlider.frame, value = owner.outputConditioningHeadroomValueLabel.frame
            try require(slider.maxX + 4 <= value.minX && value.maxX <= owner.outputDocument.bounds.width - 23,
                        "gain controls fit width \(width)")
            for child in owner.outputDocument.subviews {
                try require(owner.outputDocument.bounds.contains(child.frame), "output content stays inside scroll document")
            }
        }
        print("OutputConditioningPresentationChecks: \(assertions) assertions; exclusive modes, no unsupported controls, saved/active/fallback/stop state, gain and scroll layout passed")
    }

    /// Exercise direct model selection and gain edits against the real manager/IOProc/ring
    /// with simulated hardware. All preference writes use a disposable suite.
    static func runTrebleSignalChecks() throws {
        let suite = "timbredock.treble-signal.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let owner = NativeAppDelegate(); owner.preferenceStore = preferences
        let page = owner.makeModelPage()
        defer { withExtendedLifetime(page) {} }
        let io = GraphCheckIO()
        let access = try SystemAudioProcessor.GraphCheckAccess(io: io)
        access.withProcessorForUICheck { owner.processor = $0 }
        defer { owner.processor = nil; _ = access.stop() }
        var assertions = 0
        func require(_ condition: Bool, _ message: String) throws {
            assertions += 1
            if !condition { throw AppError.message("Treble signal: \(message)") }
        }
        var lastSecondHarmonic = 0.0
        func measure(rate: Double, frequency: Double, model: Int, drive: Double, added: Double) throws -> Double {
            owner.modelSelector.selectedSegment = model; owner.modelChanged()
            owner.intensitySlider.doubleValue = drive; owner.bodySlider.doubleValue = added
            owner.sliderChanged(); access.managerBarrier()
            let before = access.state()
            _ = access.consumeOutput(Int((before.written - before.read) / 2), advanceRamp: false)
            var squared = 0.0; var count = 0
            var real = 0.0, imaginary = 0.0
            let frameCount = Int(rate * 2)
            for start in stride(from: 0, to: frameCount, by: 512) {
                let frames = min(512, frameCount - start)
                let input = (0..<frames).flatMap { offset -> [Float] in
                    let value = Float(0.5 * sin(2 * Double.pi * frequency * Double(start + offset) / rate))
                    return [value, value]
                }
                io.capture(interleaved: input)
                let output = access.consumeOutput(frames, advanceRamp: false)
                try require(output.count == input.count && output.allSatisfy(\.isFinite), "finite full output")
                for sample in 0..<output.count where start + sample / 2 >= Int(rate) {
                    let delta = Double(output[sample] - input[sample]); squared += delta * delta; count += 1
                    if rate == 48_000 && frequency == 8_000 {
                        let angle = 2 * Double.pi * 16_000 * Double(start + sample / 2) / rate
                        real += delta * cos(angle); imaginary -= delta * sin(angle)
                    }
                }
            }
            try require(owner.processor?.receivedTone?.model == owner.selectedDSPModel(), "actual callback acknowledges the selected model")
            try require(abs((owner.processor?.receivedTone?.intensity ?? -1) - drive) < 0.011
                && abs((owner.processor?.receivedTone?.body ?? -1) - added) < 0.011, "actual callback acknowledges both controls")
            lastSecondHarmonic = 2 * hypot(real, imaginary) / Double(count)
            return sqrt(squared / Double(count))
        }
        for rate in [44_100.0, 48_000.0, 88_200.0, 96_000.0] {
            try access.seed(rate)
            let creates = io.counts["createTap"] ?? 0
            for frequency in [1_000.0, 6_000.0, 8_000.0, 12_000.0] {
                let dry = try measure(rate: rate, frequency: frequency, model: 0, drive: 0, added: 0)
                let zero = try measure(rate: rate, frequency: frequency, model: 2, drive: 100, added: 0)
                let zeroDrive = try measure(rate: rate, frequency: frequency, model: 2, drive: 0, added: 100)
                let subtle = try measure(rate: rate, frequency: frequency, model: 2, drive: 12, added: 4)
                let subtleHarmonic = lastSecondHarmonic
                let strong = try measure(rate: rate, frequency: frequency, model: 2, drive: 50, added: 16)
                let strongHarmonic = lastSecondHarmonic
                if rate == 48_000 && frequency == 8_000 {
                    let ratio = strongHarmonic / max(subtleHarmonic, 1e-15)
                    try require(subtleHarmonic > 1e-7 && abs(ratio / (0.04 / 0.000576) - 1) < 0.02,
                                "16kHz second harmonic scales with drive squared times added harmonics")
                    print(String(format: "TrebleSignalChecks 16k harmonic amplitude Subtle %.9f Strong %.9f ratio %.3f (expected 69.444)", subtleHarmonic, strongHarmonic, ratio))
                }
                let reported = try measure(rate: rate, frequency: frequency, model: 2, drive: 66.93, added: 15.79)
                let maximum = try measure(rate: rate, frequency: frequency, model: 2, drive: 100, added: 100)
                let backToDry = try measure(rate: rate, frequency: frequency, model: 0, drive: 0, added: 0)
                try require(dry < 1e-7 && zero < 1e-7 && zeroDrive < 1e-7 && backToDry < 1e-7, "Off and zero added harmonics preserve dry samples")
                try require(maximum > 1e-8 && maximum > reported && reported > strong && strong >= subtle,
                            "actual UI parameter updates create increasing measurable output changes at \(rate)/\(frequency)")
                let db = [subtle, strong, reported, maximum].map { 20 * log10(max($0, 1e-15)) }
                print(String(format: "TrebleSignalChecks %.0f Hz input %.0f Hz: residual RMS dBFS Subtle %.2f / Strong %.2f / reported %.2f / max %.2f", rate, frequency, db[0], db[1], db[2], db[3]))
            }
            try require(io.counts["createTap"] == creates, "live model/parameter edits must not recreate capture")
            try require(access.stop(), "test graph tears down before the next sample rate")
            try require(owner.processor?.receivedTone == nil, "stopped processor must hide historical callback receipt")
        }
        // The reported session used live PCM 2x. Compare against Off through
        // the same resampler/gain, rather than comparing delayed 2x samples to dry input.
        for rate in [44_100.0, 48_000.0] {
            try access.seed(rate)
            io.onPause = {
                let state = access.state()
                io.capture(256)
                if io.outputIsRunning { _ = access.consumeOutput(Int(256 * state.outputRate / state.tapRate)) }
            }
            access.live2x(true)
            try require(access.state().live2x && access.state().outputRate == rate * 2, "real 2x test path activated")
            func render(model: Int) -> [Float] {
                owner.modelSelector.selectedSegment = model; owner.modelChanged()
                owner.intensitySlider.doubleValue = 100; owner.bodySlider.doubleValue = 100
                owner.sliderChanged(); access.managerBarrier()
                let state = access.state()
                _ = access.consumeOutput(Int((state.written - state.read) / 2), advanceRamp: false)
                var result: [Float] = []
                for start in stride(from: 0, to: Int(rate * 2), by: 512) {
                    let frames = min(512, Int(rate * 2) - start)
                    let input = (0..<frames).flatMap { offset -> [Float] in
                        let value = Float(0.5 * sin(2 * Double.pi * 8000 * Double(start + offset) / rate))
                        return [value, value]
                    }
                    io.capture(interleaved: input)
                    result.append(contentsOf: access.consumeOutput(frames * 2, advanceRamp: false))
                }
                return Array(result.suffix(Int(rate) * 4))
            }
            let creates = io.counts["createTap"]
            let dry = render(model: 0), wet = render(model: 2), back = render(model: 0)
            try require(dry.count == wet.count && wet.allSatisfy(\.isFinite), "complete finite 2x output")
            let residual = sqrt(zip(wet, dry).reduce(0.0) { $0 + pow(Double($1.0 - $1.1), 2) } / Double(wet.count))
            let restored = zip(back, dry).map { abs($0 - $1) }.max() ?? 1
            try require(residual > 1e-4 && restored < 1e-6, "2x preserves the harmonic difference and returns to Off")
            try require(io.counts["createTap"] == creates, "tone edits on 2x do not recreate capture")
            print(String(format: "TrebleSignalChecks PCM2x %.0f -> %.0f Hz, 8k input: max residual %.2f dBFS, Off return max delta %.9f", rate, rate * 2, 20 * log10(residual), restored))
            io.onPause = nil
            try require(access.stop(), "2x fixture stops and restores")
        }
        print("TrebleSignalChecks: \(assertions) assertions passed; actual UI -> manager -> registered IOProc -> DSP -> output ring, simulated hardware, no playback.")
    }

    static func runLiveControlEditingChecks() throws {
        let suite = "lowend.control-editing-check.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let owner = NativeAppDelegate()
        owner.preferenceStore = preferences
        owner.outputConditioningEnabled = true
        owner.outputConditioningModeRaw = OutputConditioningMode.pcmOversampling.rawValue
        owner.outputConditioningFactor = 2
        owner.outputConditioningFilterRaw = ResamplingFilterMode.linearPhaseLong.rawValue
        owner.outputConditioningHeadroomDB = 0
        let modelPage = owner.makeModelPage()
        let outputPage = owner.makeOutputConditioningPage()
        defer { withExtendedLifetime((modelPage, outputPage)) {} }
        let io = GraphCheckIO()
        let access = try SystemAudioProcessor.GraphCheckAccess(io: io)
        access.withProcessorForUICheck { owner.processor = $0 }
        NotificationCenter.default.addObserver(owner, selector: #selector(audioFormatDidChange(_:)),
            name: AudioFormatNotifications.didChange, object: nil)
        defer {
            NotificationCenter.default.removeObserver(owner)
            owner.processor = nil
            io.onPause = nil
            _ = access.stop()
        }
        var assertions = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw AppError.message("Live control editing: \(message)") }
        }
        func drainNotifications(until condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(1)
            while !condition() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
            try require(condition(), "Final manager notification was not consumed")
        }
        func selectModel(_ index: Int) throws {
            try require(owner.modelSelector.isEnabled && (0..<3).allSatisfy { owner.modelSelector.isEnabled(forSegment: $0) },
                "All models remain selectable")
            owner.modelSelector.selectedSegment = index
            try require(owner.modelSelector.sendAction(owner.modelSelector.action, to: owner.modelSelector.target),
                "Direct model selection must dispatch")
            try require(owner.modelSelector.selectedSegment == index
                && preferences.integer(forKey: "selectedModel") == index,
                "Direct selection and saved model must change together")
            let names = [L10n.string("main.sound.value.bypass"), L10n.string("main.sound.bass.amount"), L10n.string("main.sound.treble.drive")]
            try require(owner.intensityNameLabel.stringValue == names[index], "Direct selection must refresh the model controls")
        }
        func editHeadroom(_ db: Double, synchronize: Bool = true) throws {
            try require(owner.outputConditioningHeadroomSlider.isEnabled, "Headroom settings remain editable")
            owner.outputConditioningHeadroomSlider.doubleValue = db
            try require(owner.outputConditioningHeadroomSlider.sendAction(
                owner.outputConditioningHeadroomSlider.action, to: owner.outputConditioningHeadroomSlider.target),
                "Actual headroom action must dispatch")
            if synchronize { access.managerBarrier() }
            try require(preferences.double(forKey: "outputConditioningHeadroomDB") == db
                && owner.outputConditioningHeadroomValueLabel.stringValue == formatDbText(db),
                "Requested gain and visible number must be saved together")
        }
        io.onPause = {
            let state = access.state()
            io.capture(256)
            if io.outputIsRunning {
                _ = access.consumeOutput(Int(256 * state.outputRate / max(state.tapRate, 1)))
            }
        }
        try access.seed()
        for index in [1, 2, 0] { try selectModel(index) }
        access.managerBarrier()
        // Hold the manager after the initial parameter snapshot is submitted,
        // then edit twice while activation and its main-thread status are pending.
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        access.stallManager(entered: entered, release: release)
        defer { release.signal() }
        try require(entered.wait(timeout: .now() + 1) == .success, "Manager must be held for the activation edit check")
        owner.pushOutputConditioningSettings()
        try editHeadroom(-6, synchronize: false)
        try editHeadroom(-12, synchronize: false)
        release.signal()
        access.managerBarrier()
        let creates = io.counts["createTap"] ?? 0
        try require(!owner.currentLivePCM2xActive && owner.pendingHeadroomEdit,
            "Edits must remain pending until the activation notification reaches the UI")
        try drainNotifications { owner.currentLivePCM2xActive }
        access.managerBarrier()
        try require(!owner.pendingHeadroomEdit, "Activation must submit the latest saved gain once")
        func verifyOutputGain(_ db: Double) throws {
            let state = access.state()
            _ = access.consumeOutput(Int((state.written - state.read) / 2), advanceRamp: false)
            io.capture(1024)
            let tail = access.consumeOutput(2048, advanceRamp: false).suffix(1024)
            let mean = tail.reduce(0.0) { $0 + Double($1) } / Double(tail.count)
            try require(abs(mean - 0.125 * pow(10, db / 20)) < 0.000001,
                "Live UI gain must reach actual output samples")
            try require(io.counts["createTap"] == creates, "Live headroom must not rebuild capture")
        }
        try verifyOutputGain(-12)
        for db: Double in [0, -6, -12, 0] {
            try editHeadroom(db)
            try verifyOutputGain(db)
        }
        access.live2x(false)
        let beforeStaleActiveEdit = io.counts
        try require(owner.currentLivePCM2xActive, "UI must still have the older active notification")
        try editHeadroom(-6)
        try require(io.counts == beforeStaleActiveEdit && !access.state().live2x,
            "An edit against stale UI state must not reactivate or rebuild a device")
        try drainNotifications { !owner.currentLivePCM2xActive }
        io.rejectRates = [96_000]
        access.live2x(true)
        try drainNotifications { !owner.currentLivePCM2xFallback.isEmpty }
        try require(access.state().started && owner.currentProcessingFailure == nil,
            "Recovered PCM fallback is still processing")
        let beforeFallbackEdit = io.counts
        try editHeadroom(-3)
        try require(io.counts == beforeFallbackEdit, "Editing inactive gain must not retry the failed rate transition")
        io.rejectRates = []
        io.onPause = {
            if io.outputIsRunning { _ = access.consumeOutput(512) }
        }
        access.live2x(true)
        try drainNotifications { owner.currentProcessingFailure != nil }
        try require(!access.state().started && !owner.currentLivePCM2xActive,
            "Failed target and rollback must remain stopped")
        try require(owner.statusLabel.stringValue.contains(L10n.string("main.detail.17370156d9"))
            && owner.outputConditioningRuntimeLabel.stringValue == L10n.string("main.detail.c4261b4bf6"),
            "Actual processing failure must replace stale running text")
        let beforeStoppedEdit = io.counts
        try editHeadroom(-12)
        try selectModel(2)
        access.managerBarrier()
        try require(io.counts == beforeStoppedEdit, "Settings edits must not restart or clean up the failed graph")
        try require(owner.statusLabel.stringValue.contains(L10n.string("main.detail.17370156d9")), "Model edit must preserve stopped status")
        try require(access.stop(), "Explicit Stop must finish simulated cleanup")
        print("LiveControlEditingChecks: \(assertions) assertions; direct model selection, pending activation edits and active 2x sample gain, recovered fallback and stopped editing, actual manager notifications; simulated hardware, isolated preferences, no visible window.")
    }

    @objc private func stopAudio() {
        requestStopAudio()
    }

    /// Real delegate actions, injected graph/lease, and a gated blocking call.
    /// The main loop must remain usable until the worker is explicitly released.
    static func runGUIAudioLifecycleChecks() throws {
        var assertions = 0, cases = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            guard condition() else { throw AppError.message("GUI lifecycle: \(message)") }
        }
        func pump(_ label: String, until predicate: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(2)
            while !predicate() && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            try require(predicate(), label)
        }
        func heartbeat() throws {
            let seen = RuntimeSnapshotBox(false)
            DispatchQueue.main.async { seen.store(true) }
            try pump("Main event loop blocked behind lifecycle work") { seen.load() }
        }
        func runCase(_ name: String,
                     _ body: (NativeAppDelegate, GUIAudioLifecycleCheckFixture, RuntimeSnapshotBox<Int>) throws -> Void) throws {
            let suite = "lowend.gui-lifecycle-check.\(UUID().uuidString)"
            let preferences = UserDefaults(suiteName: suite)!
            let fixture = try GUIAudioLifecycleCheckFixture()
            let owner = NativeAppDelegate()
            owner.preferenceStore = preferences
            owner.lifecycleStartsDiagnosticsTimer = false
            owner.automaticRateMatchingEnabled = false
            owner.outputConditioningEnabled = false
            owner.outputConditioningModeRaw = OutputConditioningMode.bypass.rawValue
            owner.outputConditioningFactor = 2
            owner.outputConditioningHeadroomDB = 0
            owner.audioLifecycleIO = fixture.lifecycleIO
            let modelPage = owner.makeModelPage()
            let outputPage = owner.makeOutputConditioningPage()
            owner.allSystemButton = NSButton(title: "", target: owner, action: #selector(startAllAudio))
            owner.routingStartAppButton = NSButton(title: L10n.string("main.detail.a2892e2b7c"), target: owner, action: #selector(startSelectedApp))
            owner.automaticRateMatchButton = NSButton(checkboxWithTitle: L10n.string("main.detail.ca7eb2ef0a"), target: owner,
                                                      action: #selector(automaticRateMatchChanged))
            let quitCount = RuntimeSnapshotBox(0)
            owner.finishRequestedQuit = { quitCount.store(quitCount.load() + 1) }
            NotificationCenter.default.addObserver(owner, selector: #selector(audioFormatDidChange(_:)),
                name: AudioFormatNotifications.didChange, object: nil)
            defer {
                fixture.gate.open()
                let deadline = Date().addingTimeInterval(6)
                while owner.pendingAudioOperation != nil && Date() < deadline {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.002))
                }
                if owner.pendingAudioOperation == nil {
                    fixture.rejectStop.store(false)
                    fixture.io.failures = [:]
                    _ = owner.stopAndWaitForCheck()
                    _ = owner.audioLifecycleWorker.retainedSessionCountForCheck()
                    fixture.close()
                }
                NotificationCenter.default.removeObserver(owner)
                preferences.removePersistentDomain(forName: suite)
                withExtendedLifetime((modelPage, outputPage)) {}
            }
            try body(owner, fixture, quitCount)
            try require(fixture.journal.count("gate-timeout") == 0, "\(name): gate expired without explicit release")
            try require(fixture.journal.count("make-on-main") == 0
                && fixture.journal.count("start-on-main") == 0
                && fixture.journal.count("stop-on-main") == 0, "\(name): blocking operation ran on main")
            cases += 1
            print("GUIAudioLifecycleChecks \(name): PASS")
        }

        try runCase("audio-flow-waits-for-real-input-and-output") { owner, f, _ in
            owner.startAllAudio()
            try pump("Flow fixture did not complete Start") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            owner.diagAudioFlowValue = NSTextField(labelWithString: "")
            owner.updateDiagnostics()
            try require(f.access.state().started && f.lease.isHeld && owner.spectrumAnalyzer != nil
                && owner.statusLabel.stringValue == L10n.string("main.state.waitingData")
                && owner.diagAudioFlowValue.stringValue == L10n.string("main.state.waitingData"),
                "No-data Start must retain its graph and show waiting, not running")
            try require(owner.statusLabel.toolTip == AudioFlowProgress.waitingHelp,
                "Waiting must explain conditional access requests, not assert permission denial")
            _ = f.access.consumeOutput(512)
            owner.updateDiagnostics()
            try require(f.processor.diagnosticsSnapshot().outputUnderrunSamples == 1024
                && !f.processor.diagnosticsSnapshot().audioFlow.isConfirmed
                && owner.statusLabel.stringValue == L10n.string("main.state.waitingData"),
                "Underrun padding must not count as real input/output progress")
            owner.modelSelector.selectedSegment = 1
            owner.modelChanged()
            owner.applyPreset(at: 0)
            try require(owner.statusLabel.stringValue == L10n.string("main.state.waitingData"),
                        "Model and preset edits must preserve the waiting status")
            owner.modelSelector.selectedSegment = 0
            owner.modelChanged()
            f.access.managerBarrier()
            f.io.capture(256, sample: 0)
            owner.updateDiagnostics()
            try require(owner.statusLabel.stringValue == L10n.string("runtime.flow.waitingOutput")
                && f.processor.diagnosticsSnapshot().audioFlow.producedSamples == 512
                && f.processor.diagnosticsSnapshot().audioFlow.consumedSamples == 0,
                "Capture without real output consumption must remain waiting")
            let silent = f.access.consumeOutput(256, advanceRamp: false)
            owner.updateDiagnostics()
            try require(silent.count == 512 && silent.allSatisfy { $0 == 0 }
                && f.processor.diagnosticsSnapshot().audioFlow.isConfirmed
                && owner.statusLabel.stringValue.contains(L10n.string("main.detail.4ef2c9218b"))
                && owner.diagAudioFlowValue.stringValue == L10n.string("runtime.flow.confirmed"),
                "Legitimate silent PCM must confirm flow without a level threshold")
            owner.updateDiagnostics()
            try require(owner.statusLabel.toolTip == nil,
                        "Confirmed flow must remove initial waiting instructions")
        }

        try runCase("audio-flow-before-main-completion-is-preserved") { owner, f, _ in
            let base = f.lifecycleIO
            owner.audioLifecycleIO = GUIAudioLifecycleIO(make: base.make, start: { processor in
                try base.start(processor)
                f.io.capture(128)
                _ = f.access.consumeOutput(128, advanceRamp: false)
            }, stop: base.stop)
            owner.startAllAudio()
            try pump("Early data fixture did not complete") { owner.pendingAudioOperation == nil }
            try require(owner.statusLabel.stringValue.contains(L10n.string("main.detail.4ef2c9218b"))
                && f.processor.diagnosticsSnapshot().audioFlow.producedSamples == 256
                && f.processor.diagnosticsSnapshot().audioFlow.consumedSamples == 256,
                "Main completion must not reset a baseline after real data already arrived")
        }

        try runCase("audio-flow-resets-on-graph-reconfiguration") { owner, f, _ in
            owner.startAllAudio()
            try pump("Reconfiguration flow fixture did not start") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            f.io.capture(128)
            _ = f.access.consumeOutput(128, advanceRamp: false)
            owner.updateDiagnostics()
            let previous = f.processor.diagnosticsSnapshot().audioFlow
            try require(previous.isConfirmed, "Original graph must have actual input/output")
            try f.access.reconfigureHardwareFormat(96_000)
            owner.updateDiagnostics()
            let next = f.processor.diagnosticsSnapshot().audioFlow
            try require(next.generation > previous.generation && !next.isConfirmed
                && next.producedSamples == 0 && next.consumedSamples == 0
                && f.access.state().written > 0 && owner.statusLabel.stringValue == L10n.string("main.state.waitingData"),
                "Old cumulative data must not confirm a replacement graph")
            f.io.capture(128, sample: 0)
            _ = f.access.consumeOutput(128, advanceRamp: false)
            owner.updateDiagnostics()
            try require(f.processor.diagnosticsSnapshot().audioFlow.isConfirmed
                && owner.statusLabel.stringValue.contains(L10n.string("main.detail.4ef2c9218b")),
                "Replacement graph did not become confirmed after its own silent PCM")
        }

        try runCase("audio-flow-waiting-stop-quit-and-old-session") { owner, f, quit in
            owner.startAllAudio()
            try pump("Waiting Stop fixture did not start") { owner.pendingAudioOperation == nil }
            try require(owner.stopAndWaitForCheck() && owner.statusLabel.stringValue == L10n.string("main.monitor.state.stopped")
                && owner.processor == nil && !f.lease.isHeld,
                "Waiting for first data must not prevent a normal Stop")
            let replacement = try GUIAudioLifecycleCheckFixture()
            defer { replacement.close() }
            owner.audioLifecycleIO = replacement.lifecycleIO
            owner.startAllAudio()
            try pump("Replacement waiting session did not start") { owner.pendingAudioOperation == nil }
            owner.audioFormatDidChange(Notification(name: AudioFormatNotifications.didChange,
                userInfo: ["processorSessionID": f.processor.notificationSessionID,
                    AudioFormatNotifications.livePCM2xActiveKey: false,
                    AudioFormatNotifications.isProcessingKey: true,
                    AudioFormatNotifications.livePCM2xFallbackKey: ""]))
            try require(owner.processor === replacement.processor
                && owner.statusLabel.stringValue == L10n.string("main.state.waitingData"),
                "A retired session's success must not confirm current flow")
            replacement.gate.arm("stop")
            try require(owner.applicationShouldTerminate(.shared) == .terminateCancel,
                        "Quit while waiting for data must await actual cleanup")
            try pump("Waiting Quit did not reach Stop") { replacement.gate.entered }
            owner.updateDiagnostics()
            try require(owner.statusLabel.stringValue.contains(L10n.string("main.detail.0bc794996a")) && quit.load() == 0,
                        "A diagnostics tick must not overwrite pending Stop with flow status")
            replacement.gate.open()
            try pump("Waiting Quit did not finish") { owner.pendingAudioOperation == nil }
            try require(quit.load() == 1 && owner.processor == nil && !replacement.lease.isHeld,
                        "Waiting Quit did not release its actual owner and lease")
            _ = owner.audioLifecycleWorker.retainedSessionCountForCheck()
        }

        try runCase("initialization-stop-and-duplicate-barrier") { owner, f, quit in
            f.gate.arm("make")
            owner.startAllAudio()
            try pump("Initialization did not reach the worker") { f.gate.entered }
            try heartbeat()
            let token = owner.pendingAudioOperation?.id
            owner.startAllAudio()
            try require(owner.pendingAudioOperation?.id == token && f.journal.count("make-off-main") == 1,
                        "Duplicate Apply replaced an initializing operation")
            try require(owner.processor == nil && !owner.allSystemButton.isEnabled
                && owner.allSystemButton.accessibilityLabel()?.contains(L10n.string("main.detail.6e1c0e1050")) == true,
                "Pending initialization lacks global accessible state")
            owner.stopAudio()
            try heartbeat()
            try require(f.journal.count("stop-off-main") == 0 && f.journal.count("start-off-main") == 0,
                        "Stop must not overtake an unfinished initializer")
            f.gate.open()
            try pump("Canceled initialization did not finish cleanup") { owner.pendingAudioOperation == nil }
            try require(owner.processor == nil && owner.spectrumAnalyzer == nil
                && f.journal.count("start-off-main") == 0 && f.journal.count("stop-off-main") == 1,
                "Canceled initialization must retire without starting capture")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0 && quit.load() == 0,
                        "Canceled initialization retained a worker owner or requested Quit")
            try require(owner.allSystemButton.isEnabled && owner.allSystemButton.accessibilityLabel() == L10n.string("main.detail.4ac9585a1d"),
                        "Finished operation did not restore the global Apply label")
        }

        try runCase("capture-start-delayed-stop-and-quit") { owner, f, quit in
            f.gate.arm("startCapture")
            owner.outputConditioningEnabled = true
            owner.outputConditioningModeRaw = OutputConditioningMode.pcmOversampling.rawValue
            owner.startAllAudio()
            try pump("Capture Start did not reach its gate") { f.gate.entered }
            try heartbeat()
            let token = owner.pendingAudioOperation?.id
            owner.startAllAudio()
            owner.stopAudio()
            try require(owner.applicationShouldTerminate(.shared) == .terminateCancel,
                        "Quit must not terminate an in-flight owner")
            try heartbeat()
            try require(owner.pendingAudioOperation?.id == token && owner.processor === f.processor
                && f.lease.isHeld && quit.load() == 0, "Pending Stop/Quit lost its token, owner or lease")
            try require(f.journal.count("stop-off-main") == 0 && f.journal.count("setOutputRate") == 0,
                        "Pending Stop/Quit ran cleanup or PCM negotiation before Start returned")
            try require(owner.allSystemButton.accessibilityLabel()?.contains(L10n.string("main.detail.af8289ed49")) == true,
                        "Global state does not explain deferred Stop")
            f.gate.open()
            try pump("Delayed Stop/Quit did not finish") { owner.pendingAudioOperation == nil }
            try require(owner.processor == nil && owner.spectrumAnalyzer == nil && !f.lease.isHeld
                && f.journal.count("stop-off-main") == 1 && f.journal.count("setOutputRate") == 0
                && quit.load() == 1, "Delayed success must Stop once, skip PCM/analyzer, then finish Quit")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Quit completion did not retire the worker owner")
        }

        try runCase("stop-stall-keeps-main-responsive") { owner, f, _ in
            owner.startAllAudio()
            try pump("Initial Start did not complete") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            f.gate.arm("stop")
            owner.stopAudio()
            try pump("Stop did not reach its worker gate") { f.gate.entered }
            try heartbeat()
            owner.startAllAudio()
            owner.stopAudio()
            try require(owner.processor === f.processor && f.lease.isHeld
                && f.journal.count("make-off-main") == 1 && f.journal.count("stop-off-main") == 1,
                "Repeated Start/Stop replaced or duplicated a pending Stop")
            f.gate.open()
            try pump("Stop did not complete after release") { owner.pendingAudioOperation == nil }
            try require(owner.processor == nil && !f.lease.isHeld
                && owner.currentDeviceSampleRate == nil, "Confirmed Stop did not clear owner and output cache")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Successful Stop did not retire its worker owner")
        }

        try runCase("pending-edits-and-initial-notification") { owner, f, _ in
            f.gate.arm("startCapture")
            owner.startAllAudio()
            try pump("Edit fixture did not hold Start") { f.gate.entered }
            owner.modelSelector.selectedSegment = 1
            owner.modelChanged()
            owner.intensitySlider.doubleValue = 0
            owner.bodySlider.doubleValue = 0
            owner.outputSlider.doubleValue = -6
            owner.sliderChanged()
            var spatial = owner.spatialControlModel.settings
            spatial.listenerX = 1.2; spatial.amount = 71; spatial.enabled = false
            owner.updateSpatialControls(from: spatial, notifyProcessor: true)
            owner.observeSourceSnapshot(SourceFormatSnapshot(activePlayers: [], formats: []))
            owner.outputRateModePopup.selectItem(at: 1)
            owner.outputRateModeChanged()
            owner.outputConditioningFilterRaw = ResamplingFilterMode.linearPhaseLong.rawValue
            owner.outputConditioningHeadroomSlider.doubleValue = -12
            owner.outputConditioningHeadroomChanged()
            try heartbeat()
            try require(owner.outputConditioningHeadroomDB == -12 && owner.pendingHeadroomEdit
                && owner.statusLabel.stringValue.contains(L10n.string("main.detail.6e1c0e1050"))
                && f.journal.count("setOutputRate") == 0 && f.journal.count("stopCapture") == 0,
                "Pending edits must be saved without starting a transition or replacing pending status")
            f.gate.open()
            try pump("Latest PCM setting did not become active after successful Start") {
                owner.pendingAudioOperation == nil && owner.currentLivePCM2xActive
            }
            f.access.managerBarrier()
            try require(owner.currentTapSampleRate == 48_000 && owner.currentDeviceSampleRate == 96_000,
                        "Bind-before-start lost matching-session format notifications")
            try require(owner.spectrumAnalyzer != nil && owner.selectedDSPModel() == .circuit
                && owner.spatialControlModel.settings.listenerX == 1.2 && !owner.pendingHeadroomEdit,
                "Successful Start lost the latest model, spatial or gain edit")
            let state = f.access.state()
            _ = f.access.consumeOutput(Int((state.written - state.read) / 2), advanceRamp: false)
            f.io.capture(4096)
            let tail = f.access.consumeOutput(8192, advanceRamp: false).suffix(1024)
            let mean = tail.reduce(0.0) { $0 + Double($1) } / Double(tail.count)
            try require(abs(mean - 0.125 * pow(10, -18.0 / 20)) < 0.00001,
                        "Latest Circuit output -6 dB and headroom -12 dB did not reach actual samples (\(mean))")
            try require(f.access.state().appliedRevision >= owner.lastSpatialSubmissionRevision,
                        "Latest Spatial submission was not consumed by the actual callback")
            try require(owner.stopAndWaitForCheck(), "Latest-setting fixture Stop failed")
            _ = owner.audioLifecycleWorker.retainedSessionCountForCheck()
            owner.audioFormatDidChange(Notification(name: AudioFormatNotifications.didChange,
                userInfo: ["processorSessionID": f.processor.notificationSessionID,
                           AudioFormatNotifications.sampleRateKey: 192_000.0]))
            try require(owner.currentDeviceSampleRate == nil && owner.processor == nil,
                        "Retired notification restored stopped output state")
        }

        try runCase("pending-automatic-edit-survives-initial-format") { owner, f, _ in
            f.gate.arm("startCapture")
            owner.startAllAudio()
            try pump("Automatic-rate fixture did not hold Start") { f.gate.entered }
            owner.outputRateModePopup.selectItem(at: 2)
            owner.outputRateModeChanged()
            owner.observeSourceSnapshot(SourceFormatSnapshot(activePlayers: [], formats: []))
            try heartbeat()
            f.gate.open()
            try pump("Automatic-rate fixture did not finish Start") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            // Drain the real initial false notification and the latest true
            // submission's notification, rather than inventing either event.
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            try require(owner.automaticRateMatchingEnabled && owner.outputRateMode == .matchSource
                && owner.preferenceStore.bool(forKey: "automaticRateMatchingEnabled"),
                "Initial stale format notification overwrote the pending automatic-rate edit")
            try require(owner.currentDeviceSampleRate == 48_000 && owner.lastSourceObservation != nil,
                        "Successful Start lost source observation or initial format")
        }

        try runCase("failed-stop-quit-retains-owner-and-retry") { owner, f, quit in
            owner.startAllAudio()
            try pump("Stop failure fixture Start failed") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            f.rejectStop.store(true)
            try require(owner.applicationShouldTerminate(.shared) == .terminateCancel, "Quit must wait for Stop")
            try pump("Injected Stop failure did not complete") { owner.pendingAudioOperation == nil }
            try require(owner.processor === f.processor && f.lease.isHeld && owner.currentStopFailure != nil
                && quit.load() == 0 && owner.audioLifecycleWorker.retainedSessionCountForCheck() == 1,
                "False Stop with default diagnostic must preserve both owners and cancel Quit")
            owner.startAllAudio()
            try pump("Replacement Stop failure did not finish") { owner.pendingAudioOperation == nil }
            try require(f.journal.count("make-off-main") == 1 && owner.processor === f.processor,
                        "Failed replacement Stop created another processor")
            f.rejectStop.store(false)
            try require(owner.stopAndWaitForCheck() && !f.lease.isHeld && quit.load() == 0,
                        "Explicit retry did not clear owner, or replayed the failed Quit intent")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Explicit retry did not retire the worker reference")
        }

        try runCase("failed-start-cleanup-requires-explicit-retry") { owner, f, _ in
            f.io.failures["startCapture"] = [1]
            f.io.failures["unregisterCapture"] = [1]
            owner.startAllAudio()
            try pump("Start cleanup failure did not complete") { owner.pendingAudioOperation == nil }
            f.access.managerBarrier()
            try require(f.journal.count("unregisterCapture") == 1 && f.journal.count("stop-off-main") == 0
                && owner.processor === f.processor && f.lease.isHeld && owner.currentStopFailure != nil,
                "Start completion retried a failed teardown or lost its owner")
            try require(owner.stopAndWaitForCheck() && !f.lease.isHeld,
                        "Explicit Stop did not retry failed startup cleanup")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Startup cleanup retry did not retire its worker owner")
        }

        try runCase("initialization-error") { owner, f, _ in
            f.failMake.store(true)
            owner.startAllAudio()
            try pump("Initializer error did not complete") { owner.pendingAudioOperation == nil }
            try require(owner.processor == nil && owner.spectrumAnalyzer == nil
                && owner.statusLabel.stringValue.contains(L10n.string("main.detail.3cf10d0a2f")) && owner.allSystemButton.isEnabled
                && f.journal.count("start-off-main") == 0 && f.journal.count("stop-off-main") == 0,
                "Initializer error started a graph, retained an owner or left Apply disabled")
        }

        try runCase("final-destructor-on-worker") { owner, _, _ in
            let weakOwner = GUIAudioWeakOwnerCheck()
            let journal = GUIAudioCheckJournal()
            owner.audioLifecycleIO = GUIAudioLifecycleIO(make: { settings in
                let io = GraphCheckIO()
                io.onCall = { operation in
                    if operation == "stopOutput" {
                        journal.record(Thread.isMainThread ? "stopOutput-main" : "stopOutput-worker")
                    }
                }
                let processor = try SystemAudioProcessor(settings: settings,
                    initialOutput: { (777, 48_000) }, graphIO: io)
                weakOwner.observe(processor)
                return processor
            }, start: { _ in }, stop: { $0.stop() })
            owner.startAllAudio()
            try pump("Retirement fixture did not start") { owner.pendingAudioOperation == nil }
            try require(weakOwner.isAlive && owner.audioLifecycleWorker.retainedSessionCountForCheck() == 1,
                        "Worker did not retain the live processor")
            try require(owner.stopAndWaitForCheck(), "Retirement fixture Stop failed")
            try require(owner.audioLifecycleWorker.retainedSessionCountForCheck() == 0,
                        "Retirement table did not clear")
            try pump("Final processor reference survived worker retirement") { !weakOwner.isAlive }
            try require(journal.count("stopOutput-main") == 0 && journal.count("stopOutput-worker") >= 2,
                        "Successful Stop or final destructor entered the graph on main")
        }
        print("GUIAudioLifecycleChecks: \(cases) cases; \(assertions) assertions; actual async delegate init/start/stop, gated main-loop responsiveness, duplicate/Stop/Quit ownership, latest edits and samples, failed cleanup/retry, session routing and worker retirement; injected devices/leases, isolated preferences, no visible window.")
    }

    /// Exercise the real strong property and stop method without launching the
    /// app, building a window, observing source players or querying a device.
    static func runStopRestorationChecks() throws {
        try SystemAudioProcessor.runStopRestorationChecks { processor in
            let owner = NativeAppDelegate()
            owner.processor = processor
            return (
                attempt: { owner.stopAndWaitForCheck() },
                retainsProcessor: { owner.processor === processor }
            )
        }
    }

    /// Exercise the real diagnostics observer boundary with no graph, device
    /// lookup, app launch or timer. Identical snapshots must not invalidate the
    /// Spatial page; receipt/pending text changes must remain observable.
    static func runSpatialDiagnosticsChecks() throws {
        let owner = NativeAppDelegate()
        let processor = try SystemAudioProcessor(settings: Settings(), initialOutput: { (777, 48_000) })
        owner.processor = processor
        owner.diagnosticsLabel = NSTextField(labelWithString: "")
        var publications = 0
        var audioSubmissions = 0
        let observation = owner.spatialControlModel.objectWillChange.sink { publications += 1 }
        owner.spatialControlModel.onChange = { _ in audioSubmissions += 1 }
        defer { observation.cancel(); owner.processor = nil; _ = processor.stop() }
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw AppError.message("Spatial diagnostics: \(message)") }
        }
        owner.updateDiagnostics()
        let received = owner.spatialControlModel.appliedStatusText
        try require(publications == 1 && received?.contains(L10n.string("main.detail.5ba7c94f1c")) == true,
                    "Initial actual diagnostics did not publish receipt status")
        for _ in 0..<3 { owner.updateDiagnostics() }
        try require(publications == 1, "Identical receipt status republished the observed model")
        owner.lastSpatialSubmissionRevision = 7
        owner.updateDiagnostics()
        try require(publications == 2 && owner.spatialControlModel.appliedStatusText?.contains(L10n.string("main.detail.f0820eb4bc")) == true,
                    "Changed pending request did not update its status")
        for _ in 0..<3 { owner.updateDiagnostics() }
        try require(publications == 2, "Identical pending status republished the observed model")
        owner.lastSpatialSubmissionRevision = 0
        owner.updateDiagnostics()
        try require(publications == 3 && owner.spatialControlModel.appliedStatusText == received,
                    "Returning to received status did not publish the change")
        try require(audioSubmissions == 0 && owner.spatialControlModel.uiEditRevision == 0
                    && !owner.spatialControlModel.hasPendingEdit && processor.appliedSpatialRevision == 0,
                    "Read-only diagnostics changed an audio edit or ACK")
        print("SpatialDiagnosticsChecks: 6 assertions; actual updateDiagnostics, identical receipt/pending status emits no model update, changed status remains observable, no audio edit. Injected unstarted processor; no window/device query.")
    }

    /// Check the actual notification consumer without posting to the global
    /// notification center. Device/engine rates must not replace the tap rate
    /// used by Spatial preview, and a retired processor cannot change the page.
    static func runSpatialFormatBridgeChecks() throws {
        let owner = NativeAppDelegate()
        let old = try SystemAudioProcessor(settings: Settings(), initialOutput: { (777, 48_000) })
        let current = try SystemAudioProcessor(settings: Settings(), initialOutput: { (777, 44_100) })
        defer { owner.processor = nil; _ = old.stop(); _ = current.stop() }
        var settings = SpatialSettings()
        settings.enabled = true; settings.listenerX = 1.2; settings.listenerZ = 0.7
        settings.speakerWidth = 2.1; settings.amount = 73
        owner.spatialControlModel.update(settings)
        var audioEdits = 0
        owner.spatialControlModel.onChange = { _ in audioEdits += 1 }
        var assertions = 0
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw AppError.message("Spatial format bridge: \(message)") }
        }
        func deliver(_ session: String?, tap: Double, output: Double) {
            var values: [String: Any] = [
                AudioFormatNotifications.tapSampleRateKey: tap,
                AudioFormatNotifications.processingSampleRateKey: output,
                AudioFormatNotifications.sampleRateKey: output,
                AudioFormatNotifications.livePCM2xActiveKey: true
            ]
            if let session { values["processorSessionID"] = session }
            owner.audioFormatDidChange(Notification(name: AudioFormatNotifications.didChange,
                                                    object: nil, userInfo: values))
        }
        owner.processor = old
        deliver(old.notificationSessionID, tap: 48_000, output: 96_000)
        try require(owner.currentProcessingSampleRate == 96_000 && owner.currentDeviceSampleRate == 96_000,
                    "Matching session did not update engine/device rates")
        try require(owner.currentTapSampleRate == 48_000 && owner.spatialControlModel.processingSampleRate == 48_000
                    && owner.spatialControlModel.preview?.raw.sampleRate == 48_000,
                    "Spatial preview used output 2x instead of capture 1x")
        try require(owner.currentLivePCM2xActive, "Matching notification lost live 2x display state")
        deliver(nil, tap: 192_000, output: 384_000)
        try require(owner.currentTapSampleRate == 48_000 && owner.currentDeviceSampleRate == 96_000,
                    "Notification without a session changed the active state")
        owner.processor = current
        deliver(old.notificationSessionID, tap: 96_000, output: 192_000)
        try require(owner.currentTapSampleRate == 48_000 && owner.spatialControlModel.preview?.raw.sampleRate == 48_000,
                    "Retired processor notification changed preview")
        deliver(current.notificationSessionID, tap: 44_100, output: 88_200)
        try require(owner.currentTapSampleRate == 44_100 && owner.currentProcessingSampleRate == 88_200
                    && owner.currentDeviceSampleRate == 88_200,
                    "Current session did not apply its split route")
        try require(owner.spatialControlModel.processingSampleRate == 44_100
                    && owner.spatialControlModel.preview?.raw.sampleRate == 44_100,
                    "Current session preview is not precomputed at its tap rate")
        try require(SpatialControlModel.equal(owner.spatialControlModel.settings, settings)
                    && audioEdits == 0 && owner.spatialControlModel.uiEditRevision == 0
                    && !owner.spatialControlModel.hasPendingEdit,
                    "Read-only format delivery changed an audio edit")
        owner.compactSourceTitleLabel = NSTextField(labelWithString: "")
        owner.compactSourceValueLabel = NSTextField(labelWithString: "")
        owner.compactOutputLabel = NSTextField(labelWithString: "")
        owner.compactModelLabel = NSTextField(labelWithString: "")
        owner.modelSelector = NSSegmentedControl(labels: ["Clean", "Circuit", "HighExciter"],
            trackingMode: .selectOne, target: nil, action: nil)
        owner.modelSelector.selectedSegment = 0
        owner.updateCompactFormatSummary()
        try require(owner.compactOutputLabel.stringValue.contains("88.2 kHz"),
                    "Compact output must show the current session before Stop")
        try require(owner.stopAndWaitForCheck() && owner.processor == nil,
                    "Successful Stop must retire the current processor")
        try require(owner.currentDeviceSampleRate == nil && owner.currentProcessingSampleRate == nil
                    && owner.currentTapSampleRate == nil && !owner.currentLivePCM2xActive
                    && owner.compactOutputLabel.stringValue == L10n.string("main.format.outputWaiting"),
                    "Stopped compact output must not retain the previous device rate")
        deliver(old.notificationSessionID, tap: 48_000, output: 96_000)
        deliver(current.notificationSessionID, tap: 44_100, output: 88_200)
        try require(owner.currentDeviceSampleRate == nil && owner.currentProcessingSampleRate == nil
                    && owner.currentTapSampleRate == nil && !owner.currentLivePCM2xActive
                    && owner.compactOutputLabel.stringValue == L10n.string("main.format.outputWaiting"),
                    "Retired notifications must not restore a stopped output display")
        try require(old.stop() && current.stop(), "Unstarted fixture cleanup failed")
        print("SpatialFormatBridgeChecks: \(assertions) assertions; actual format notification consumer, tap/output separation, session routing, stopped compact output and retired notifications, unchanged audio edits; injected processors, no graph/window/device query.")
    }

    private func stopAnalysisPresentation() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = nil
        spectrumAnalyzer?.stop()
        spectrumAnalyzer = nil
        dynamicsMeterModel.reset()
        spectrumModel.reset()
    }

    private func showAudioStopFailure(_ failure: String) {
        currentStopFailure = failure
        statusLabel?.stringValue = L10n.format("main.status.stopIncomplete", String(describing: failure))
        rateMatchStatusText = failure
        currentLivePCM2xFallback = failure
        refreshDiagnosticsPanel()
        updateRateMatchPreview()
    }

    /// Only call after confirmed Stop, or when no processor has been created.
    private func clearStoppedAudioPresentation() {
        processor = nil
        activeTarget = nil
        refreshHeaderPresentation()
        currentStopFailure = nil
        currentProcessingFailure = nil
        if let lastSourceSnapshot { updateSourceDisplay(lastSourceSnapshot) }
        if statusLabel != nil {
            statusLabel.stringValue = L10n.string("main.monitor.state.stopped")
            statusLabel.toolTip = nil
        }
        if formatLabel != nil {
            formatLabel.stringValue = L10n.string("main.format.formatWaiting")
        }
        diagnosticsLabel?.stringValue = L10n.string("main.detail.4288e4c2ff")
        currentProcessingSampleRate = nil
        currentTapSampleRate = nil
        currentDeviceSampleRate = nil
        currentLivePCM2xActive = false
        currentLivePCM2xFallback = ""
        diagXRunValue?.stringValue = formatXRunCounts(underrun: 0, drop: 0, vis: 0)
        diagRestartValue?.stringValue = "0"
        diagCachedDeviceID = kAudioObjectUnknown
        diagCachedDeviceName = "—"
        diagDeviceNameValue?.stringValue = "—"
        diagCaptureValue?.stringValue = "—"
        diagAudioFlowValue?.stringValue = "—"
        diagAudioFlowValue?.toolTip = nil
        refreshDiagnosticsPanel()
        updateOversamplingIndicator()
        updateCompactFormatSummary()
    }

    /// Existing fixture adapters keep their Bool contract while exercising the
    /// real asynchronous delegate path and pumping the main event loop.
    private func stopAndWaitForCheck() -> Bool {
        requestStopAudio()
        let deadline = Date().addingTimeInterval(3)
        while pendingAudioOperation != nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        return pendingAudioOperation == nil && processor == nil && currentStopFailure == nil
    }

    private func startDiagnosticsTimer() {
        diagnosticsTimer?.invalidate()
        diagnosticsTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(updateDiagnostics),
            userInfo: nil,
            repeats: true
        )
    }

    private func startSourceFormatTracking() {
        let tracker = SourceFormatTracker(
            onUpdate: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateSourceDisplay(snapshot)
                }
            },
            onObservation: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    self?.observeSourceSnapshot(snapshot)
                }
            }
        )
        sourceFormatTracker = tracker
        tracker.start()
    }

    private func observeSourceSnapshot(_ snapshot: SourceFormatSnapshot) {
        lastSourceObservation = snapshot
        guard pendingAudioOperation == nil else { return }
        processor?.observeSourceFormats(snapshot.formats)
    }

    private func updateSourceDisplay(_ snapshot: SourceFormatSnapshot) {
        lastSourceSnapshot = snapshot
        let scope = processor?.capturedBundleIDs
        let selected = SourceFormatSelectionPolicy.select(formats: snapshot.formats, capturedBundleIDs: scope)
        let text = selected?.indicatorText ?? (scope == nil ? snapshot.indicatorText : L10n.string("main.detail.17e40846bd"))
        sourceFormatLabel?.stringValue = text
        sourceFormatLabel?.toolTip = text
        currentSourceSampleRate = selected?.sampleRate
        currentSourceBitDepth = selected?.bitDepth
        currentSourcePlayerName = selected?.player.displayName
        updateCompactFormatSummary()
        updateRateMatchPreview()
    }

    @objc private func updateDiagnostics() {
        guard let processor else { return }
        let snapshot = processor.diagnosticsSnapshot()
        refreshAudioFlowPresentation(snapshot)
        let applied = processor.appliedSpatialRevision
        let spatialStatus = applied >= lastSpatialSubmissionRevision
            ? L10n.format("main.detail.79b30d0268", String(describing: applied))
            : L10n.format("main.detail.d5a49e4b76", String(describing: lastSpatialSubmissionRevision), String(describing: applied))
        // Publishing an unchanged status invalidates the observed Spatial page
        // and requests another stage frame even while its scene is idle.
        if spatialControlModel.appliedStatusText != spatialStatus {
            spatialControlModel.appliedStatusText = spatialStatus
        }
        diagnosticsLabel.stringValue = snapshot.displayText
        diagnosticsLabel.toolTip = snapshot.displayText

        // Diagnostics panel — counters + device identity, refreshed at the 1 Hz
        // timer cadence (these values are not notification-driven). deviceName is
        // a CoreAudio query performed only when the device changes;
        // outputDeviceID reads an off-thread-published snapshot without waiting
        // for the manager queue or the realtime audio callback.
        if diagXRunValue != nil {
            diagXRunValue.stringValue = formatXRunCounts(
                underrun: snapshot.outputUnderrunSamples,
                drop: snapshot.outputDroppedSamples,
                vis: snapshot.visualizerDroppedSamples
            )
            diagRestartValue.stringValue = "\(snapshot.engineRestartCount)"
            diagCaptureValue.stringValue = snapshot.captureTarget
            // Resolve the device name only when the device changes (it rarely
            // does mid-session) to avoid a CoreAudio IPC on the main thread every
            // tick. outputDeviceID reads the last published device snapshot.
            let devID = processor.outputDeviceID
            if devID != diagCachedDeviceID {
                diagCachedDeviceID = devID
                diagCachedDeviceName = HardwareSampleRateTracker.deviceName(for: devID)
            }
            diagDeviceNameValue.stringValue =
                "\(diagCachedDeviceName) · 0x\(String(devID, radix: 16))"
        }
        refreshDiagnosticsPanel()
    }

    @objc private func refreshApps() {
        let apps = NSWorkspace.shared.runningApplications
            .compactMap { app -> String? in
                guard let bundleID = app.bundleIdentifier else { return nil }
                return "\(app.localizedName ?? bundleID)\t\(bundleID)"
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        appsView.string = apps.joined(separator: "\n")
    }

    @objc private func audioFormatDidChange(_ notification: Notification) {
        guard let processor,
              notification.userInfo?["processorSessionID"] as? String == processor.notificationSessionID else { return }
        let userInfo = notification.userInfo
        if let text = userInfo?[AudioFormatNotifications.indicatorTextKey] as? String {
            formatLabel?.stringValue = text
        }

        if let sampleRate = userInfo?[AudioFormatNotifications.processingSampleRateKey] as? Double {
            currentProcessingSampleRate = sampleRate
            spectrumAnalyzer?.updateSampleRate(Float(sampleRate))
        }
        if let tapRate = userInfo?[AudioFormatNotifications.tapSampleRateKey] as? Double {
            currentTapSampleRate = tapRate
            spatialControlModel.processingSampleRate = Float(tapRate)
        }
        if let deviceRate = userInfo?[AudioFormatNotifications.sampleRateKey] as? Double {
            currentDeviceSampleRate = deviceRate
        }
        if let format = userInfo?[AudioFormatNotifications.sampleFormatKey] as? String {
            currentOutputSampleFormat = format
        }
        supportedDeviceSampleRates =
            userInfo?[AudioFormatNotifications.supportedSampleRatesKey] as? [Double]
            ?? supportedDeviceSampleRates
        isDeviceSampleRateSettable =
            userInfo?[AudioFormatNotifications.isSampleRateSettableKey] as? Bool
            ?? isDeviceSampleRateSettable
        if pendingAudioOperation == nil, let enabled =
            userInfo?[AudioFormatNotifications.automaticRateMatchingEnabledKey] as? Bool {
            automaticRateMatchingEnabled = enabled
            automaticRateMatchButton?.state = enabled ? .on : .off
        }
        rateMatchStatusText =
            userInfo?[AudioFormatNotifications.rateMatchStatusKey] as? String
            ?? rateMatchStatusText

        // Live PCM 2× conditioning state is posted separately by
        // publishLivePCM2xStatus WITHOUT an indicatorTextKey, so it must be
        // consumed here regardless of whether the format indicator is present.
        if let active = userInfo?[AudioFormatNotifications.livePCM2xActiveKey] as? Bool {
            currentLivePCM2xActive = active
        }
        if let fallback = userInfo?[AudioFormatNotifications.livePCM2xFallbackKey] as? String {
            currentLivePCM2xFallback = fallback
            if let processing = userInfo?[AudioFormatNotifications.isProcessingKey] as? Bool {
                let hadFailure = currentProcessingFailure != nil
                currentProcessingFailure = !processing && !fallback.isEmpty ? fallback : nil
                if let failure = currentProcessingFailure {
                    statusLabel?.stringValue = L10n.string("main.detail.fb1550dce6")
                    statusLabel?.toolTip = failure
                } else if hadFailure && processing {
                    refreshAudioFlowPresentation()
                }
            }
        }

        // Activation uses an earlier parameter snapshot. Deliver edits made
        // while it was pending only after a successful, matching-session result.
        // Inactive/fallback notifications never retry a device transition.
        if currentLivePCM2xActive && pendingHeadroomEdit && outputConditioningEnabled
            && OutputConditioningMode(rawValue: outputConditioningModeRaw) == .pcmOversampling
            && outputConditioningFactor == 2 {
            pushActiveHeadroomSettings()
        }
        updateCompactFormatSummary()
        updateRateMatchPreview()
        updateOversamplingIndicator()
        refreshDiagnosticsPanel()
        refreshAudioOperationPresentation()
    }

    private func refreshRateMatchDeviceCapabilities() {
        do {
            let deviceID = try HardwareSampleRateTracker.defaultOutputDevice()
            diagCachedDeviceID = deviceID
            diagCachedDeviceName = HardwareSampleRateTracker.deviceName(for: deviceID)
            let capabilities = try HardwareSampleRateTracker.rateCapabilities(for: deviceID)
            currentDeviceSampleRate = try HardwareSampleRateTracker.nominalSampleRate(for: deviceID)
            supportedDeviceSampleRates = capabilities.supportedRates
            isDeviceSampleRateSettable = capabilities.isSettable
        } catch {
            currentDeviceSampleRate = nil
            supportedDeviceSampleRates = []
            isDeviceSampleRateSettable = false
        }
        updateCompactFormatSummary()
        updateRateMatchPreview()
        refreshHeaderPresentation()
    }

    private func updateRateMatchPreview() {
        let preview = SourceRateMatchPolicy.preview(
            sourceRate: currentSourceSampleRate,
            currentDeviceRate: currentDeviceSampleRate,
            supportedRates: supportedDeviceSampleRates,
            isDeviceRateSettable: isDeviceSampleRateSettable
        )
        rateMatchPreviewLabel?.stringValue = "\(preview.indicatorText) | \(rateMatchStatusText)"
        rateMatchPreviewLabel?.toolTip =
            L10n.format("main.detail.934e62b10b", String(describing: preview.indicatorText), String(describing: rateMatchStatusText))
    }

}

private final class TopAlignedDocument: NSView { override var isFlipped: Bool { true } }

private var nativeAppDelegateHolder: AnyObject?

@available(macOS 14.4, *)
@MainActor
private func launchGUI() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    installMainMenu(for: app)
    let delegate = NativeAppDelegate()
    nativeAppDelegateHolder = delegate
    app.delegate = delegate
    app.finishLaunching()
    app.run()
    exit(0)
}

@available(macOS 14.4, *)
@MainActor
private func installMainMenu(for app: NSApplication) {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu(title: "LowEnd Native Audio")
    let quitItem = NSMenuItem(
        title: L10n.string("main.detail.ab2c02d0e9"),
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    quitItem.keyEquivalentModifierMask = [.command]
    quitItem.target = app
    appMenu.addItem(quitItem)
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)

    // Native text fields depend on the application's responder-chain edit
    // commands for keyboard shortcuts such as Command-A/C/V. A Quit-only menu
    // leaves precision editing with no standard Select All command.
    let editMenuItem = NSMenuItem()
    let editMenu = NSMenu(title: L10n.string("main.menu.edit"))
    for (title, action, key) in [
        (L10n.string("main.menu.undo"), "undo:", "z"),
        (L10n.string("main.menu.cut"), "cut:", "x"),
        (L10n.string("main.menu.copy"), "copy:", "c"),
        (L10n.string("main.menu.paste"), "paste:", "v"),
        (L10n.string("main.menu.selectAll"), "selectAll:", "a")
    ] {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = [.command]
        // A nil target routes the command to the current native field editor.
        editMenu.addItem(item)
    }
    let redo = NSMenuItem(title: L10n.string("main.menu.redo"), action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    editMenu.insertItem(redo, at: 1)
    editMenu.insertItem(.separator(), at: 2)
    editMenuItem.submenu = editMenu
    mainMenu.addItem(editMenuItem)
    app.mainMenu = mainMenu
}

private func printUsageAndExit() -> Never {
    print("""
    SystemAudioProcessor

    Usage:
      SystemAudioProcessor --all
      SystemAudioProcessor --bundle-id com.spotify.client
      SystemAudioProcessor --list-apps
      SystemAudioProcessor --self-test
      SystemAudioProcessor --ui-self-test
      SystemAudioProcessor --benchmark-output-conditioning

    With no arguments, open the app. Diagnostics and the offline benchmark
    above do not start audio capture. Use each diagnostic flag on its own.

    Options:
      --intensity 0...100
      --body 0...100
      --output -18...6 dB
      --model clean|circuit|highexciter
      --spatial on|off
      --listener-x -3...3 meters
      --listener-z -2.8...2.8 meters
      --stage-width 0.6...3 meters
      --space 0...100
    """)
    exit(0)
}

private func listRunningApps() {
    let apps = NSWorkspace.shared.runningApplications
        .compactMap { app -> (String, String, pid_t)? in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return (app.localizedName ?? bundleID, bundleID, app.processIdentifier)
        }
        .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

    for app in apps {
        print("\(app.0)\t\(app.1)\tpid=\(app.2)")
    }
}


do {
    if CommandLine.arguments.count == 1 {
        guard #available(macOS 14.4, *) else {
            throw AppError.message("Native system audio processing requires macOS 14.4 or newer.")
        }
        launchGUI()
    }

    if CommandLine.arguments.dropFirst() == ["--benchmark-output-conditioning"] {
        runOutputConditioningBenchmark()
        exit(0)
    }
    if CommandLine.arguments.dropFirst() == ["--ui-self-test"] {
        guard #available(macOS 14.4, *) else { throw AppError.message("UI checks need macOS 14.4") }
        try runSpatialUIChecks()
        try NativeAppDelegate.runSpatialDiagnosticsChecks()
        try NativeAppDelegate.runSpatialFormatBridgeChecks()
        try NativeAppDelegate.runRedesignWindowChecks()
        try NativeAppDelegate.runOutputConditioningPresentationChecks()
        try NativeAppDelegate.runTrebleSignalChecks()
        try NativeAppDelegate.runLiveControlEditingChecks()
        try NativeAppDelegate.runGUIAudioLifecycleChecks()
        exit(0)
    }
    let settings = try parseArguments()

    if case .listApps = settings.mode {
        listRunningApps()
        exit(0)
    }
    if case .selfTest = settings.mode {
        try L10n.runOfflineChecks()
        try RedesignPreferences.runOfflineChecks()
        try runInputValidationChecks()
        try runDSPParityChecks()
        try runOutputConditioningChecks()
        try runRuntimeChecks()
        try runSourceFormatTrackerChecks()
        try AudioSpectrumAnalyzer.runOfflineChecks()
        if #available(macOS 14.4, *) {
            try NativeAppDelegate.runStopRestorationChecks()
            try SystemAudioProcessor.runManagerResponsivenessChecks()
            try SystemAudioProcessor.runCaptureTargetRefreshChecks()
            try SystemAudioProcessor.runInputBufferLayoutChecks()
            try AudioGraphChecks.run()
            try HardwareEventChecks.run()
            try NativeAppDelegate.runCaptureSessionChecks()
        }
        exit(0)
    }

    guard #available(macOS 14.4, *) else {
        throw AppError.message("Native system audio processing requires macOS 14.4 or newer.")
    }

    let processor = try SystemAudioProcessor(settings: settings)
    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
        if processor.stop() {
            exit(0)
        }
        let reason = processor.stopFailureDescription
        fputs(L10n.format("main.detail.e1700d5bad", String(describing: reason)), stderr)
    }
    signalSource.resume()

    try processor.start()
    RunLoop.main.run()
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
