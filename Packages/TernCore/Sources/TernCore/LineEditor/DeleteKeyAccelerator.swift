import Foundation

/// Decides what each press of the software keyboard's delete key should do while the key is held.
///
/// iOS repeats the key for as long as it is held. A short hold deletes characters; once the key has
/// been held for a while the deletion speeds up to a word at a time, the way every other text field
/// on the system behaves. The accelerator only sees timestamps, so the rule lives here where it can
/// be tested, and the terminal view just acts on the answer.
public struct DeleteKeyAccelerator: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Delete one character.
        case character
        /// Delete the word before the cursor.
        case word
        /// Do nothing: the hold is deleting words and the last one went a moment ago.
        case pause
    }

    /// Presses further apart than this start a new hold. The keyboard repeats about ten times a
    /// second, so anything slower is someone tapping.
    public var repeatGap: TimeInterval
    /// How long a hold must last before words go instead of characters.
    public var wordsAfterHold: TimeInterval
    /// How many presses a hold must have produced before words go. Together with `wordsAfterHold`
    /// this keeps a burst of quick taps from turning into word deletion.
    public var wordsAfterPresses: Int
    /// Minimum time between two word deletions, so words leave at a pace the eye can follow.
    public var wordInterval: TimeInterval

    private var holdStart: TimeInterval?
    private var lastPress: TimeInterval = 0
    private var lastWord: TimeInterval?
    private var presses = 0

    public init(repeatGap: TimeInterval = 0.3, wordsAfterHold: TimeInterval = 1.2, wordsAfterPresses: Int = 10, wordInterval: TimeInterval = 0.18) {
        self.repeatGap = repeatGap
        self.wordsAfterHold = wordsAfterHold
        self.wordsAfterPresses = wordsAfterPresses
        self.wordInterval = wordInterval
    }

    /// True while a hold is in progress, that is while presses keep arriving within `repeatGap`.
    public var isHolding: Bool { holdStart != nil }

    /// Records a press at `time` (seconds on any monotonic clock) and returns what it should do.
    public mutating func press(at time: TimeInterval) -> Action {
        if let start = holdStart, time - lastPress <= repeatGap, time >= lastPress {
            lastPress = time
            presses += 1
            guard time - start >= wordsAfterHold, presses > wordsAfterPresses else { return .character }
            if let last = lastWord, time - last < wordInterval {
                return .pause
            }
            lastWord = time
            return .word
        }
        holdStart = time
        lastPress = time
        lastWord = nil
        presses = 1
        return .character
    }

    /// Forgets the current hold, for example when the terminal loses the keyboard.
    public mutating func reset() {
        holdStart = nil
        lastWord = nil
        presses = 0
    }
}
