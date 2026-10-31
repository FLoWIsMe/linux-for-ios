import Foundation

/// A word as written in the source, quotes and expansions intact. Expansion happens at run time.
struct Word: Equatable {
    var raw: String
    var line: Int

    init(_ raw: String, line: Int = 0) {
        self.raw = raw
        self.line = line
    }
}

enum RedirectionKind: Equatable {
    /// `<`
    case input
    /// `>` (honours noclobber)
    case output
    /// `>|`
    case outputClobber
    /// `>>`
    case append
    /// `<>`
    case readWrite
    /// `<&n` or `<&-`
    case duplicateInput
    /// `>&n` or `>&-`
    case duplicateOutput
    /// `<<WORD` and `<<-WORD`; body is stored in `heredocBody`
    case heredoc
    /// `<<<word`
    case herestring
    /// `&>`
    case bothOutput
    /// `&>>`
    case bothAppend
}

struct Redirection: Equatable {
    /// Explicit descriptor (`2>`), nil means the default for the kind.
    var fd: Int32?
    var kind: RedirectionKind
    var target: Word
    /// Heredoc body, with leading tabs already stripped for `<<-`.
    var heredocBody: String = ""
    /// False when the heredoc delimiter was quoted (no expansion of the body).
    var heredocExpands: Bool = true
    var line: Int = 0

    var defaultFD: Int32 {
        switch kind {
        case .input, .duplicateInput, .heredoc, .herestring, .readWrite: return 0
        case .output, .outputClobber, .append, .duplicateOutput, .bothOutput, .bothAppend: return 1
        }
    }

    var effectiveFD: Int32 { fd ?? defaultFD }
}

struct Assignment: Equatable {
    var name: String
    var value: Word
    /// `name+=value`
    var append: Bool = false
}

struct SimpleCommand: Equatable {
    var assignments: [Assignment] = []
    var words: [Word] = []
    var redirections: [Redirection] = []
    var line: Int = 0
}

struct CaseItem: Equatable {
    var patterns: [Word]
    var body: CommandList
    /// `;;` stops, `;&` falls through to the next body, `;;&` keeps testing patterns.
    var terminator: CaseTerminator
}

enum CaseTerminator: Equatable {
    case stop
    case fallthrough
    case continueMatching
}

struct IfClause: Equatable {
    var condition: CommandList
    var body: CommandList
}

/// Expression inside `[[ ... ]]`.
indirect enum ConditionalExpression: Equatable {
    case unary(op: String, operand: Word)
    case binary(op: String, lhs: Word, rhs: Word)
    case string(Word)
    case not(ConditionalExpression)
    case and(ConditionalExpression, ConditionalExpression)
    case or(ConditionalExpression, ConditionalExpression)
}

indirect enum CompoundCommand: Equatable {
    case braceGroup(CommandList)
    case subshell(CommandList)
    case ifClause(clauses: [IfClause], elseBody: CommandList?)
    /// `words == nil` means `for name; do` which iterates over the positional parameters.
    case forLoop(variable: String, words: [Word]?, body: CommandList)
    case arithmeticFor(initializer: String, condition: String, step: String, body: CommandList)
    case whileLoop(condition: CommandList, body: CommandList)
    case untilLoop(condition: CommandList, body: CommandList)
    case caseClause(subject: Word, items: [CaseItem])
    case conditional(ConditionalExpression)
    case arithmetic(String)
}

struct FunctionDefinition: Equatable {
    var name: String
    var body: Command
    var line: Int
}

indirect enum Command: Equatable {
    case simple(SimpleCommand)
    case compound(CompoundCommand, redirections: [Redirection], line: Int)
    case function(FunctionDefinition)
}

struct PipelineStage: Equatable {
    var command: Command
    /// `|&`: the stage's stderr is also piped into the next stage.
    var pipesStderr: Bool = false
}

struct Pipeline: Equatable {
    var stages: [PipelineStage]
    var negated: Bool = false
    var timed: Bool = false
    var line: Int = 0
}

enum ListOperator: Equatable {
    case and
    case or
}

/// `pipeline (&& pipeline | || pipeline)*`
struct AndOrList: Equatable {
    var first: Pipeline
    var rest: [(ListOperator, Pipeline)]

    static func == (lhs: AndOrList, rhs: AndOrList) -> Bool {
        guard lhs.first == rhs.first, lhs.rest.count == rhs.rest.count else { return false }
        for (a, b) in zip(lhs.rest, rhs.rest) where a.0 != b.0 || a.1 != b.1 { return false }
        return true
    }
}

enum ListSeparator: Equatable {
    case sequential
    case background
}

struct ListItem: Equatable {
    var andOr: AndOrList
    var separator: ListSeparator
}

/// A sequence of and-or lists separated by `;`, `&` or newlines.
struct CommandList: Equatable {
    var items: [ListItem] = []
    var line: Int = 0

    var isEmpty: Bool { items.isEmpty }
}
