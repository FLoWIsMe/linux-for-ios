import Foundation
import TernCore

/// A small Claude coding agent that runs inside a Tern tab. It holds a conversation, streams the
/// model's replies to the terminal, and lets the model run shell commands and read and write files
/// in the user's home directory through tools, asking for confirmation before anything that changes
/// the device.
///
/// Commands run in an isolated sub-shell seeded with the tab's current directory and environment, so
/// the agent never reenters the interactive interpreter it was launched from.
final class ClaudeAgent {
    private let io: ShellIO
    private let session: ShellSession
    private let client: AnthropicClient
    private let model: String
    private var autoApprove: Bool
    private var messages: [[String: Any]] = []

    private let bold = "\u{1b}[1m"
    private let dim = "\u{1b}[2m"
    private let accent = "\u{1b}[36m"
    private let green = "\u{1b}[32m"
    private let red = "\u{1b}[31m"
    private let reset = "\u{1b}[0m"

    /// The isolated shell the agent's commands run in. Created on first use so a conversation that
    /// never runs a command is cheap.
    private lazy var sandbox: Shell = {
        let executor = IOSSystemExecutor(sessionName: "tern-claude-" + UUID().uuidString)
        return Shell(executor: executor, host: nil,
                     environment: SystemEnvironment.shellEnvironment(),
                     workingDirectory: session.shell.workingDirectory,
                     homeDirectory: SystemEnvironment.homeDirectory)
    }()

    init(io: ShellIO, session: ShellSession, model: String, baseURL: String, apiKey: String, autoApprove: Bool) {
        self.io = io
        self.session = session
        self.model = model
        self.autoApprove = autoApprove
        self.client = AnthropicClient(apiKey: apiKey, baseURL: baseURL)
    }

    // MARK: Entry points

    /// One prompt, then return.
    func runOnce(_ prompt: String) -> Int32 {
        appendUser(text: prompt)
        return converse()
    }

    /// Interactive chat until Ctrl-D or `exit`.
    func runREPL() -> Int32 {
        io.writeOut("\(accent)Claude\(reset) in Tern. Type your request, or \(bold)exit\(reset) to leave. Model: \(dim)\(model)\(reset)\n")
        while true {
            guard let line = session.readLine(prompt: "\(accent)you ›\(reset) ", secure: false) else {
                io.writeOut("\n")
                return 0
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if ["exit", "quit", ":q"].contains(trimmed.lowercased()) { return 0 }
            appendUser(text: line)
            let status = converse()
            if status != 0 { return status }
            if session.shell.isInterrupted { return 130 }
        }
    }

    // MARK: Conversation loop

    /// Runs model turns until it stops asking for tools. Returns 0 normally, non-zero on error.
    private func converse() -> Int32 {
        var guardCount = 0
        while true {
            guardCount += 1
            if guardCount > 50 {
                io.writeErr("\n\(red)claude: stopped after 50 tool steps.\(reset)\n")
                return 1
            }
            if session.shell.isInterrupted { return 130 }

            var streamedAny = false
            var endedWithNewline = true
            let reply = client.send(body: requestBody(), onText: { [weak self] text in
                guard let self else { return }
                self.io.writeOut(text)
                streamedAny = true
                if let last = text.last { endedWithNewline = (last == "\n") }
            }, isInterrupted: { [weak self] in self?.session.shell.isInterrupted ?? false })

            if streamedAny && !endedWithNewline { io.writeOut("\n") }

            if let error = reply.error {
                io.writeErr("\(red)claude: \(error)\(reset)\n")
                return 1
            }

            // Record what the model said (text + any tool_use blocks) as the assistant turn.
            if !reply.content.isEmpty {
                messages.append(["role": "assistant", "content": reply.content])
            }

            if reply.toolUses.isEmpty {
                return 0
            }

            // Run each requested tool and gather results for the next turn.
            var results: [[String: Any]] = []
            for tool in reply.toolUses {
                if session.shell.isInterrupted {
                    results.append(toolResult(tool.id, "Interrupted by the user.", isError: true))
                    continue
                }
                let (output, isError) = runTool(tool)
                results.append(toolResult(tool.id, output, isError: isError))
            }
            messages.append(["role": "user", "content": results])
        }
    }

    // MARK: Tools

    private func runTool(_ tool: AnthropicClient.ToolUse) -> (String, Bool) {
        switch tool.name {
        case "run_command":
            guard let command = tool.input["command"] as? String, !command.isEmpty else {
                return ("run_command needs a 'command' string.", true)
            }
            return runCommandTool(command)
        case "read_file":
            guard let path = tool.input["path"] as? String else { return ("read_file needs a 'path'.", true) }
            return readFileTool(path)
        case "write_file":
            guard let path = tool.input["path"] as? String, let content = tool.input["content"] as? String else {
                return ("write_file needs 'path' and 'content'.", true)
            }
            return writeFileTool(path, content)
        case "list_directory":
            let path = tool.input["path"] as? String ?? "."
            return listDirectoryTool(path)
        default:
            return ("Unknown tool \(tool.name).", true)
        }
    }

    private func runCommandTool(_ command: String) -> (String, Bool) {
        io.writeOut("\n\(accent)run\(reset) \(bold)\(command)\(reset)\n")
        guard confirm("Run this command?") else {
            io.writeOut("\(dim)skipped\(reset)\n")
            return ("User declined to run the command.", false)
        }
        // Merge stderr into the captured output and keep the sub-shell's own exit status.
        let (output, status) = sandbox.capture("{ " + command + " ; } 2>&1")
        let trimmed = trimForModel(output)
        if !trimmed.isEmpty { io.writeOut(trimmed.hasSuffix("\n") ? trimmed : trimmed + "\n") }
        io.writeOut("\(dim)exit \(status)\(reset)\n")
        let header = "Exit status: \(status)\n"
        return (header + (trimmed.isEmpty ? "(no output)" : trimmed), false)
    }

    private func readFileTool(_ path: String) -> (String, Bool) {
        let resolved = sandbox.resolvePath(path)
        guard let data = FileManager.default.contents(atPath: resolved) else {
            return ("Could not read \(path).", true)
        }
        io.writeOut("\(accent)read\(reset) \(path)\n")
        return (trimForModel(String(decoding: data, as: UTF8.self)), false)
    }

    private func writeFileTool(_ path: String, _ content: String) -> (String, Bool) {
        let resolved = sandbox.resolvePath(path)
        io.writeOut("\n\(accent)write\(reset) \(bold)\(path)\(reset) \(dim)(\(content.count) chars)\(reset)\n")
        guard confirm("Write this file?") else {
            io.writeOut("\(dim)skipped\(reset)\n")
            return ("User declined to write the file.", false)
        }
        do {
            let directory = (resolved as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try content.write(toFile: resolved, atomically: true, encoding: .utf8)
            io.writeOut("\(green)wrote \(path)\(reset)\n")
            return ("Wrote \(content.count) characters to \(path).", false)
        } catch {
            return ("Could not write \(path): \(error.localizedDescription)", true)
        }
    }

    private func listDirectoryTool(_ path: String) -> (String, Bool) {
        let resolved = sandbox.resolvePath(path)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: resolved) else {
            return ("Could not list \(path).", true)
        }
        io.writeOut("\(accent)list\(reset) \(path)\n")
        return (entries.sorted().joined(separator: "\n"), false)
    }

    // MARK: Confirmation

    private func confirm(_ question: String) -> Bool {
        if autoApprove { return true }
        guard let answer = session.readLine(prompt: "\(dim)\(question) [Y/n/a=always] \(reset)", secure: false) else {
            return false
        }
        switch answer.trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "y", "yes":
            return true
        case "a", "always":
            autoApprove = true
            return true
        default:
            return false
        }
    }

    // MARK: Request building

    private func appendUser(text: String) {
        messages.append(["role": "user", "content": [["type": "text", "text": text]]])
    }

    private func toolResult(_ id: String, _ content: String, isError: Bool) -> [String: Any] {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": content]
        if isError { block["is_error"] = true }
        return block
    }

    private func requestBody() -> [String: Any] {
        [
            "model": model,
            "max_tokens": 8192,
            "system": systemPrompt(),
            "messages": messages,
            "tools": toolSchemas(),
            "stream": true,
        ]
    }

    private func systemPrompt() -> String {
        """
        You are Claude, acting as a coding and shell assistant running inside Tern, a terminal \
        application on iOS and iPadOS. You are talking to the user through their terminal.

        You can act on the device with these tools: run_command (a non-interactive shell command), \
        read_file, write_file, and list_directory. Paths are relative to the current directory \
        (\(session.shell.workingDirectory)); ~ is the user's home. The user must confirm each command \
        and file write, so explain briefly what you are about to do.

        The shell is tsh, a POSIX-style shell. Available tools include git (as lg2), vim, curl, ssh, \
        python is not available; lua is. Do not run interactive programs (vim, less, ssh sessions, \
        top) through run_command, since it captures output and has no keyboard; edit files with \
        write_file instead. Keep answers concise and terminal-friendly: short lines, minimal markdown.
        """
    }

    private func toolSchemas() -> [[String: Any]] {
        [
            [
                "name": "run_command",
                "description": "Run a non-interactive shell command in the current directory and get its combined output and exit status.",
                "input_schema": [
                    "type": "object",
                    "properties": ["command": ["type": "string", "description": "The shell command to run."]],
                    "required": ["command"],
                ],
            ],
            [
                "name": "read_file",
                "description": "Read a text file and return its contents.",
                "input_schema": [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "File path, relative to the current directory or absolute."]],
                    "required": ["path"],
                ],
            ],
            [
                "name": "write_file",
                "description": "Create or overwrite a text file with the given contents.",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"],
                        "content": ["type": "string"],
                    ],
                    "required": ["path", "content"],
                ],
            ],
            [
                "name": "list_directory",
                "description": "List the entries in a directory.",
                "input_schema": [
                    "type": "object",
                    "properties": ["path": ["type": "string", "description": "Directory path. Defaults to the current directory."]],
                ],
            ],
        ]
    }

    /// Keeps tool output from blowing past the context: caps it and notes the truncation.
    private func trimForModel(_ text: String) -> String {
        let limit = 20_000
        if text.count <= limit { return text }
        let head = String(text.prefix(limit))
        return head + "\n[... truncated \(text.count - limit) characters ...]"
    }
}
