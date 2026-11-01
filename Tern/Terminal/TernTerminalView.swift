import UIKit
import SwiftTerm
import TernCore

/// SwiftTerm's view with the delete key behaviour people expect from an iOS keyboard.
///
/// Two things are fixed here. iOS only auto-repeats the delete key while the text input reports
/// that it has text, and SwiftTerm answers from its shadow of what the software keyboard typed on
/// the current line. That shadow is empty after a tab completion, a history recall or a paste, so
/// holding delete used to stop after one character. The far side always has something to delete
/// as far as the keyboard is concerned. And a long press speeds up: characters first, then whole
/// words at the prompt, the way every other text field on the system behaves.
final class TernTerminalView: TerminalView {
    /// Deletes the word before the cursor and returns true, or returns false when there is no line
    /// editor to do it (a command is running), in which case a plain backspace is sent instead.
    var deleteWordBackward: (() -> Bool)?

    private var accelerator = DeleteKeyAccelerator()

    override var hasText: Bool { true }

    override func deleteBackward() {
        let action = accelerator.press(at: ProcessInfo.processInfo.systemUptime)
        // While marked text (a composition) or a keyboard chosen range is pending, SwiftTerm has to
        // handle the key itself so its input state stays in step with the keyboard.
        let keyboardOwnsRange = markedTextRange != nil || !(selectedTextRange?.isEmpty ?? true)
        switch action {
        case .character:
            super.deleteBackward()
        case .word:
            if keyboardOwnsRange || deleteWordBackward?() != true {
                super.deleteBackward()
            }
        case .pause:
            if keyboardOwnsRange {
                super.deleteBackward()
            }
        }
    }

    override func resignFirstResponder() -> Bool {
        accelerator.reset()
        return super.resignFirstResponder()
    }
}
