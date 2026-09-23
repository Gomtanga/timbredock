import AppKit

/// Presentation-only tokens. No dependency on the audio graph or preferences.
enum GlassDesign {
    // Keep the large surfaces near black; reserve white for type and selection.
    // Light appearance uses the same hierarchy with reversed contrast.
    static var ink: NSColor { neutral(dark: 0.98, light: 0.045) }
    static var secondary: NSColor { neutral(dark: 0.67, light: 0.38) }
    static var canvas: NSColor { neutral(dark: 0.025, light: 0.96) }
    static var surface: NSColor { neutral(dark: 0.047, light: 1) }
    static var well: NSColor { neutral(dark: 0.085, light: 0.96) }
    static var control: NSColor { neutral(dark: 0.12, light: 0.91) }
    static var selected: NSColor { ink }
    static var selectedInk: NSColor { neutral(dark: 0.035, light: 1) }
    static var glassTint: NSColor { neutral(dark: 0.015, light: 1, alpha: 0.78) }
    private static func neutral(dark: CGFloat, light: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light, alpha: alpha)
        }
    }
    @MainActor static func button(_ button: NSButton) {
        if #available(macOS 26.0, *) { button.bezelStyle = .glass }
        else { button.bezelStyle = .rounded }
        button.contentTintColor = .labelColor
    }
}

/// Native Liquid Glass for navigation and common controls. The content belongs
/// to NSGlassEffectView.contentView, as required by AppKit's compositing contract.
final class GlassPanel: NSView {
    let content = NSView()
    private var material: NSView?
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    private let radius: CGFloat
    init(frame: NSRect, radius: CGFloat = 24) {
        self.radius = radius
        super.init(frame: frame)
        installMaterial()
        workspaceNotifications.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { workspaceNotifications.removeObserver(self) }
    @objc private func accessibilityChanged() { installMaterial() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshMaterialAppearance()
    }
    private func refreshMaterialAppearance() {
        if #available(macOS 26.0, *), let glass = material as? NSGlassEffectView {
            // The canvas is opaque, so clear glass can keep navigation black
            // without losing text contrast. Resolve the tint after attachment.
            glass.style = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .clear : .regular
            effectiveAppearance.performAsCurrentDrawingAppearance {
                glass.tintColor = GlassDesign.glassTint.usingColorSpace(.deviceRGB)
            }
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        material?.frame = bounds
        content.frame = bounds
    }
    private func installMaterial() {
        content.removeFromSuperview()
        material?.removeFromSuperview()
        let effect: NSView
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let opaque = MonochromeSurface(frame: bounds, radius: radius)
            opaque.addSubview(content)
            effect = opaque
        } else if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = radius
            glass.contentView = content
            effect = glass
        } else {
            let visual = NSVisualEffectView(frame: bounds)
            visual.material = .sidebar
            visual.blendingMode = .behindWindow
            visual.state = .followsWindowActiveState
            visual.wantsLayer = true
            visual.layer?.cornerRadius = radius
            visual.layer?.masksToBounds = true
            visual.addSubview(content)
            effect = visual
        }
        effect.autoresizingMask = [.width, .height]
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(effect)
        material = effect
        refreshMaterialAppearance()
    }
}

/// Quiet opaque surfaces behind detailed controls and charts; glass is reserved
/// for navigation. Dynamic colors are resolved again when appearance changes.
final class MonochromeSurface: NSView {
    private var viewTag = 0
    override var tag: Int { get { viewTag } set { viewTag = newValue } }
    private let radius: CGFloat
    private let isCanvas: Bool
    private let isWell: Bool
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter
    init(frame: NSRect, radius: CGFloat = 20, canvas: Bool = false, well: Bool = false) {
        self.radius = radius; self.isCanvas = canvas; self.isWell = well
        super.init(frame: frame)
        wantsLayer = true
        refreshColors()
        workspaceNotifications.addObserver(self, selector: #selector(accessibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    deinit { workspaceNotifications.removeObserver(self) }
    @objc private func accessibilityChanged() { refreshColors() }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isCanvas ? GlassDesign.canvas : isWell ? GlassDesign.well : GlassDesign.surface).cgColor
            layer?.cornerRadius = radius
            layer?.borderWidth = !isCanvas && NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1.5 : 0
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Draw only the presentation; NSButton retains target/action, keyboard and AX.
/// The entire row gets a neutral focus outline, never an accent-colored symbol.
class StudioButton: NSButton {
    var prominent = false { didSet { needsDisplay = true } }
    var navigation = false { didSet { needsDisplay = true } }
    var accentColor: NSColor? { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverArea: NSTrackingArea?
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var title: String { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; if result { scrollToVisible(bounds.insetBy(dx: -4, dy: -4)) }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let emphasis = prominent && isEnabled
        let filled = emphasis || (selected && !navigation)
        let foreground: NSColor = filled
            ? (accentColor == nil ? GlassDesign.selectedInk : NSColor(white: 0.035, alpha: 1))
            : (accentColor ?? (selected || !navigation ? GlassDesign.ink : GlassDesign.secondary))
        let background: NSColor = filled ? (accentColor ?? GlassDesign.selected)
            : selected && navigation ? GlassDesign.ink.withAlphaComponent(0.08)
            : accentColor?.withAlphaComponent(0.14) ?? GlassDesign.well
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let shape = NSBezierPath(roundedRect: rect, xRadius: navigation ? 11 : 9, yRadius: navigation ? 11 : 9)
        if !navigation || selected || hovered || isHighlighted {
            background.withAlphaComponent(background.alphaComponent * (isEnabled ? 1 : 0.45)).setFill(); shape.fill()
            if (hovered || isHighlighted) && isEnabled {
                NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : 0.04).setFill(); shape.fill()
            }
        }
        if selected && !navigation && NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            foreground.setStroke(); shape.lineWidth = 1; shape.stroke()
        }
        let color = foreground.withAlphaComponent(foreground.alphaComponent * (isEnabled ? 1 : 0.35))
        let textFont = font ?? .systemFont(ofSize: 13, weight: .medium)
        let style = NSMutableParagraphStyle(); style.alignment = navigation ? .left : .center; style.lineBreakMode = .byTruncatingTail
        let showImage = image != nil
        let imageOnly = imagePosition == .imageOnly
        if let image, showImage {
            let x: CGFloat = navigation ? 16 : imageOnly ? (bounds.width - 18) / 2 : 12
            StudioDrawing.symbol(image, in: NSRect(x: x, y: (bounds.height - 18) / 2, width: 18, height: 18), color: color)
        }
        if !imageOnly {
            let x: CGFloat = navigation ? 46 : showImage ? 36 : 10
            let textRect = NSRect(x: x, y: (bounds.height - textFont.boundingRectForFont.height) / 2,
                                  width: max(1, bounds.width - x - 10), height: textFont.boundingRectForFont.height)
            (title as NSString).draw(in: textRect, withAttributes: [.font: textFont, .foregroundColor: color, .paragraphStyle: style])
        }
        StudioDrawing.focus(self, in: rect, radius: navigation ? 11 : 9)
    }
}

final class NavigationPill: StudioButton {}

enum StudioDrawing {
    @MainActor static func symbol(_ image: NSImage, in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        (image.withSymbolConfiguration(configuration) ?? image).draw(in: rect)
    }
    @MainActor static func focus(_ view: NSView, in rect: NSRect, radius: CGFloat) {
        guard view.window?.firstResponder === view, view.window?.isKeyWindow == true else { return }
        NSColor.labelColor.withAlphaComponent(0.7).setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        outline.lineWidth = 1.5; outline.stroke()
    }
}

/// Keeps the native menu, keyboard selection and accessibility of NSPopUpButton.
final class StudioPopUpButton: NSPopUpButton {
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        GlassDesign.control.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
        let color = GlassDesign.ink.withAlphaComponent(isEnabled ? 1 : 0.35)
        let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
        let textFont = font ?? .systemFont(ofSize: 13, weight: .medium)
        (titleOfSelectedItem ?? "").draw(in: NSRect(x: 14, y: (bounds.height - 18) / 2, width: max(1, bounds.width - 48), height: 18),
            withAttributes: [.font: textFont, .foregroundColor: color, .paragraphStyle: style])
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            StudioDrawing.symbol(chevron, in: NSRect(x: bounds.width - 28, y: (bounds.height - 12) / 2, width: 12, height: 12), color: color)
        }
        StudioDrawing.focus(self, in: rect, radius: 9)
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; if result { scrollToVisible(bounds.insetBy(dx: -4, dy: -4)) }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
}

/// A quiet segmented control using native selection and AX segment semantics.
final class StudioSegmentedControl: NSSegmentedControl {
    var compactLabels = false
    var onFocus: (() -> Void)?
    override var selectedSegment: Int { didSet { needsDisplay = true } }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard segmentCount > 0 else { return }
        let segmentWidth = newSize.width / CGFloat(segmentCount)
        for index in 0..<segmentCount where abs(width(forSegment: index) - segmentWidth) > 0.25 {
            setWidth(segmentWidth, forSegment: index)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        GlassDesign.well.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
        guard segmentCount > 0 else { return }
        let width = bounds.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let selected = selectedSegment == index
            let rect = NSRect(x: CGFloat(index) * width + 4, y: 4, width: width - 8, height: bounds.height - 8)
            if selected {
                GlassDesign.selected.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
                if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                    NSColor.labelColor.setStroke()
                    NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).stroke()
                }
            }
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingTail
            let color: NSColor = selected ? GlassDesign.selectedInk : GlassDesign.secondary
            let textFont = font ?? .systemFont(ofSize: 13, weight: .semibold)
            (label(forSegment: index) ?? "").draw(in: NSRect(x: rect.minX + (compactLabels ? 4 : 8), y: (bounds.height - 18) / 2, width: rect.width - (compactLabels ? 8 : 16), height: 18),
                withAttributes: [.font: textFont, .foregroundColor: color.withAlphaComponent(color.alphaComponent * (isEnabled ? 1 : 0.4)), .paragraphStyle: style])
        }
        StudioDrawing.focus(self, in: bounds.insetBy(dx: 1, dy: 1), radius: 12)
    }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); needsDisplay = true; if result { scrollToVisible(bounds.insetBy(dx: -4, dy: -4)); onFocus?() }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); needsDisplay = true; return result }
}

/// A discoverable, keyboard-accessible help control: hover for a tooltip or
/// click for a persistent, wrapping popover. Only explanatory text belongs here.
final class GlassHelpButton: NSButton {
    var message: String { didSet {
        guard oldValue != message else { return }
        toolTip = message; setAccessibilityHelp(message)
        helpPopover?.close()
    } }
    var onFocus: (() -> Void)?
    private var helpPopover: NSPopover?
    init(_ message: String, context: String? = nil) {
        self.message = message
        super.init(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        target = self; action = #selector(toggleHelp)
        toolTip = message
        setAccessibilityLabel([context, L10n.string("main.help.label")].compactMap { $0 }.joined(separator: " · "))
        setAccessibilityHelp(message)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { scrollToVisible(bounds.insetBy(dx: -8, dy: -8)); onFocus?() }
        return accepted
    }
    @objc private func toggleHelp() {
        if helpPopover?.isShown == true { helpPopover?.close(); return }
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.isSelectable = true
        let width: CGFloat = 320
        let height = max(40, label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height ?? 80)
        label.frame = NSRect(x: 16, y: 16, width: width, height: height)
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width + 32, height: height + 32))
        controller.view.addSubview(label)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        helpPopover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }
}
