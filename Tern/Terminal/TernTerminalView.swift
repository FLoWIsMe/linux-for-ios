import UIKit
import SwiftTerm
import TernCore

/// SwiftTerm's view with the delete key behaviour people expect from an iOS keyboard.
///
/// The software keyboard decides on its own whether the delete key has anything to delete: it
/// looks at the `UITextInput` document behind the view, and SwiftTerm's document is only a shadow
/// of what the keyboard itself typed on the current line. After a tab completion, a history recall
/// or a paste that shadow is empty, so the key did nothing at all, and holding it never got going.
/// This view keeps the document in step with the line being edited at the prompt (without sending
/// anything to the shell), keeps it non empty while a command owns the screen so every press still
/// reaches the command, and times the keyboard's auto-repeat so a long press speeds up from
/// characters to words at the prompt, the way every other text field on the system behaves.
final class TernTerminalView: TerminalView {
    /// The line being edited at the prompt, or nil while a command or a read owns the input.
    var editorLine: (() -> String?)?
    /// Deletes the word before the cursor and returns true, or returns false when there is no line
    /// editor to do it (a command is running), in which case a plain backspace is sent instead.
    var deleteWordBackward: (() -> Bool)?

    private var accelerator = DeleteKeyAccelerator()
    private var isSyncingDocument = false
    private var syncScheduled = false

    /// Room kept in the document while a command runs: each press deletes one of these and sends
    /// the command a backspace. Topped up when it runs low.
    private static let placeholderLength = 64
    private static let placeholderMinimum = 16

    override var hasText: Bool { true }

    override func deleteBackward() {
        let action = accelerator.press(at: ProcessInfo.processInfo.systemUptime)
        // While marked text (a composition) or a keyboard chosen range is pending, SwiftTerm has to
        // handle the key itself so its document stays in step with the keyboard.
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
        scheduleDocumentSync()
    }

    override func resignFirstResponder() -> Bool {
        accelerator.reset()
        return super.resignFirstResponder()
    }

    // MARK: Text input document

    /// Brings the document up to date on the next turn of the main run loop. Never done inline:
    /// the call may come from inside one of SwiftTerm's own input callbacks, and the document must
    /// only change between them.
    func scheduleDocumentSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.syncScheduled = false
            self.syncInputDocument()
        }
    }

    /// Makes the document match the prompt line, or holds placeholder room while a command runs.
    private func syncInputDocument() {
        guard !isSyncingDocument, markedTextRange == nil,
              let whole = textRange(from: beginningOfDocument, to: endOfDocument) else { return }
        let current = text(in: whole) ?? ""
        let desired: String
        if let line = editorLine?() {
            desired = line
        } else {
            // Whatever was typed since the last top up stays at the end, where the keyboard deletes first.
            let typed = current.drop { $0 == " " }
            if current.count - typed.count >= Self.placeholderMinimum { return }
            desired = String(repeating: " ", count: Self.placeholderLength) + typed
        }
        guard desired != current else { return }
        // SwiftTerm mirrors every document edit to the terminal as backspaces and text. Nothing may
        // reach the shell for this edit, so the delegate steps aside for its duration; SwiftTerm
        // delivers input synchronously on the main thread, which is where this runs.
        isSyncingDocument = true
        let delegate = terminalDelegate
        terminalDelegate = nil
        replace(whole, withText: desired)
        terminalDelegate = delegate
        isSyncingDocument = false
    }
}
