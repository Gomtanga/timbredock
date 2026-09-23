import AppKit
import SwiftUI

/// Uses the same AppKit control as Sound, including native keyboard/AX selection.
struct StudioChoice<Value: Hashable>: NSViewRepresentable {
    var items: [(Value, String)]
    @Binding var selection: Value
    var label: String
    var compact = false
    var onFocus: (() -> Void)? = nil

    @MainActor final class Coordinator: NSObject {
        var parent: StudioChoice
        init(_ parent: StudioChoice) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            guard parent.items.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.items[sender.selectedSegment].0
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> StudioChoiceContainer {
        let control = StudioSegmentedControl(labels: items.map(\.1), trackingMode: .selectOne,
            target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.focusRingType = .none
        control.font = .systemFont(ofSize: compact ? 12 : 13, weight: .medium)
        return StudioChoiceContainer(control: control)
    }
    func updateNSView(_ container: StudioChoiceContainer, context: Context) {
        let control = container.control
        context.coordinator.parent = self
        let index = items.firstIndex(where: { $0.0 == selection }) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
        control.setAccessibilityLabel(label)
        control.compactLabels = compact
        control.onFocus = onFocus
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StudioChoiceContainer, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 36)
    }
}

/// Isolates the segmented cell's intrinsic width from SwiftUI's proposed width.
/// Native segment metrics must not feed back into the hosting layout engine.
final class StudioChoiceContainer: NSView {
    let control: StudioSegmentedControl
    init(control: StudioSegmentedControl) {
        self.control = control
        super.init(frame: .zero)
        addSubview(control)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        control.frame = bounds
    }
}
