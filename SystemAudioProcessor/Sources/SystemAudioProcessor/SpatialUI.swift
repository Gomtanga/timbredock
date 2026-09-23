import AppKit
import Combine
import SceneKit
import SwiftUI
import LowEndDSPCoreC
import simd

// SDK 27 also exports a State macro whose plugin is absent from some CLT
// installations. Name the public State<Value> property-wrapper type explicitly
// to preserve the same storage and Binding behavior used on earlier SDKs.
private typealias SpatialViewState<Value> = SwiftUI.State<Value>

struct SpatialSceneState: Equatable {
    enum ViewMode: String, CaseIterable { case planar, perspective }
    enum Selection: String, CaseIterable { case none, listener, leftSpeaker, rightSpeaker }
    var viewMode: ViewMode = .planar
    var selection: Selection = .none
    var showGrid = true
    var showPaths = true
    var showDetails = false
    var cameraOrbit: Float = 0
    var cameraElevation: Float = 55 * .pi / 180
    var cameraZoom: Float = 8.5
    var cameraPan = SIMD2<Float>.zero

    mutating func fitCamera() {
        cameraOrbit = 0
        cameraElevation = 55 * .pi / 180
        cameraZoom = 8.5
        cameraPan = .zero
    }
}

/// Object and source-path colors stay identical in the planar and 3D scene.
/// Text labels and solid/dashed paths retain meaning without color perception.
private enum SpatialPalette {
    static let left = NSColor(srgbRed: 0.31, green: 0.88, blue: 0.76, alpha: 1)
    static let right = NSColor(srgbRed: 1, green: 0.57, blue: 0.49, alpha: 1)
    static let listener = NSColor(srgbRed: 0.71, green: 0.63, blue: 1, alpha: 1)
    static let background = NSColor(white: 0.027, alpha: 1)
    static var accent: NSColor { NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? left : NSColor(srgbRed: 0, green: 0.43, blue: 0.36, alpha: 1)
    } }
    static func color(for selection: SpatialSceneState.Selection) -> NSColor {
        switch selection {
        case .leftSpeaker: return left
        case .rightSpeaker: return right
        case .listener, .none: return listener
        }
    }
    static func pathText(leftChannel: Bool) -> NSColor { NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua { return leftChannel ? left : right }
        return leftChannel ? NSColor(srgbRed: 0, green: 0.43, blue: 0.36, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.24, blue: 0.17, alpha: 1)
    } }
}

@MainActor
final class SpatialControlModel: ObservableObject {
    @Published private(set) var settings: SpatialSettings
    @Published private(set) var preview: SpatialGeometrySnapshot?
    @Published private(set) var validationMessage: String?
    @Published private(set) var hasPendingEdit = false
    @Published var appliedStatusText: String?
    private(set) var uiEditRevision: UInt64 = 0
    private(set) var submittedEditRevision: UInt64 = 0
    @Published var processingSampleRate: Float = 48_000 {
        didSet {
            guard processingSampleRate.isFinite, processingSampleRate > 0,
                  processingSampleRate <= 768_000 else {
                processingSampleRate = oldValue
                return
            }
            updatePreview()
        }
    }
    @Published var sceneState: SpatialSceneState {
        didSet {
            // Camera and selection are session state. Only these three visual
            // preferences persist, and none of them submits an audio edit.
            if oldValue.viewMode != sceneState.viewMode {
                preferences.set(sceneState.viewMode.rawValue, forKey: "spatial.ui.viewMode")
            }
            if oldValue.showGrid != sceneState.showGrid {
                preferences.set(sceneState.showGrid, forKey: "spatial.ui.showGrid")
            }
            if oldValue.showPaths != sceneState.showPaths {
                preferences.set(sceneState.showPaths, forKey: "spatial.ui.showPaths")
            }
        }
    }
    var onChange: ((SpatialSettings) -> Void)?
    private let preferences: UserDefaults
    private var pendingSettings: SpatialSettings?
    private var publishTimer: Timer?
    private(set) var publishedEditCount = 0

    init(settings: SpatialSettings = SpatialSettings(), preferences: UserDefaults = .standard) {
        self.settings = Self.validated(settings, fallback: SpatialSettings())
        self.preferences = preferences
        var state = SpatialSceneState()
        state.viewMode = SpatialSceneState.ViewMode(rawValue:
            preferences.string(forKey: "spatial.ui.viewMode") ?? "") ?? .planar
        state.showGrid = preferences.object(forKey: "spatial.ui.showGrid") as? Bool ?? true
        state.showPaths = preferences.object(forKey: "spatial.ui.showPaths") as? Bool ?? true
        self.sceneState = state
        updatePreview()
    }

    /// Reflect external state without creating another DSP event.
    func update(_ newSettings: SpatialSettings) {
        let safe = Self.validated(newSettings, fallback: settings)
        guard !Self.equal(safe, settings) else { return }
        settings = safe
        updatePreview()
    }

    @discardableResult
    func applyEdit(_ newSettings: SpatialSettings, final: Bool = false) -> Bool {
        let values = [newSettings.listenerX, newSettings.listenerZ,
                      newSettings.speakerWidth, newSettings.amount]
        guard values.allSatisfy(\.isFinite) else {
            validationMessage = L10n.string("spatial.validation.finite")
            if final { commit() }
            return false
        }
        validationMessage = nil
        let safe = Self.validated(newSettings, fallback: settings)
        let changed = !Self.equal(safe, settings)
        if changed {
            uiEditRevision &+= 1
            settings = safe
            updatePreview()
            pendingSettings = safe
            hasPendingEdit = true
        }
        if final {
            commit()
        } else if changed, publishTimer == nil {
            // A single latest-value slot and a one-shot common-mode timer keep
            // pointer tracking responsive without queuing every intermediate edit.
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPending() }
            }
            publishTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        return changed
    }

    func mutate(final: Bool = false, _ mutation: (inout SpatialSettings) -> Void) {
        var edited = settings
        mutation(&edited)
        applyEdit(edited, final: final)
    }

    /// Final commits bypass the timer; manager-side retry/ack is a separate layer.
    func commit() {
        publishTimer?.invalidate()
        publishTimer = nil
        pendingSettings = nil
        hasPendingEdit = false
        submittedEditRevision = uiEditRevision
        publishedEditCount += 1
        onChange?(settings)
    }

    func flushPending() {
        publishTimer?.invalidate()
        publishTimer = nil
        guard let latest = pendingSettings else { return }
        pendingSettings = nil
        hasPendingEdit = false
        submittedEditRevision = uiEditRevision
        publishedEditCount += 1
        onChange?(latest)
    }

    func resetListener() { mutate(final: true) { $0.listenerX = 0; $0.listenerZ = 0 } }
    func resetSpatial() { applyEdit(SpatialSettings(), final: true) }

    private func updatePreview() {
        preview = SpatialGeometrySnapshot.make(sampleRate: processingSampleRate, settings: settings)
    }

    static func equal(_ a: SpatialSettings, _ b: SpatialSettings) -> Bool {
        a.enabled == b.enabled && a.listenerX == b.listenerX && a.listenerZ == b.listenerZ
            && a.speakerWidth == b.speakerWidth && a.amount == b.amount
    }

    static func validated(_ value: SpatialSettings, fallback: SpatialSettings) -> SpatialSettings {
        var safe = value
        safe.listenerX = value.listenerX.isFinite ? min(3, max(-3, value.listenerX)) : fallback.listenerX
        safe.listenerZ = value.listenerZ.isFinite ? min(2.8, max(-2.8, value.listenerZ)) : fallback.listenerZ
        safe.speakerWidth = value.speakerWidth.isFinite ? min(3, max(0.6, value.speakerWidth)) : fallback.speakerWidth
        safe.amount = value.amount.isFinite ? min(100, max(0, value.amount)) : fallback.amount
        return safe
    }
}

@available(macOS 14.4, *)
struct SpatialStageRepresentable: NSViewRepresentable {
    @ObservedObject var model: SpatialControlModel
    let onChange: (SpatialSettings) -> Void
    var onFocus: () -> Void = {}

    func makeNSView(context: Context) -> SpatialStageView {
        let view = SpatialStageView(frame: .zero)
        view.onFocus = onFocus
        view.bind(model: model, onChange: onChange)
        return view
    }
    func updateNSView(_ nsView: SpatialStageView, context: Context) {
        nsView.onFocus = onFocus
        nsView.bind(model: model, onChange: onChange)
    }
    static func dismantleNSView(_ nsView: SpatialStageView, coordinator: ()) {
        nsView.finishPendingEdit()
    }
}

@available(macOS 14.4, *)
struct SpatialPageView: View {
    @ObservedObject var spatialModel: SpatialControlModel
    let onSpatialChange: (SpatialSettings) -> Void
    private enum PageFocus: Hashable {
        case viewMode, enabled, resetListener, resetSpatial, fit, grid, paths
        case selection, inspectorReset, details
        var scrollID: String {
            switch self {
            case .selection: return "spatial.selection"
            case .inspectorReset: return "spatial.inspectorReset"
            case .details: return "spatial.details"
            default: return "spatial.toolbar"
            }
        }
    }
    @FocusState private var pageFocus: PageFocus?
    @SpatialViewState<String?> private var revealTarget: String?
    @SpatialViewState<UInt64> private var revealRevision: UInt64 = 0

    var body: some View {
        GeometryReader { page in
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(L10n.string("spatial.page.title")).font(.system(size: 26, weight: .bold))
                                Spacer()
                                ContextualHelp(text: L10n.string("spatial.page.subtitle"), title: L10n.string("spatial.page.title"), onFocus: { reveal("spatial.toolbar") })
                                    .frame(width: 28, height: 28)
                            }
                        }
                        toolbar.id("spatial.toolbar")
                        if page.size.width >= 860 {
                            HStack(alignment: .top, spacing: 16) {
                                stage(height: max(360, min(620, page.size.height - 184)))
                                inspector.frame(width: 290)
                            }
                        } else {
                            stage(height: max(320, min(440, (page.size.width - 56) * 0.68)))
                            inspector
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onChange(of: revealRevision) { _, _ in
                    guard let revealTarget else { return }
                    // No animation: retain the native field editor and make a
                    // keyboard destination visible in the same focus change.
                    scroll.scrollTo(revealTarget, anchor: revealTarget == "spatial.details" ? .top : .center)
                }
            }
        }
        .foregroundStyle(Color.primary)
        .tint(Color(nsColor: SpatialPalette.accent))
        .background(Color(nsColor: GlassDesign.surface))
        .onAppear { spatialModel.onChange = onSpatialChange }
        .onDisappear { spatialModel.flushPending() }
        .onChange(of: pageFocus) { _, focused in
            if let focused { reveal(focused.scrollID) }
        }
    }

    private func reveal(_ target: String) {
        guard SpatialFocusRevealPolicy.shouldReveal else { return }
        revealTarget = target
        // Moving among controls in one row must reveal it again even if the
        // user scrolled manually after the previous focus event.
        revealRevision &+= 1
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack {
                StudioChoice(items: [(SpatialSceneState.ViewMode.planar, L10n.string("spatial.view.planar")),
                                     (.perspective, L10n.string("spatial.view.perspective"))],
                             selection: $spatialModel.sceneState.viewMode, label: L10n.string("spatial.view.label"),
                             onFocus: { reveal("spatial.toolbar") })
                    .frame(width: 176, height: 36)
                Spacer(minLength: 12)
                Toggle(spatialModel.settings.enabled ? L10n.string("spatial.enabledOn")
                                                     : L10n.string("spatial.enabledOff"),
                       isOn: Binding(get: { spatialModel.settings.enabled },
                                     set: { value in spatialModel.mutate(final: true) { $0.enabled = value } }))
                    .toggleStyle(.checkbox).font(.system(size: 12, weight: .semibold))
                    .focused($pageFocus, equals: .enabled)
            }
            HStack(spacing: 8) {
                toolButton(L10n.string("spatial.resetListener"), symbol: "location.fill.viewfinder") { spatialModel.resetListener() }
                    .focused($pageFocus, equals: .resetListener)
                toolButton(L10n.string("spatial.resetAll"), symbol: "arrow.counterclockwise") { spatialModel.resetSpatial() }
                    .focused($pageFocus, equals: .resetSpatial)
                toolButton(L10n.string("spatial.fitCamera"), symbol: "arrow.up.left.and.arrow.down.right") {
                    spatialModel.sceneState.fitCamera()
                }.focused($pageFocus, equals: .fit)
                Spacer(minLength: 8)
                Toggle(L10n.string("spatial.grid"), isOn: $spatialModel.sceneState.showGrid).toggleStyle(.checkbox)
                    .focused($pageFocus, equals: .grid)
                Toggle(L10n.string("spatial.paths"), isOn: $spatialModel.sceneState.showPaths).toggleStyle(.checkbox)
                    .focused($pageFocus, equals: .paths)
            }.font(.system(size: 12))
        }
    }

    private func toolButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28) }
                    .buttonStyle(.glass)
            } else {
                Button(action: action) { Image(systemName: symbol).frame(width: 28, height: 28) }
                    .buttonStyle(.bordered)
            }
        }.tint(Color.primary).help(label).accessibilityLabel(label)
    }

    private func stage(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SpatialStageRepresentable(model: spatialModel, onChange: onSpatialChange,
                                      onFocus: { reveal("spatial.stage") })
                .frame(maxWidth: .infinity).frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .id("spatial.stage")
            HStack {
                Spacer()
                ContextualHelp(text: spatialModel.sceneState.viewMode == .planar
                    ? L10n.string("spatial.stageHint.planar") : L10n.string("spatial.stageHint.perspective"),
                    title: L10n.string("spatial.view.label"), onFocus: { reveal("spatial.stageHelp") })
                    .id("spatial.stageHelp")
                    .frame(width: 28, height: 28)
            }
        }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("spatial.inspector.target")).font(.system(size: 14, weight: .semibold))
            StudioChoice(items: [(SpatialSceneState.Selection.none, L10n.string("spatial.selection.none")),
                                 (.listener, L10n.string("spatial.selection.listener")),
                                 (.leftSpeaker, L10n.string("spatial.selection.left")),
                                 (.rightSpeaker, L10n.string("spatial.selection.right"))],
                         selection: $spatialModel.sceneState.selection,
                         label: L10n.string("spatial.selection.accessibilityLabel"), compact: true,
                         onFocus: { reveal("spatial.selection") })
                .frame(height: 36).id("spatial.selection")
            switch spatialModel.sceneState.selection {
            case .listener:
                valueControl(L10n.string("spatial.value.listenerX"), id: "listenerX", key: \.listenerX, range: -3...3, unit: L10n.string("spatial.unit.meters"))
                valueControl(L10n.string("spatial.value.listenerZ"), id: "listenerZ", key: \.listenerZ, range: -2.8...2.8, unit: L10n.string("spatial.unit.meters"))
                ContextualHelp(text: L10n.string("spatial.inspector.axisHint"), title: L10n.string("spatial.inspector.target"), onFocus: { reveal("spatial.inspectorHelp") })
                    .id("spatial.inspectorHelp")
                    .frame(width: 28, height: 28)
                Button(L10n.string("spatial.resetListener")) { spatialModel.resetListener() }.buttonStyle(.bordered)
                    .focused($pageFocus, equals: .inspectorReset).id("spatial.inspectorReset")
            case .leftSpeaker, .rightSpeaker:
                valueControl(L10n.string("spatial.value.speakerWidth"), id: "speakerWidth", key: \.speakerWidth, range: 0.6...3, unit: L10n.string("spatial.unit.meters"))
                ContextualHelp(text: L10n.string("spatial.inspector.widthHint"), title: L10n.string("spatial.inspector.target"), onFocus: { reveal("spatial.inspectorHelp") })
                    .id("spatial.inspectorHelp")
                    .frame(width: 28, height: 28)
            case .none:
                ContextualHelp(text: L10n.string("spatial.inspector.noneHint"), title: L10n.string("spatial.inspector.target"), onFocus: { reveal("spatial.inspectorHelp") })
                    .id("spatial.inspectorHelp")
                    .frame(width: 28, height: 28)
            }
            Divider()
            valueControl(L10n.string("spatial.value.amount"), id: "amount", key: \.amount, range: 0...100, unit: "%")
            Text(!spatialModel.settings.enabled ? L10n.string("spatial.amountHint.off")
                 : spatialModel.settings.amount == 0 ? L10n.string("spatial.amountHint.zero")
                 : L10n.string("spatial.amountHint.on"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let message = spatialModel.validationMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.orange)
            }
            DisclosureGroup(L10n.string("spatial.details.title"), isExpanded: $spatialModel.sceneState.showDetails) {
                geometryInspector.padding(.top, 8)
            }
                .font(.system(size: 12, weight: .semibold))
                .focused($pageFocus, equals: .details).id("spatial.details")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: GlassDesign.well))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func valueControl(_ title: String, id: String, key: WritableKeyPath<SpatialSettings, Float>,
    range: ClosedRange<Double>, unit: String) -> some View {
        SpatialValueControl(title: title, value: Binding(
            get: { Double(spatialModel.settings[keyPath: key]) },
            set: { value in spatialModel.mutate { $0[keyPath: key] = Float(value) } }),
            range: range, unit: unit, commit: { spatialModel.commit() }, onFocus: { reveal("spatial.value.\(id)") })
            .id("spatial.value.\(id)")
    }

    @ViewBuilder private var geometryInspector: some View {
        if let snapshot = spatialModel.preview {
            let raw = snapshot.raw
            VStack(alignment: .leading, spacing: 8) {
                Text(spatialModel.hasPendingEdit ? L10n.string("spatial.details.pending")
                     : spatialModel.submittedEditRevision == 0 ? L10n.string("spatial.details.preview")
                     : L10n.string("spatial.details.submitted"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(spatialModel.appliedStatusText ?? L10n.string("spatial.details.noDeviceStatus"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(L10n.format("spatial.details.rateRelativeDelay", raw.sampleRate / 1000))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                pathRow(L10n.string("spatial.path.ll"), raw.ll, leftChannel: true)
                pathRow(L10n.string("spatial.path.lr"), raw.lr, leftChannel: true)
                pathRow(L10n.string("spatial.path.rl"), raw.rl, leftChannel: false)
                pathRow(L10n.string("spatial.path.rr"), raw.rr, leftChannel: false)
                Text(L10n.format("spatial.details.crossfeed", raw.crossfeed))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                ContextualHelp(text: L10n.string("spatial.details.gainNote"), title: L10n.string("spatial.details.title"), onFocus: { reveal("spatial.detailsHelp") })
                    .id("spatial.detailsHelp")
                    .frame(width: 28, height: 28)
            }
        } else {
            Text(L10n.string("spatial.details.waitingRate")).font(.system(size: 11))
        }
    }

    private func pathRow(_ label: String, _ path: LCSpatialPathGeometry, leftChannel: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
        Text(label).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(nsColor: SpatialPalette.pathText(leftChannel: leftChannel)))
        Text(L10n.format("spatial.pathRow.metrics", path.rawDistanceMeters, path.gain,
                         path.appliedDelayMs, path.appliedDelaySamples))
            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        if path.rawDistanceMeters < path.effectiveDistanceMeters {
            Text(L10n.format("spatial.pathRow.distanceFloor", path.effectiveDistanceMeters))
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        if path.requestedDelaySamples != path.appliedDelaySamples {
            Text(L10n.string("spatial.pathRow.delayLimited")).font(.system(size: 10)).foregroundStyle(.orange)
        }
        }.accessibilityElement(children: .combine)
    }
}

@available(macOS 14.4, *)
private struct SpatialValueControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let unit: String
    let commit: () -> Void
    let onFocus: () -> Void
    @SpatialViewState<String> private var text = ""
    @SpatialViewState<Bool> private var invalid = false
    @SpatialViewState<Bool> private var hasUncommittedText = false
    @FocusState private var editing: Bool
    private enum ControlFocus: Hashable { case decrease, increase, slider }
    @FocusState private var controlFocus: ControlFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                TextField(title, text: Binding(get: { text }, set: {
                    guard text != $0 else { return }
                    text = $0
                    hasUncommittedText = true
                }))
                .textFieldStyle(.roundedBorder).frame(width: 66)
                .multilineTextAlignment(.trailing).focused($editing)
                .onSubmit { finishText() }
                .accessibilityLabel(L10n.format("spatial.control.range", title, unit,
                                                String(range.lowerBound), String(range.upperBound)))
                Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                HStack(spacing: 2) {
                    Button { step(-1) } label: { Image(systemName: "minus").frame(width: 28, height: 28) }
                        .disabled(value <= range.lowerBound).accessibilityLabel(L10n.format("spatial.control.decrease", title))
                        .focused($controlFocus, equals: .decrease)
                    Button { step(1) } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                        .disabled(value >= range.upperBound).accessibilityLabel(L10n.format("spatial.control.increase", title))
                        .focused($controlFocus, equals: .increase)
                }.buttonStyle(.borderless).accessibilityElement(children: .contain)
            }
            Slider(value: Binding(get: { value }, set: { newValue in
                // An absolute slider edit supersedes the draft before a late
                // text-field blur can commit its previous value.
                hasUncommittedText = false
                invalid = false
                value = newValue
                text = String(format: unit == "%" ? "%.0f" : "%.2f", newValue)
            }), in: range, onEditingChanged: { active in if !active { commit() } })
            .accessibilityLabel(L10n.format("spatial.control.slider", title, unit))
            .focused($controlFocus, equals: .slider)
            if invalid {
                Text(L10n.string("spatial.control.invalid")).font(.system(size: 10)).foregroundStyle(.orange)
            }
        }
        .onAppear { refresh() }
        .onChange(of: value) { _, _ in
            if !editing && !hasUncommittedText { invalid = false; refresh() }
        }
        .onChange(of: editing) { _, focused in
            if focused { onFocus() } else { finishText() }
        }
        .onChange(of: controlFocus) { _, focused in if focused != nil { onFocus() } }
        .onDisappear { if hasUncommittedText { finishText() } }
    }
    private func refresh() { text = String(format: unit == "%" ? "%.0f" : "%.2f", value) }
    private var parsedText: Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let number = Double(input), number.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, number))
    }
    private func finishText() {
        // FocusState's blur notification can follow a button action. Once a
        // draft was consumed, use the current model, never its older display.
        guard hasUncommittedText else { refresh(); commit(); return }
        hasUncommittedText = false
        guard let number = parsedText else { invalid = true; refresh(); return }
        invalid = false
        value = number
        refresh()
        commit()
    }
    private func step(_ direction: Double) {
        // Native focus and press can arrive in one turn before blur commits.
        // Only an actual user draft may override an externally updated value.
        let base = hasUncommittedText ? (parsedText ?? value) : value
        hasUncommittedText = false
        invalid = false
        value = min(range.upperBound, max(range.lowerBound, base + direction * (unit == "%" ? 1 : 0.01)))
        refresh()
        commit()
    }
}

/// Revealing keyboard focus must not move the stage beneath an active pointer.
/// The native scope also covers direct AppKit event dispatch in offscreen tests;
/// currentEvent covers SwiftUI focus callbacks after the native handler returns.
@MainActor
enum SpatialFocusRevealPolicy {
    private static var pointerDepth = 0
    static var shouldReveal: Bool {
        guard pointerDepth == 0 else { return false }
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel:
            return false
        default:
            return true
        }
    }
    static func beginPointerInteraction() { pointerDepth += 1 }
    static func endPointerInteraction() { pointerDepth -= 1 }
}

/// NSViewRepresentable descendants need a native first-responder hook because
/// SwiftUI FocusState does not own their internal AppKit selection buttons.
@MainActor
private final class SpatialFocusButton: StudioButton {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if SpatialFocusRevealPolicy.shouldReveal { onFocus?() }
        return true
    }
    override func mouseDown(with event: NSEvent) {
        SpatialFocusRevealPolicy.beginPointerInteraction()
        defer { SpatialFocusRevealPolicy.endPointerInteraction() }
        super.mouseDown(with: event)
    }
}

/// Screen annotation, separate from the four acoustic paths. It never consumes
/// pointer events and reuses its path object when the selected glyph moves.
@MainActor
final class SpatialSelectionLeaderView: NSView {
    private let path = NSBezierPath()
    private(set) var startPoint = NSPoint.zero
    private(set) var endPoint = NSPoint.zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func connect(from start: NSPoint, to end: NSPoint) {
        startPoint = start; endPoint = end
        path.removeAllPoints(); path.move(to: start); path.line(to: end)
        path.lineWidth = 1
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        // Neutral annotation leaders remain distinct from the colored DSP paths.
        NSColor(white: 0.55, alpha: 0.8).setStroke()
        path.stroke()
    }
}

@available(macOS 14.4, *)
@MainActor
final class SpatialStageView: SCNView {
    var onChange: ((SpatialSettings) -> Void)? { didSet { model.onChange = onChange } }
    var onFocus: (() -> Void)?
    private var model = SpatialControlModel()
    private let listenerNode = SCNNode()
    private let listenerRingNode = SCNNode()
    private let leftSpeakerNode = SCNNode()
    private let rightSpeakerNode = SCNNode()
    private let leftEarNode = SCNNode()
    private let rightEarNode = SCNNode()
    private let widthNode = SCNNode()
    private let gridNode = SCNNode()
    private let planarCamera = SCNNode()
    private let perspectiveCamera = SCNNode()
    private let pathNodes: [[SCNNode]] = (0..<4).map { path in (0..<(path == 0 || path == 3 ? 1 : 12)).map { _ in SCNNode() } }
    private let listenerButton = SpatialFocusButton(title: L10n.string("spatial.selection.listener"), target: nil, action: nil)
    private let leftButton = SpatialFocusButton(title: L10n.string("spatial.selection.left"), target: nil, action: nil)
    private let rightButton = SpatialFocusButton(title: L10n.string("spatial.selection.right"), target: nil, action: nil)
    private let frontLabel = NSTextField(labelWithString: L10n.string("spatial.stage.front"))
    private let widthLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let selectionCoordinates = NSTextField(labelWithString: "")
    private let selectionLeader = SpatialSelectionLeaderView(frame: .zero)
    private let objectLabelLeaders = (0..<3).map { _ in SpatialSelectionLeaderView(frame: .zero) }
    private enum DragKind { case listener, leftSpeaker, rightSpeaker, orbit, pan }
    private var dragKind: DragKind?
    private var dragStartSettings = SpatialSettings()
    private var dragOffset = SIMD2<Float>.zero
    private var lastPointer = NSPoint.zero
    private var editedDuringDrag = false

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if SpatialFocusRevealPolicy.shouldReveal { onFocus?() }
        return true
    }

    override init(frame frameRect: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frameRect, options: options)
        setupScene()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); setupScene() }

    func bind(model: SpatialControlModel, onChange: @escaping (SpatialSettings) -> Void) {
        self.model = model
        self.onChange = onChange
        renderState()
    }
    func setSettings(_ settings: SpatialSettings) { model.update(settings); renderState() }
    func finishPendingEdit() { model.flushPending() }
    override func layout() { super.layout(); renderState() }

    static func scenePoint(x: Float, z: Float, height: Float = 0) -> SCNVector3 { SCNVector3(x, height, -z) }

    // SCNView.projectPoint/unprojectPoint may retain the last rendered camera or
    // viewport during layout/camera changes. Resolve both directions from the
    // model camera and current logical-point bounds, without requesting a frame.
    private var stageViewProjection: simd_float4x4? {
        guard bounds.width > 1, bounds.height > 1,
              let pointOfView, let camera = pointOfView.camera else { return nil }
        let projection = simd_float4x4(camera.projectionTransform(withViewportSize: bounds.size))
        return projection * simd_inverse(pointOfView.simdWorldTransform)
    }

    func projectStagePoint(_ world: SCNVector3) -> SCNVector3 {
        guard let matrix = stageViewProjection else { return SCNVector3(Float.nan, Float.nan, Float.nan) }
        let clip = matrix * SIMD4<Float>(Float(world.x), Float(world.y), Float(world.z), 1)
        guard clip.w.isFinite, abs(clip.w) > 0.000001 else { return SCNVector3(Float.nan, Float.nan, Float.nan) }
        let ndc = clip / clip.w
        return SCNVector3((ndc.x + 1) * Float(bounds.width) / 2,
                          (ndc.y + 1) * Float(bounds.height) / 2, (ndc.z + 1) / 2)
    }

    private func unprojectStagePoint(_ screen: SCNVector3) -> SCNVector3 {
        guard let matrix = stageViewProjection else { return SCNVector3(Float.nan, Float.nan, Float.nan) }
        let ndc = SIMD4<Float>(2 * Float(screen.x) / Float(bounds.width) - 1,
                              2 * Float(screen.y) / Float(bounds.height) - 1, 2 * Float(screen.z) - 1, 1)
        let world = simd_inverse(matrix) * ndc
        guard world.w.isFinite, abs(world.w) > 0.000001 else { return SCNVector3(Float.nan, Float.nan, Float.nan) }
        return SCNVector3(world.x / world.w, world.y / world.w, world.z / world.w)
    }

    private func setupScene() {
        scene = SCNScene()
        backgroundColor = SpatialPalette.background
        allowsCameraControl = false
        rendersContinuously = false
        isPlaying = false
        antialiasingMode = .multisampling4X
        setAccessibilityRole(.group)
        setAccessibilityLabel(L10n.string("spatial.stage.accessibilityLabel"))
        guard let root = scene?.rootNode else { return }
        planarCamera.camera = SCNCamera()
        planarCamera.camera?.usesOrthographicProjection = true
        planarCamera.camera?.zNear = 0.01
        planarCamera.camera?.zFar = 100
        planarCamera.position = SCNVector3(0, 10, 0)
        planarCamera.look(at: SCNVector3Zero, up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        perspectiveCamera.camera = SCNCamera()
        perspectiveCamera.camera?.fieldOfView = 55
        perspectiveCamera.camera?.zNear = 0.01
        perspectiveCamera.camera?.zFar = 100
        root.addChildNode(planarCamera)
        root.addChildNode(perspectiveCamera)
        root.addChildNode(gridNode)

        let floor = SCNNode(geometry: SCNPlane(width: 6, height: 5.6))
        floor.geometry?.materials = [material(NSColor(white: 0.055, alpha: 1))]
        floor.eulerAngles.x = -.pi / 2
        floor.position.y = -0.025
        root.addChildNode(floor)
        let gridMaterial = material(NSColor(white: 0.22, alpha: 0.65))
        for x in stride(from: Float(-3), through: 3, by: 0.5) {
            let node = line(material: gridMaterial, radius: 0.005)
            connect(node, from: Self.scenePoint(x: x, z: -2.8), to: Self.scenePoint(x: x, z: 2.8))
            gridNode.addChildNode(node)
        }
        for z in stride(from: Float(-2.5), through: 2.5, by: 0.5) {
            let node = line(material: gridMaterial, radius: 0.005)
            connect(node, from: Self.scenePoint(x: -3, z: z), to: Self.scenePoint(x: 3, z: z))
            gridNode.addChildNode(node)
        }
        for z: Float in [-2.8, 2.8] {
            let edge = line(material: gridMaterial, radius: 0.014)
            connect(edge, from: Self.scenePoint(x: -3, z: z), to: Self.scenePoint(x: 3, z: z))
            root.addChildNode(edge)
        }
        for x: Float in [-3, 3] {
            let edge = line(material: gridMaterial, radius: 0.014)
            connect(edge, from: Self.scenePoint(x: x, z: -2.8), to: Self.scenePoint(x: x, z: 2.8))
            root.addChildNode(edge)
        }
        let axisX = line(material: material(NSColor(white: 0.30, alpha: 1)), radius: 0.01)
        let axisZ = line(material: material(NSColor(white: 0.38, alpha: 1)), radius: 0.01)
        connect(axisX, from: Self.scenePoint(x: -3, z: 0), to: Self.scenePoint(x: 3, z: 0))
        connect(axisZ, from: Self.scenePoint(x: 0, z: -2.8), to: Self.scenePoint(x: 0, z: 2.8))
        root.addChildNode(axisX); root.addChildNode(axisZ)

        for (node, name, color) in [(leftSpeakerNode, "leftSpeaker", SpatialPalette.left),
                                    (rightSpeakerNode, "rightSpeaker", SpatialPalette.right)] {
            node.geometry = SCNBox(width: 0.28, height: 0.3, length: 0.4, chamferRadius: 0.035)
            node.geometry?.materials = [material(color)]
            node.name = name; node.categoryBitMask = 2
            root.addChildNode(node)
        }
        listenerNode.geometry = SCNSphere(radius: 0.18)
        listenerNode.geometry?.materials = [material(SpatialPalette.listener)]
        listenerNode.name = "listener"; listenerNode.categoryBitMask = 2
        root.addChildNode(listenerNode)
        listenerRingNode.geometry = SCNTorus(ringRadius: 0.27, pipeRadius: 0.018)
        listenerRingNode.geometry?.materials = [material(SpatialPalette.listener)]
        root.addChildNode(listenerRingNode)
        for (ear, color) in [(leftEarNode, SpatialPalette.left), (rightEarNode, SpatialPalette.right)] {
            ear.geometry = SCNSphere(radius: 0.045)
            // Ear markers represent the DSP endpoints on the floor plane. Draw
            // them above the larger listener glyph without moving those points.
            let earMaterial = material(color)
            earMaterial.readsFromDepthBuffer = false
            earMaterial.writesToDepthBuffer = false
            ear.geometry?.materials = [earMaterial]
            ear.renderingOrder = 10
            root.addChildNode(ear)
        }
        widthNode.geometry = SCNCylinder(radius: 0.012, height: 1)
        widthNode.geometry?.materials = [material(NSColor(white: 0.30, alpha: 1))]
        root.addChildNode(widthNode)
        for path in 0..<4 {
            for node in pathNodes[path] {
                node.geometry = SCNCylinder(radius: path == 0 || path == 3 ? 0.012 : 0.008, height: 1)
                node.geometry?.materials = [material(path < 2 ? SpatialPalette.left : SpatialPalette.right)]
                root.addChildNode(node)
            }
        }
        for (button, action) in [(listenerButton, #selector(selectListener)),
                                 (leftButton, #selector(selectLeft)),
                                 (rightButton, #selector(selectRight))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
            button.onFocus = { [weak self] in self?.onFocus?() }
            button.setButtonType(.toggle)
            button.isBordered = false
            button.focusRingType = .none
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            addSubview(button)
        }
        listenerButton.accentColor = SpatialPalette.listener
        leftButton.accentColor = SpatialPalette.left
        rightButton.accentColor = SpatialPalette.right
        // Stable identifiers and accessible names survive language changes.
        listenerButton.identifier = NSUserInterfaceItemIdentifier("spatial.control.listener")
        leftButton.identifier = NSUserInterfaceItemIdentifier("spatial.control.leftSpeaker")
        rightButton.identifier = NSUserInterfaceItemIdentifier("spatial.control.rightSpeaker")
        listenerButton.setAccessibilityLabel(L10n.string("spatial.stage.selectListener"))
        leftButton.setAccessibilityLabel(L10n.string("spatial.stage.selectLeft"))
        rightButton.setAccessibilityLabel(L10n.string("spatial.stage.selectRight"))
        for label in [frontLabel, widthLabel, stateLabel] {
            label.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            label.textColor = NSColor(white: 0.76, alpha: 1)
            label.isSelectable = false
            addSubview(label)
        }
        frontLabel.identifier = NSUserInterfaceItemIdentifier("spatial.stage.frontLabel")
        widthLabel.identifier = NSUserInterfaceItemIdentifier("spatial.stage.widthLabel")
        stateLabel.identifier = NSUserInterfaceItemIdentifier("spatial.stage.stateLabel")
        // Annotation frames avoid objects and names, but a displaced object's
        // leader can still pass behind them. Their padded opaque backing keeps
        // the direction and width text legible above every scene/leader line.
        for label in [frontLabel, widthLabel] {
            label.drawsBackground = true
            label.backgroundColor = backgroundColor
        }
        selectionLeader.identifier = NSUserInterfaceItemIdentifier("spatial.selection.leader")
        selectionLeader.setAccessibilityElement(false)
        addSubview(selectionLeader, positioned: .below, relativeTo: listenerButton)
        for (index, leader) in objectLabelLeaders.enumerated() {
            leader.identifier = NSUserInterfaceItemIdentifier("spatial.name.leader.\(index)")
            leader.setAccessibilityElement(false)
            addSubview(leader, positioned: .below, relativeTo: listenerButton)
        }
        selectionCoordinates.identifier = NSUserInterfaceItemIdentifier("spatial.selection.coordinates")
        selectionCoordinates.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        selectionCoordinates.textColor = .labelColor
        selectionCoordinates.drawsBackground = true
        selectionCoordinates.backgroundColor = SpatialPalette.background
        selectionCoordinates.toolTip = L10n.string("spatial.stage.coordinatesTooltip")
        addSubview(selectionCoordinates)
        renderState()
    }

    private func material(_ color: NSColor) -> SCNMaterial {
        let result = SCNMaterial()
        result.lightingModel = .constant
        result.diffuse.contents = color
        result.isDoubleSided = true
        return result
    }
    private func line(material: SCNMaterial, radius: CGFloat) -> SCNNode {
        let node = SCNNode(geometry: SCNCylinder(radius: radius, height: 1))
        node.geometry?.materials = [material]
        return node
    }
    private func connect(_ node: SCNNode, from a: SCNVector3, to b: SCNVector3) {
        let start = SIMD3<Float>(Float(a.x), Float(a.y), Float(a.z))
        let end = SIMD3<Float>(Float(b.x), Float(b.y), Float(b.z))
        let delta = end - start
        let length = simd_length(delta)
        node.simdPosition = (start + end) / 2
        node.simdScale = SIMD3(1, max(length, 0.00001), 1)
        node.simdOrientation = length > 0.00001
            ? simd_quatf(from: SIMD3<Float>(0, 1, 0), to: delta / length)
            : simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    }

    func renderState() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let state = model.sceneState
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        let halfHeight = max(3.35, 3.65 / Float(bounds.width / bounds.height))
        planarCamera.camera?.orthographicScale = CGFloat(halfHeight)
        let elevation = min(75 * Float.pi / 180, max(25 * Float.pi / 180, state.cameraElevation))
        let yaw = min(Float.pi / 3, max(-Float.pi / 3, state.cameraOrbit))
        let distance = min(12, max(4, state.cameraZoom))
        let center = SIMD3<Float>(state.cameraPan.x, 0, -state.cameraPan.y)
        perspectiveCamera.simdPosition = center + SIMD3(distance * cos(elevation) * sin(yaw),
                                                       distance * sin(elevation), distance * cos(elevation) * cos(yaw))
        perspectiveCamera.look(at: SCNVector3(center.x, center.y, center.z),
                                  up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        pointOfView = state.viewMode == .planar ? planarCamera : perspectiveCamera
        gridNode.isHidden = !state.showGrid
        if let geometry = model.preview?.raw {
            leftSpeakerNode.position = Self.scenePoint(x: geometry.leftSpeaker.x, z: geometry.leftSpeaker.z, height: 0.15)
            rightSpeakerNode.position = Self.scenePoint(x: geometry.rightSpeaker.x, z: geometry.rightSpeaker.z, height: 0.15)
            leftEarNode.position = Self.scenePoint(x: geometry.leftEar.x, z: geometry.leftEar.z, height: 0.04)
            rightEarNode.position = Self.scenePoint(x: geometry.rightEar.x, z: geometry.rightEar.z, height: 0.04)
            listenerNode.position = Self.scenePoint(x: model.settings.listenerX, z: model.settings.listenerZ, height: 0.16)
            let selectedNode: SCNNode
            switch state.selection {
            case .leftSpeaker: selectedNode = leftSpeakerNode
            case .rightSpeaker: selectedNode = rightSpeakerNode
            default: selectedNode = listenerNode
            }
            listenerRingNode.position = SCNVector3(selectedNode.position.x, 0.04, selectedNode.position.z)
            listenerRingNode.isHidden = state.selection == .none
            listenerRingNode.geometry?.firstMaterial?.diffuse.contents = SpatialPalette.color(for: state.selection)
            let left = Self.scenePoint(x: geometry.leftSpeaker.x, z: geometry.leftSpeaker.z, height: 0.04)
            let right = Self.scenePoint(x: geometry.rightSpeaker.x, z: geometry.rightSpeaker.z, height: 0.04)
            connect(widthNode, from: left, to: right)
            let starts = [left, left, right, right]
            let ends = [leftEarNode.position, rightEarNode.position, leftEarNode.position, rightEarNode.position]
            let gains = [geometry.ll.gain, geometry.lr.gain, geometry.rl.gain, geometry.rr.gain]
            let maxGain = max(0.001, gains.max() ?? 1)
            let active = model.settings.enabled && model.settings.amount > 0
            for path in 0..<4 {
                let a = SIMD3<Float>(Float(starts[path].x), Float(starts[path].y), Float(starts[path].z))
                let b = SIMD3<Float>(Float(ends[path].x), Float(ends[path].y), Float(ends[path].z))
                let segments = pathNodes[path].count
                for (index, node) in pathNodes[path].enumerated() {
                    let low = Float(index) / Float(segments)
                    let high = Float(index + 1) / Float(segments) - (segments > 1 ? 0.035 : 0)
                    let p = a + (b - a) * low
                    let q = a + (b - a) * high
                    connect(node, from: SCNVector3(p.x, p.y, p.z), to: SCNVector3(q.x, q.y, q.z))
                    node.opacity = CGFloat((active ? 0.28 + 0.7 * gains[path] / maxGain : 0.18))
                    node.isHidden = !state.showPaths
                }
            }
            for node in [listenerNode, leftSpeakerNode, rightSpeakerNode] { node.opacity = active ? 1 : 0.64 }
        }
        SCNTransaction.commit()
        updateOverlays()
        needsDisplay = true
    }

    private func overlayBounds(of node: SCNNode) -> NSRect {
        let box = node.boundingBox
        var result = NSRect.null
        for x in [box.min.x, box.max.x] {
            for y in [box.min.y, box.max.y] {
                for z in [box.min.z, box.max.z] {
                    let p = projectStagePoint(node.convertPosition(SCNVector3(x, y, z), to: nil))
                    guard p.x.isFinite, p.y.isFinite else { continue }
                    result = result.union(NSRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0.001, height: 0.001))
                }
            }
        }
        return result.insetBy(dx: -4, dy: -4)
    }

    private func updateOverlays() {
        // Name, front and width annotations share one placement policy. Fixed
        // offsets alone can put the listener's label over both speakers in a
        // narrow perspective view, or merge front/name labels at the +Z edge.
        var occupied = [listenerNode, leftSpeakerNode, rightSpeakerNode].map { overlayBounds(of: $0) }
        if !listenerRingNode.isHidden { occupied.append(overlayBounds(of: listenerRingNode)) }
        @discardableResult
        func place(_ view: NSView, world: SCNVector3, size: NSSize, offset: CGFloat) -> Bool {
            let p = projectStagePoint(world)
            guard p.x.isFinite, p.y.isFinite else { return false }
            let preferred = NSPoint(x: CGFloat(p.x) - size.width / 2, y: CGFloat(p.y) + offset)
            let xOffsets: [CGFloat] = [0, -size.width / 2 - 24, size.width / 2 + 24, -size.width - 32, size.width + 32]
            let yOffsets: [CGFloat] = [offset, 24, -size.height - 12, 56, -size.height - 40, 84, -size.height - 68]
            var best = NSRect(origin: preferred, size: size)
            var bestScore = CGFloat.greatestFiniteMagnitude
            for dy in yOffsets {
                for dx in xOffsets {
                    let rect = NSRect(x: min(max(preferred.x + dx, 6), max(6, bounds.width - size.width - 6)),
                                      y: min(max(CGFloat(p.y) + dy, 26), max(26, bounds.height - size.height - 6)),
                                      width: size.width, height: size.height)
                    let overlap = occupied.reduce(CGFloat.zero) { total, obstacle in
                        let intersection = rect.insetBy(dx: -3, dy: -3).intersection(obstacle)
                        return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
                    }
                    let distance = pow(rect.minX - preferred.x, 2) + pow(rect.minY - preferred.y, 2)
                    let score = overlap * 1_000_000 + distance
                    if score < bestScore { best = rect; bestScore = score }
                }
            }
            view.frame = best
            occupied.append(best)
            return hypot(best.minX - preferred.x, best.minY - preferred.y) > 8
        }
        frontLabel.stringValue = L10n.string("spatial.stage.front")
        frontLabel.alignment = .center
        place(frontLabel, world: Self.scenePoint(x: 0, z: 2.65), size: NSSize(width: 70, height: 16), offset: 2)
        widthLabel.stringValue = L10n.format("spatial.stage.widthLabel", model.settings.speakerWidth)
        widthLabel.alignment = .center
        place(widthLabel, world: Self.scenePoint(x: 0, z: 1.8), size: NSSize(width: 95, height: 16), offset: -30)
        let objects = [(leftButton, leftSpeakerNode, NSSize(width: 32, height: 28), CGFloat(20)),
                       (rightButton, rightSpeakerNode, NSSize(width: 32, height: 28), CGFloat(20)),
                       (listenerButton, listenerNode, NSSize(width: max(76, listenerButton.fittingSize.width), height: 28), CGFloat(28))]
        for (index, entry) in objects.enumerated() {
            let (button, node, size, offset) = entry
            let moved = place(button, world: node.position, size: size, offset: offset)
            let leader = objectLabelLeaders[index]
            leader.isHidden = !moved
            if moved {
                let p = projectStagePoint(node.position)
                let point = NSPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                leader.frame = bounds
                leader.connect(from: point, to: NSPoint(x: min(max(point.x, button.frame.minX), button.frame.maxX),
                                                       y: min(max(point.y, button.frame.minY), button.frame.maxY)))
            }
        }
        for (button, selected) in [(listenerButton, model.sceneState.selection == .listener),
                                    (leftButton, model.sceneState.selection == .leftSpeaker),
                                    (rightButton, model.sceneState.selection == .rightSpeaker)] {
            button.state = selected ? .on : .off
            button.setAccessibilitySelected(selected)
            button.setAccessibilityValue(selected ? L10n.string("spatial.state.selected")
                                                  : L10n.string("spatial.state.unselected"))
        }
        listenerButton.toolTip = L10n.format("spatial.stage.listenerTooltip",
                                             model.settings.listenerX, model.settings.listenerZ)
        listenerButton.setAccessibilityValue(L10n.format("spatial.stage.listenerValue",
            model.settings.listenerX, model.settings.listenerZ,
            model.sceneState.selection == .listener ? L10n.string("spatial.state.selected")
                                                    : L10n.string("spatial.state.unselected")))
        let widthValue = L10n.format("spatial.stage.widthValue", model.settings.speakerWidth)
        leftButton.setAccessibilityValue(L10n.format("spatial.stage.speakerValue", widthValue,
            model.sceneState.selection == .leftSpeaker ? L10n.string("spatial.state.selected")
                                                       : L10n.string("spatial.state.unselected")))
        rightButton.setAccessibilityValue(L10n.format("spatial.stage.speakerValue", widthValue,
            model.sceneState.selection == .rightSpeaker ? L10n.string("spatial.state.selected")
                                                        : L10n.string("spatial.state.unselected")))
        leftButton.toolTip = L10n.string("spatial.stage.leftTooltip")
        rightButton.toolTip = L10n.string("spatial.stage.rightTooltip")
        stateLabel.stringValue = L10n.format("spatial.stage.stateLabel",
                                             model.settings.enabled ? L10n.string("spatial.state.on")
                                                                    : L10n.string("spatial.state.off"))
        stateLabel.frame = NSRect(x: 10, y: 7, width: max(0, bounds.width - 20), height: 15)
        updateSelectionCoordinates()
    }

    private func updateSelectionCoordinates() {
        guard let geometry = model.preview?.raw, model.sceneState.selection != .none else {
            selectionCoordinates.isHidden = true; selectionLeader.isHidden = true
            return
        }
        selectionCoordinates.textColor = SpatialPalette.color(for: model.sceneState.selection)
        let name: String, x: Float, z: Float, node: SCNNode
        switch model.sceneState.selection {
        case .listener:
            name = L10n.string("spatial.selection.listener")
            x = model.settings.listenerX; z = model.settings.listenerZ; node = listenerNode
        case .leftSpeaker:
            name = L10n.string("spatial.selection.left")
            x = geometry.leftSpeaker.x; z = geometry.leftSpeaker.z; node = leftSpeakerNode
        case .rightSpeaker:
            name = L10n.string("spatial.selection.right")
            x = geometry.rightSpeaker.x; z = geometry.rightSpeaker.z; node = rightSpeakerNode
        case .none: return
        }
        selectionCoordinates.stringValue = L10n.format("spatial.stage.coordinates", name, x, z)
        selectionCoordinates.setAccessibilityLabel(L10n.format("spatial.stage.coordinatesLabel", name))
        selectionCoordinates.setAccessibilityValue(selectionCoordinates.stringValue)
        selectionCoordinates.sizeToFit()
        let labelWidth = min(selectionCoordinates.frame.width + 10, max(1, bounds.width - 12))
        let labelHeight: CGFloat = 22
        let projected = projectStagePoint(node.position)
        guard projected.x.isFinite, projected.y.isFinite else { return }
        let point = NSPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
        // A perspective view can place the listener directly below a speaker.
        // Keep the coordinate card away from every object's hit target and the
        // existing annotations, rather than covering the listener with a fixed
        // vertical offset from the selected speaker.
        var obstacles = [leftButton.frame, rightButton.frame, listenerButton.frame,
                         widthLabel.frame, frontLabel.frame]
        for object in [listenerNode, leftSpeakerNode, rightSpeakerNode] {
            let p = projectStagePoint(object.position)
            obstacles.append(NSRect(x: CGFloat(p.x) - 17, y: CGFloat(p.y) - 17, width: 34, height: 34))
        }
        let origins = [
            NSPoint(x: point.x - labelWidth / 2, y: point.y - 64),
            NSPoint(x: point.x - labelWidth - 30, y: point.y - labelHeight / 2),
            NSPoint(x: point.x + 30, y: point.y - labelHeight / 2),
            NSPoint(x: point.x - labelWidth / 2, y: point.y + 48),
            NSPoint(x: 6, y: 28),
            NSPoint(x: bounds.width - labelWidth - 6, y: 28)
        ]
        let candidates = origins.map { origin in
            NSRect(x: min(max(origin.x, 6), max(6, bounds.width - labelWidth - 6)),
                   y: min(max(origin.y, 28), max(28, bounds.height - labelHeight - 6)),
                   width: labelWidth, height: labelHeight)
        }
        func overlap(_ candidate: NSRect) -> CGFloat {
            obstacles.reduce(0) { total, obstacle in
                let intersection = candidate.insetBy(dx: -4, dy: -4).intersection(obstacle)
                return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
        }
        let rect = candidates.first(where: { overlap($0) == 0 })
            ?? candidates.min(by: { overlap($0) < overlap($1) })!
        selectionCoordinates.frame = rect
        selectionCoordinates.isHidden = false
        selectionLeader.frame = bounds
        selectionLeader.connect(from: point,
            to: NSPoint(x: min(max(point.x, rect.minX + 5), rect.maxX - 5),
                        y: min(max(point.y, rect.minY), rect.maxY)))
        selectionLeader.isHidden = false
    }

    @objc private func selectListener() { select(.listener) }
    @objc private func selectLeft() { select(.leftSpeaker) }
    @objc private func selectRight() { select(.rightSpeaker) }
    private func select(_ selection: SpatialSceneState.Selection) {
        model.sceneState.selection = selection
        window?.makeFirstResponder(self)
        renderState()
    }

    /// One coordinate conversion serves both cameras and offscreen regression tests.
    func domainPoint(at point: NSPoint) -> SIMD2<Float>? {
        let near = unprojectStagePoint(SCNVector3(Float(point.x), Float(point.y), 0))
        let far = unprojectStagePoint(SCNVector3(Float(point.x), Float(point.y), 1))
        let dy = Float(far.y - near.y)
        guard dy.isFinite, abs(dy) > 0.00001 else { return nil }
        let t = -Float(near.y) / dy
        guard t.isFinite, t >= 0, t <= 1 else { return nil }
        let x = Float(near.x) + Float(far.x - near.x) * t
        let z = Float(near.z) + Float(far.z - near.z) * t
        guard x.isFinite, z.isFinite else { return nil }
        return SIMD2(x, -z)
    }

    func selection(at point: NSPoint) -> SpatialSceneState.Selection? {
        // Screen-space proxies make every object at least 40pt wide, independent
        // of zoom. Scene geometry is a fallback for larger projected shapes.
        let candidates: [(SCNNode, SpatialSceneState.Selection)] = [
            (listenerNode, .listener), (leftSpeakerNode, .leftSpeaker), (rightSpeakerNode, .rightSpeaker)]
        var nearest: (SpatialSceneState.Selection, CGFloat)?
        for (node, selection) in candidates {
            let screen = projectStagePoint(node.position)
            let distance = hypot(CGFloat(screen.x) - point.x, CGFloat(screen.y) - point.y)
            if distance <= 20, nearest == nil || distance < nearest!.1 { nearest = (selection, distance) }
        }
        if let nearest { return nearest.0 }
        let hit = hitTest(point, options: [.categoryBitMask: 2,
                                          .searchMode: SCNHitTestSearchMode.closest.rawValue]).first?.node.name
        return hit.flatMap(SpatialSceneState.Selection.init(rawValue:))
    }

    override func mouseDown(with event: NSEvent) {
        SpatialFocusRevealPolicy.beginPointerInteraction()
        defer { SpatialFocusRevealPolicy.endPointerInteraction() }
        window?.makeFirstResponder(self)
        lastPointer = convert(event.locationInWindow, from: nil)
        if model.sceneState.viewMode == .perspective && event.modifierFlags.contains(.option) {
            dragKind = .orbit; return
        }
        guard let point = domainPoint(at: lastPointer) else { return }
        dragStartSettings = model.settings
        editedDuringDrag = false
        let hit = selection(at: lastPointer)
        switch hit {
        case .leftSpeaker: dragKind = .leftSpeaker; select(.leftSpeaker)
        case .rightSpeaker: dragKind = .rightSpeaker; select(.rightSpeaker)
        default: dragKind = .listener; select(.listener)
        }
        if hit == .listener {
            dragOffset = SIMD2(model.settings.listenerX, model.settings.listenerZ) - point
        } else if hit == .leftSpeaker {
            dragOffset = SIMD2(-model.settings.speakerWidth / 2 - point.x, 0)
        } else if hit == .rightSpeaker {
            dragOffset = SIMD2(model.settings.speakerWidth / 2 - point.x, 0)
        } else {
            dragOffset = .zero
            applyDrag(point)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let pointer = convert(event.locationInWindow, from: nil)
        let dx = Float(pointer.x - lastPointer.x)
        let dy = Float(pointer.y - lastPointer.y)
        switch dragKind {
        case .orbit:
            model.sceneState.cameraOrbit = min(.pi / 3, max(-.pi / 3, model.sceneState.cameraOrbit - dx * 0.007))
            model.sceneState.cameraElevation = min(75 * .pi / 180, max(25 * .pi / 180, model.sceneState.cameraElevation - dy * 0.006))
        case .pan:
            model.sceneState.cameraPan.x = min(1.5, max(-1.5, model.sceneState.cameraPan.x - dx * 0.01))
            model.sceneState.cameraPan.y = min(1.5, max(-1.5, model.sceneState.cameraPan.y - dy * 0.01))
        default:
            if let point = domainPoint(at: pointer) { applyDrag(point) }
        }
        lastPointer = pointer
        renderState()
    }
    private func applyDrag(_ point: SIMD2<Float>) {
        var settings = model.settings
        let target = point + dragOffset
        switch dragKind {
        case .listener: settings.listenerX = target.x; settings.listenerZ = target.y
        case .leftSpeaker: settings.speakerWidth = -2 * target.x
        case .rightSpeaker: settings.speakerWidth = 2 * target.x
        default: return
        }
        editedDuringDrag = model.applyEdit(settings) || editedDuringDrag
        renderState()
    }
    override func mouseUp(with event: NSEvent) {
        if dragKind == .listener || dragKind == .leftSpeaker || dragKind == .rightSpeaker {
            let pointer = convert(event.locationInWindow, from: nil)
            if let point = domainPoint(at: pointer) { applyDrag(point) }
        }
        if editedDuringDrag { model.commit() }
        editedDuringDrag = false
        dragKind = nil
    }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, model.sceneState.viewMode == .perspective else { super.otherMouseDown(with: event); return }
        lastPointer = convert(event.locationInWindow, from: nil)
        dragKind = .pan
    }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { dragKind = nil }
    override func scrollWheel(with event: NSEvent) {
        guard model.sceneState.viewMode == .perspective else { super.scrollWheel(with: event); return }
        model.sceneState.cameraZoom = min(12, max(4, model.sceneState.cameraZoom + Float(event.scrollingDeltaY) * 0.04))
        renderState()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if editedDuringDrag { model.applyEdit(dragStartSettings, final: true) }
            dragKind = nil; editedDuringDrag = false
            select(.none); return
        }
        if let character = event.charactersIgnoringModifiers {
            if character == "1" { select(.listener); return }
            if character == "2" { select(.leftSpeaker); return }
            if character == "3" { select(.rightSpeaker); return }
        }
        guard [123, 124, 125, 126].contains(event.keyCode) else { super.keyDown(with: event); return }
        if model.sceneState.selection == .none { model.sceneState.selection = .listener }
        if (model.sceneState.selection == .leftSpeaker || model.sceneState.selection == .rightSpeaker)
            && (event.keyCode == 125 || event.keyCode == 126) { return }
        let step: Float = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        let direction: Float = event.keyCode == 123 || event.keyCode == 125 ? -1 : 1
        model.mutate(final: true) { settings in
            switch model.sceneState.selection {
            case .leftSpeaker, .rightSpeaker:
                if event.keyCode == 123 || event.keyCode == 124 {
                    settings.speakerWidth += direction * step * (model.sceneState.selection == .leftSpeaker ? -2 : 2)
                }
            default:
                if event.keyCode == 123 || event.keyCode == 124 { settings.listenerX += direction * step }
                else { settings.listenerZ += direction * step }
            }
        }
        renderState()
    }
}
