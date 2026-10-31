import Foundation

/// A snapshot of the editor buffer used by `Ctrl-_`.
public struct EditorSnapshot: Equatable {
    public var buffer: [Character]
    public var cursor: Int

    public init(buffer: [Character], cursor: Int) {
        self.buffer = buffer
        self.cursor = cursor
    }
}

/// Undo history for one line. Runs of plain typing are coalesced into a single step so that
/// `Ctrl-_` removes a word or a phrase at a time, the way readline groups self-insert commands.
public struct UndoStack: Equatable {
    private var stack: [EditorSnapshot] = []
    private var coalescing = false
    public let capacity: Int

    public init(capacity: Int = 200) {
        self.capacity = capacity
    }

    public var isEmpty: Bool { stack.isEmpty }

    /// Records `state` before a modification. `typing` marks a self-insert of a single character;
    /// consecutive typing steps share one undo record.
    public mutating func record(_ state: EditorSnapshot, typing: Bool) {
        if typing && coalescing { return }
        coalescing = typing
        stack.append(state)
        if stack.count > capacity { stack.removeFirst(stack.count - capacity) }
    }

    /// Ends the current typing run so the next character starts a new undo record.
    public mutating func breakCoalescing() { coalescing = false }

    public mutating func pop() -> EditorSnapshot? {
        coalescing = false
        return stack.popLast()
    }

    public mutating func removeAll() {
        stack.removeAll()
        coalescing = false
    }
}
