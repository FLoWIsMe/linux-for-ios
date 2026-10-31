import Foundation

/// Readline style kill ring: killed text accumulates when kills are consecutive, `Ctrl-Y` yanks the
/// most recent entry and `Alt-Y` rotates through older ones.
public struct KillRing: Equatable {
    public private(set) var entries: [String] = []
    private var yankIndex: Int = 0
    public let capacity: Int

    public init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Stores killed text. When `append` is set the text is merged with the newest entry (a run of
    /// consecutive kills behaves like one kill). `prepend` merges in front, for backward kills.
    public mutating func kill(_ text: String, append: Bool, prepend: Bool = false) {
        guard !text.isEmpty else { return }
        if append, let last = entries.last {
            entries[entries.count - 1] = prepend ? text + last : last + text
        } else {
            entries.append(text)
            if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        }
        yankIndex = entries.count - 1
    }

    /// The text `Ctrl-Y` inserts. Resets the rotation to the newest entry.
    public mutating func yank() -> String? {
        guard !entries.isEmpty else { return nil }
        yankIndex = entries.count - 1
        return entries[yankIndex]
    }

    /// The next older entry for `Alt-Y`, wrapping around.
    public mutating func rotate() -> String? {
        guard !entries.isEmpty else { return nil }
        yankIndex = (yankIndex - 1 + entries.count) % entries.count
        return entries[yankIndex]
    }
}
