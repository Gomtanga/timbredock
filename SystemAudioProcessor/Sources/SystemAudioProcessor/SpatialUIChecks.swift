import AppKit
import SceneKit
import SwiftUI

/// Offscreen AppKit/SceneKit checks. No audio capture, output-device negotiation,
/// or user preference changes. Render snapshots are optional local QA artifacts.
@available(macOS 14.4, *)
@MainActor
func runSpatialUIChecks(snapshotDirectory: URL? = nil) throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw AppError.message("Spatial UI: \(message)") }
    }
    let suite = "lowend.spatial-ui-checks.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { throw AppError.message("Cannot create isolated UI test preferences.") }
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = SpatialControlModel(preferences: defaults)
    var delivered: [SpatialSettings] = []
    model.onChange = { delivered.append($0) }
    try require(model.sceneState.viewMode == .planar, "The first view must be planar.")
    model.sceneState.viewMode = .perspective
    model.sceneState.showGrid = false
    model.sceneState.showPaths = false
    let restored = SpatialControlModel(preferences: defaults)
    try require(restored.sceneState.viewMode == .perspective && !restored.sceneState.showGrid
                && !restored.sceneState.showPaths, "Visual preferences did not round-trip.")
    try require(delivered.isEmpty, "Changing a visual preference emitted an audio edit.")
    model.sceneState = SpatialSceneState()

    var invalid = model.settings
    invalid.listenerX = .nan
    try require(!model.applyEdit(invalid), "Non-finite input must be rejected.")
    try require(model.settings.listenerX == 0 && delivered.isEmpty, "Invalid input changed settings or audio state.")
    for index in 0..<1_000 {
        var settings = model.settings
        settings.listenerX = Float(index) / 200 - 3
        settings.listenerZ = 10
        model.applyEdit(settings)
    }
    try require(delivered.isEmpty, "UI edits synchronously emitted intermediate DSP packets.")
    try require(abs(model.settings.listenerX - 1.995) < 0.00001 && model.settings.listenerZ == 2.8,
                "Immediate local display/clamp did not retain the latest value.")
    model.commit()
    try require(delivered.count == 1 && delivered.last?.listenerX == model.settings.listenerX,
                "Final commit did not publish exactly the latest setting.")
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
    try require(delivered.count == 1, "A cancelled timer duplicated the final commit.")
    model.mutate { $0.listenerX = 0.3 }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04))
    try require(delivered.count == 2 && delivered.last?.listenerX == 0.3,
                "Common-mode coalescing timer did not flush the pending edit.")
    model.update(SpatialSettings())
    model.processingSampleRate = 96_000
    try require(model.preview?.raw.sampleRate == 96_000, "Preview did not use the actual processing rate.")
    model.processingSampleRate = .infinity
    try require(model.processingSampleRate == 96_000, "Invalid processing rate replaced the last valid rate.")

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = SpatialStageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = view
    view.bind(model: model, onChange: { delivered.append($0) })
    view.layoutSubtreeIfNeeded()
    let scene = view.scene
    try require(!view.rendersContinuously && !view.isPlaying, "Spatial view continuously renders at idle.")
    let origin = view.projectStagePoint(SpatialStageView.scenePoint(x: 0, z: 0))
    let positiveX = view.projectStagePoint(SpatialStageView.scenePoint(x: 1, z: 0))
    let positiveZ = view.projectStagePoint(SpatialStageView.scenePoint(x: 0, z: 1))
    try require(positiveX.x > origin.x && positiveZ.y > origin.y,
                "Planar axes are inverted: +X must be right and +Z must be up.")
    for x: Float in [-3, 0, 3] {
        for z: Float in [-2.8, 0, 2.8] {
            let screen = view.projectStagePoint(SpatialStageView.scenePoint(x: x, z: z))
            guard let roundTrip = view.domainPoint(at: NSPoint(x: CGFloat(screen.x), y: CGFloat(screen.y))) else {
                throw AppError.message("Spatial UI planar ray-plane round trip failed.")
            }
            try require(abs(roundTrip.x - x) < 0.001 && abs(roundTrip.y - z) < 0.001,
                        "Planar coordinates do not round trip.")
        }
    }
    let beforeCamera = delivered.count
    for yaw: Float in [-Float.pi / 3, 0, Float.pi / 3] {
        for elevation: Float in [25, 75] {
            model.sceneState.viewMode = .perspective
            model.sceneState.cameraOrbit = yaw
            model.sceneState.cameraElevation = elevation * .pi / 180
            model.sceneState.cameraPan = SIMD2(0.5, -0.5)
            view.renderState()
            let screen = view.projectStagePoint(SpatialStageView.scenePoint(x: 0.3, z: 0.4))
            guard let point = view.domainPoint(at: NSPoint(x: CGFloat(screen.x), y: CGFloat(screen.y))) else {
                throw AppError.message("Spatial UI perspective ray-plane round trip failed.")
            }
            try require(abs(point.x - 0.3) < 0.001 && abs(point.y - 0.4) < 0.001,
                        "Perspective camera rotation inverted or displaced object dragging.")
            try require(view.scene === scene, "Changing the camera replaced the scene.")
        }
    }
    try require(delivered.count == beforeCamera, "Camera orbit/pan/view change emitted DSP events.")
    model.sceneState = SpatialSceneState()
    view.renderState()

    func localPoint(x: Float, z: Float, height: Float = 0) -> NSPoint {
        let p = view.projectStagePoint(SpatialStageView.scenePoint(x: x, z: z, height: height))
        return NSPoint(x: CGFloat(p.x), y: CGFloat(p.y))
    }
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
            throw AppError.message("Cannot construct Spatial pointer fixture.")
        }
        return event
    }
    let floor = localPoint(x: 2.2, z: -1.4)
    view.mouseDown(with: try mouse(.leftMouseDown, floor))
    view.mouseUp(with: try mouse(.leftMouseUp, floor))
    try require(abs(model.settings.listenerX - 2.2) < 0.001 && abs(model.settings.listenerZ + 1.4) < 0.001,
                "Blank-floor click did not move the listener to the clicked position.")
    let left = localPoint(x: -model.settings.speakerWidth / 2, z: 1.8, height: 0.15)
    try require(view.selection(at: left) == .leftSpeaker, "Left speaker hit proxy selected the listener.")
    view.mouseDown(with: try mouse(.leftMouseDown, left))
    let crossedCenter = localPoint(x: 2, z: 1.8)
    view.mouseDragged(with: try mouse(.leftMouseDragged, crossedCenter))
    view.mouseUp(with: try mouse(.leftMouseUp, crossedCenter))
    try require(model.settings.speakerWidth == 0.6, "Crossing the center flipped a speaker instead of clamping width.")
    guard let leftNode = view.scene?.rootNode.childNode(withName: "leftSpeaker", recursively: false),
          let rightNode = view.scene?.rootNode.childNode(withName: "rightSpeaker", recursively: false) else {
        throw AppError.message("Spatial speaker nodes missing.")
    }
    try require(abs(Float(leftNode.position.x + rightNode.position.x)) < 1e-6
                && abs(Float(leftNode.position.z) + 1.8) < 1e-6,
                "Speaker drag lost symmetry or fixed forward position.")

    func key(_ code: UInt16, flags: NSEvent.ModifierFlags = [], character: String = "") throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                          timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, characters: character, charactersIgnoringModifiers: character,
                                          isARepeat: false, keyCode: code) else {
            throw AppError.message("Cannot construct Spatial keyboard fixture.")
        }
        return event
    }
    model.sceneState.selection = .listener
    let oldX = model.settings.listenerX
    view.keyDown(with: try key(124, flags: .shift))
    try require(abs(model.settings.listenerX - oldX - 0.1) < 1e-5, "Shift+arrow did not move 0.10 m.")
    let initial = model.settings
    let empty = localPoint(x: -2.2, z: -1.2)
    view.mouseDown(with: try mouse(.leftMouseDown, empty))
    view.keyDown(with: try key(53))
    try require(SpatialControlModel.equal(model.settings, initial), "Escape did not restore drag-start settings.")
    try require(delivered.last.map { SpatialControlModel.equal($0, initial) } == true,
                "Escape restored the display but not the final DSP setting.")
    try require(view.subviews.compactMap { $0 as? NSButton }.count == 3,
                "Stage selection must expose three native accessibility buttons.")
    try require(view.subviews.compactMap { $0 as? NSButton }.allSatisfy {
        $0.bounds.width >= 28 && $0.bounds.height >= 28
    }, "Stage accessibility targets are smaller than 28×28 pt.")

    guard let coordinates = view.subviews.first(where: { $0.identifier?.rawValue == "spatial.selection.coordinates" }) as? NSTextField,
          let leader = view.subviews.first(where: { $0.identifier?.rawValue == "spatial.selection.leader" }) as? SpatialSelectionLeaderView else {
        throw AppError.message("Spatial selection needs a visible coordinate annotation and leader.")
    }
    model.mutate(final: true) { $0.listenerX = 0.4; $0.listenerZ = -0.6; $0.speakerWidth = 1.8 }
    // Selection is asserted through stable identifiers and localized values, so
    // the check never depends on a Korean (or any) display title.
    let selectionByIdentifier: [String: SpatialSceneState.Selection] = [
        "spatial.control.listener": .listener,
        "spatial.control.leftSpeaker": .leftSpeaker,
        "spatial.control.rightSpeaker": .rightSpeaker
    ]
    let selectedState = L10n.string("spatial.state.selected")
    let unselectedState = L10n.string("spatial.state.unselected")
    for mode in SpatialSceneState.ViewMode.allCases {
        model.sceneState.viewMode = mode
        for selected in [SpatialSceneState.Selection.listener, .leftSpeaker, .rightSpeaker] {
            model.sceneState.selection = selected
            view.renderState()
            let selectedTitle = selected == .listener ? L10n.string("spatial.selection.listener")
                : selected == .leftSpeaker ? L10n.string("spatial.selection.left")
                : L10n.string("spatial.selection.right")
            let buttons = view.subviews.compactMap { $0 as? NSButton }
            try require(buttons.count == selectionByIdentifier.count,
                        "Stage selection must expose exactly the three native accessibility buttons.")
            for button in buttons {
                guard let identifier = button.identifier?.rawValue,
                      let buttonSelection = selectionByIdentifier[identifier] else {
                    throw AppError.message("Stage selection button lost its stable identifier.")
                }
                let expected = buttonSelection == selected
                try require(button.state == (expected ? .on : .off) && button.isAccessibilitySelected() == expected,
                            "Native and AX selected state disagree for \(identifier).")
                let value = button.accessibilityValue() as? String ?? ""
                let expectedValue: String
                switch buttonSelection {
                case .listener:
                    expectedValue = L10n.format("spatial.stage.listenerValue", Float(0.4), Float(-0.6),
                                                expected ? selectedState : unselectedState)
                case .leftSpeaker, .rightSpeaker:
                    let width = L10n.format("spatial.stage.widthValue", Float(1.8))
                    expectedValue = L10n.format("spatial.stage.speakerValue", width,
                                                expected ? selectedState : unselectedState)
                case .none:
                    expectedValue = ""
                }
                try require(value == expectedValue,
                            "AX value for \(identifier) lost its selection or width after a coordinate update.")
            }
            let expectedX: Float = selected == .listener ? 0.4 : selected == .leftSpeaker ? -0.9 : 0.9
            let expectedZ: Float = selected == .listener ? -0.6 : 1.8
            let expectedText = L10n.format("spatial.stage.coordinates", selectedTitle, expectedX, expectedZ)
            try require(!coordinates.isHidden && coordinates.stringValue == expectedText,
                        "Visible selection coordinates differ from DSP planar geometry.")
            try require(view.bounds.contains(coordinates.frame), "Selection coordinates are clipped.")
            let height: Float = selected == .listener ? 0.16 : 0.15
            let glyph = view.projectStagePoint(SpatialStageView.scenePoint(x: expectedX, z: expectedZ, height: height))
            try require(!leader.isHidden && abs(leader.startPoint.x - CGFloat(glyph.x)) < 0.01
                        && abs(leader.startPoint.y - CGFloat(glyph.y)) < 0.01,
                        "Selection annotation leader is detached from the selected glyph.")
            try require(leader.hitTest(leader.startPoint) == nil, "Annotation intercepted object dragging.")
        }
    }
    // Prime the real renderer, then change size/camera without rendering again.
    // AppKit overlays and input must use the new projection immediately.
    model.sceneState.selection = .listener
    _ = view.snapshot()
    for (width, height) in [(1200, 700), (515, 600), (800, 600)] {
        window.setContentSize(NSSize(width: width, height: height))
        view.layoutSubtreeIfNeeded()
        for mode in SpatialSceneState.ViewMode.allCases {
            model.sceneState.viewMode = mode
            view.renderState()
            let world = SpatialStageView.scenePoint(x: 0.4, z: -0.6, height: 0.16)
            let immediate = view.projectStagePoint(world)
            try require(abs(leader.startPoint.x - CGFloat(immediate.x)) < 0.01
                        && abs(leader.startPoint.y - CGFloat(immediate.y)) < 0.01,
                        "Resize/camera change left the annotation at the previous projection.")
            let floor = SpatialStageView.scenePoint(x: 0.4, z: -0.6)
            let screen = view.projectStagePoint(floor)
            guard let restored = view.domainPoint(at: NSPoint(x: CGFloat(screen.x), y: CGFloat(screen.y))) else {
                throw AppError.message("Immediate resized input projection did not reach the floor.")
            }
            try require(abs(restored.x - 0.4) < 0.001 && abs(restored.y + 0.6) < 0.001,
                        "Immediate resized input used the previous viewport.")
            _ = view.snapshot()
            let rendered = view.projectPoint(world)
            try require(abs(Float(rendered.x - immediate.x)) < 0.01
                        && abs(Float(rendered.y - immediate.y)) < 0.01,
                        "Explicit projection disagrees with the actual SceneKit rendered viewport.")
        }
    }
    try require(!view.rendersContinuously && !view.isPlaying,
                "Viewport correction enabled continuous rendering.")

    // Required minimum-page states previously merged front/L text or put the
    // listener name on top of speaker bodies. Check the rendered glyphs and
    // all non-card annotations, not just the coordinate-card placement policy.
    window.setContentSize(NSSize(width: 483, height: 328.5))
    view.layoutSubtreeIfNeeded()
    for (mode, x, z, width): (SpatialSceneState.ViewMode, Float, Float, Float) in [
        (.perspective, 0, 0, 0.6), (.planar, 0, 2.8, 0.6), (.planar, 0, 2.8, 3)
    ] {
        model.update(SpatialSettings(enabled: true, listenerX: x, listenerZ: z, speakerWidth: width, amount: 35))
        model.sceneState.viewMode = mode
        model.sceneState.selection = .listener
        view.renderState()
        _ = view.snapshot()
        // Identify role labels by their stable identifiers; the visible text is localized.
        let roleIdentifiers = ["spatial.stage.frontLabel", "spatial.stage.widthLabel"]
        let labels = view.subviews.filter {
            if $0 is NSButton { return true }
            guard let label = $0 as? NSTextField else { return false }
            return roleIdentifiers.contains(label.identifier?.rawValue ?? "")
        }
        try require(labels.count == selectionByIdentifier.count + roleIdentifiers.count,
                    "Minimum-page role labels lost their stable identifiers.")
        for (index, label) in labels.enumerated() {
            try require(view.bounds.contains(label.frame), "Minimum-page role label clipped.")
            if let annotation = label as? NSTextField {
                try require(annotation.drawsBackground && annotation.backgroundColor?.alphaComponent == 1,
                            "Front/width annotation must mask scene and leader lines with an opaque backing.")
                let annotationIndex = view.subviews.firstIndex(of: annotation)!
                for (leaderIndex, overlay) in view.subviews.enumerated()
                    where overlay.identifier?.rawValue.contains("leader") == true {
                    try require(leaderIndex < annotationIndex, "Leader drawn above front/width annotation.")
                }
            }
            for other in labels.dropFirst(index + 1) {
                try require(!label.frame.intersects(other.frame), "Minimum-page role/front/width labels overlap.")
            }
            for name in ["listener", "leftSpeaker", "rightSpeaker"] {
                guard let node = view.scene?.rootNode.childNode(withName: name, recursively: false) else {
                    throw AppError.message("Missing glyph in minimum-page overlay fixture.")
                }
                let box = node.boundingBox
                var renderedBounds = NSRect.null
                for px in [box.min.x, box.max.x] {
                    for py in [box.min.y, box.max.y] {
                        for pz in [box.min.z, box.max.z] {
                            let world = node.convertPosition(SCNVector3(px, py, pz), to: nil)
                            let p = view.projectPoint(world)
                            renderedBounds = renderedBounds.union(NSRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0.001, height: 0.001))
                        }
                    }
                }
                try require(!label.frame.intersects(renderedBounds), "Minimum-page role label hides \(name).")
            }
        }
    }
    window.setContentSize(NSSize(width: 800, height: 600))
    view.layoutSubtreeIfNeeded()
    model.sceneState.selection = .none
    view.renderState()
    try require(coordinates.isHidden && leader.isHidden, "Deselection left a stale coordinate annotation.")
    model.sceneState.viewMode = .planar

    var updateDurations: [Double] = []
    updateDurations.reserveCapacity(1_000)
    for index in 0..<1_000 {
        var settings = model.settings
        settings.listenerX = 2 * sin(Float(index) * 0.01)
        settings.listenerZ = 2 * cos(Float(index) * 0.01)
        let start = DispatchTime.now().uptimeNanoseconds
        model.applyEdit(settings)
        view.renderState()
        updateDurations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    model.commit()
    updateDurations.sort()
    print(String(format: "Spatial UI model+node elapsed update (1000 edits, offscreen 800x600): p50 %.3f ms, p95 %.3f ms, max %.3f ms; excludes event dispatch and GPU presentation.",
                 updateDurations[500], updateDurations[950], updateDurations[999]))
    try require(model.uiEditRevision == model.submittedEditRevision && !model.hasPendingEdit,
                "UI final submission left an unsubmitted local target revision.")

    if let snapshotDirectory {
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        var displaySettings = SpatialSettings()
        displaySettings.enabled = true
        displaySettings.listenerX = 0.4
        displaySettings.listenerZ = -0.6
        model.update(displaySettings)
        model.sceneState.selection = .listener
        for mode in SpatialSceneState.ViewMode.allCases {
            model.sceneState.viewMode = mode
            view.renderState()
            let image = view.snapshot()
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .png, properties: [:]) else {
                throw AppError.message("Cannot encode the offscreen SceneKit rendering.")
            }
            try data.write(to: snapshotDirectory.appendingPathComponent("stage-\(mode.rawValue).png"))
        }
        model.sceneState.viewMode = .planar
        model.sceneState.showDetails = true
        for (width, height) in [(515, 600), (616, 660), (1000, 860)] {
            let host = NSHostingView(rootView: SpatialPageView(spatialModel: model, onSpatialChange: { _ in }))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window.setContentSize(host.frame.size)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

            func descendants<T: NSView>(_ node: NSView, type: T.Type) -> [T] {
                var result = (node as? T).map { [$0] } ?? []
                for child in node.subviews { result += descendants(child, type: type) }
                return result
            }
            func capture(_ suffix: String) throws {
                // AppKit bitmap caching omits Metal-backed content. Use the
                // same SCNView's actual offscreen snapshot as a temporary
                // underlay, preserving the real native controls and layout.
                let posters = descendants(host, type: SpatialStageView.self).map { stage in
                    let poster = NSImageView(image: stage.snapshot())
                    poster.frame = stage.bounds
                    poster.imageScaling = .scaleAxesIndependently
                    stage.addSubview(poster, positioned: .below, relativeTo: stage.subviews.first)
                    return poster
                }
                defer { posters.forEach { $0.removeFromSuperview() } }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw AppError.message("Cannot allocate Spatial layout screenshot.")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw AppError.message("Cannot encode Spatial layout screenshot.")
                }
                try png.write(to: snapshotDirectory.appendingPathComponent("spatial-\(width)x\(height)\(suffix).png"))
            }
            try capture("")
            if let scroll = descendants(host, type: NSScrollView.self).first,
               let document = scroll.documentView,
               document.bounds.height > scroll.contentView.bounds.height {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                host.layoutSubtreeIfNeeded()
                try capture("-scrolled")
            }
        }
    }
    print("Spatial UI checks passed: finite/clamp, visual preferences, latest-only coalescing/final commit, planar/perspective coordinates, same scene, hit selection, width symmetry, cancel, keyboard, accessibility proxies, idle rendering policy.")
}
