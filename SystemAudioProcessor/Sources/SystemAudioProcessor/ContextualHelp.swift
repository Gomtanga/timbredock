import SwiftUI

struct ContextualHelp: NSViewRepresentable {
    let text: String
    var title: String? = nil
    var onFocus: (() -> Void)? = nil
    func makeNSView(context: Context) -> GlassHelpButton {
        let button = GlassHelpButton(text, context: title)
        button.onFocus = onFocus
        return button
    }
    func updateNSView(_ view: GlassHelpButton, context: Context) { view.message = text; view.onFocus = onFocus }
}
