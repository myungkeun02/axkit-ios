import UIKit

/// Korean (and Japanese, Chinese) typing keeps the last syllable "marked" until it is finished. A send tapped
/// at that moment would read the text without it, and the finished syllable would then land in an empty box
/// or go out again. So: finish the composition first, let the text field hand over the whole text, then send.
enum TextComposition {
    /// The text input being typed into right now, if any.
    @MainActor static var current: UITextInput? {
        Responder.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.axCaptureFirstResponder), to: nil, from: nil, for: nil)
        return Responder.found as? UITextInput
    }

    @MainActor static var isComposing: Bool { current?.markedTextRange != nil }

    /// Runs `send` with the finished text: right away when nothing is being composed, otherwise after the
    /// composition is committed and the binding has caught up.
    @MainActor static func finish(then send: @escaping @MainActor () -> Void) {
        guard let input = current, input.markedTextRange != nil else { send(); return }
        input.unmarkText()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { send() }
    }

    fileprivate enum Responder { @MainActor static weak var found: UIResponder? }
}

extension UIResponder {
    @objc fileprivate func axCaptureFirstResponder() { TextComposition.Responder.found = self }
}
