import Foundation
import UIKit
import TernCore

/// Commands that live in the app rather than in the shell or the toolchain: `help`, `tern`, `open`,
/// `pbcopy`, `pbpaste`, `history`, `clear`, `keys`, `hosts`, `settings`, `newtab`, `mount`, `umount`.
///
/// `runHostCommand` is called on the shell thread. Anything that touches UI hops to the main actor.
final class TernHostCommands: HostCommandProvider {
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    let hostCommandNames: [String] = ["help", "tern", "open", "pbcopy", "pbpaste", "history", "clear", "keys", "hosts", "settings", "newtab", "about", "mount", "umount"]

    func runHostCommand(_ argv: [String], io: ShellIO, session: ShellSession) -> Int32? {
        guard let name = argv.first else { return nil }
        let arguments = Array(argv.dropFirst())
        switch name {
        case "help":
            io.writeOut(HelpText.text(for: arguments.first))
            return 0
        case "about":
            io.writeOut(HelpText.about)
            return 0
        case "tern":
            return ternCommand(arguments, io: io)
        case "open":
            return openCommand(arguments, io: io, session: session)
        case "pbcopy":
            let bytes = FileDescriptorIO.readAll(io.stdin)
            let text = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async { UIPasteboard.general.string = text }
            return 0
        case "pbpaste":
            var text = ""
            DispatchQueue.main.sync { text = UIPasteboard.general.string ?? "" }
            io.writeOut(text)
            if !text.hasSuffix("\n") { io.writeOut("\n") }
            return 0
        case "history":
            return historyCommand(arguments, io: io, session: session)
        case "clear":
            io.writeOut("\u{1b}[H\u{1b}[2J\u{1b}[3J")
            return 0
        case "keys":
            present(.keys); return 0
        case "hosts":
            present(.hosts); return 0
        case "settings":
            present(.settings); return 0
        case "newtab":
            let directory = session.shell.workingDirectory
            let command = arguments.isEmpty ? nil : arguments.joined(separator: " ")
            DispatchQueue.main.async { [weak model] in
                _ = model?.newSession(workingDirectory: directory, initialCommand: command)
            }
            return 0
        case "mount":
            return mountCommand(arguments, io: io)
        case "umount":
            return unmountCommand(arguments, io: io)
        default:
            return nil
        }
    }

    // MARK: mount

    private static let dim = "\u{1b}[2m"
    private static let reset = "\u{1b}[0m"

    private func mountCommand(_ arguments: [String], io: ShellIO) -> Int32 {
        let store = MountStore.shared
        guard let first = arguments.first else {
            let entries = store.entries()
            if entries.isEmpty {
                io.writeOut("""
                Nothing is mounted. Attach a folder from the Files app with

                  mount Downloads

                It then appears at ~/mnt/Downloads. Type help mount for more.

                """)
                return 0
            }
            let width = entries.map { $0.mountPoint.count }.max() ?? 0
            for entry in entries {
                let point = entry.mountPoint.padding(toLength: width, withPad: " ", startingAt: 0)
                let note = entry.isAvailable ? "" : "  \(Self.dim)(unavailable: the folder was moved or deleted)\(Self.reset)"
                io.writeOut("\(point)  \(entry.location)\(note)\n")
            }
            return 0
        }
        if ["-h", "--help", "help"].contains(first) {
            io.writeOut(HelpText.mount)
            return 0
        }
        if first.hasPrefix("-") {
            io.writeErr("mount: unknown option \(first)\nusage: mount [name]   umount <name>\n")
            return 2
        }
        if arguments.count > 1 {
            io.writeErr("usage: mount [name]\n  mount            list mounted folders\n  mount Downloads  pick a folder in Files; it appears at ~/mnt/Downloads\n")
            return 2
        }
        let name = first
        do {
            try MountStore.validate(name: name)
        } catch {
            io.writeErr("mount: \(error.localizedDescription)\n")
            return 2
        }
        if store.isMounted(name) {
            io.writeErr("mount: \(MountStore.MountError.alreadyMounted(name).localizedDescription)\n")
            return 1
        }

        io.writeOut("\(Self.dim)Choose a folder in Files...\(Self.reset)\n")
        let finished = DispatchSemaphore(value: 0)
        var picked: URL?
        DispatchQueue.main.async {
            FolderPicker.present { url in
                picked = url
                finished.signal()
            }
        }
        finished.wait()
        // The picker took the keyboard with it; give it back to the terminal once the sheet is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak model] in
            model?.selected?.focus()
        }
        guard let url = picked else {
            io.writeErr("mount: cancelled\n")
            return 1
        }
        do {
            let entry = try store.mount(name: name, url: url)
            io.writeOut("Mounted \(entry.location) at \(entry.mountPoint)\n")
            io.writeOut("\(Self.dim)cd \(entry.mountPoint) to work there. umount \(name) detaches it again.\(Self.reset)\n")
            if entry.isCloud {
                io.writeOut("\(Self.dim)iCloud files that are not downloaded yet show as .name.icloud; opening them once in Files downloads them.\(Self.reset)\n")
            }
            return 0
        } catch {
            io.writeErr("mount: \(error.localizedDescription)\n")
            return 1
        }
    }

    private func unmountCommand(_ arguments: [String], io: ShellIO) -> Int32 {
        guard arguments.count == 1, !arguments[0].hasPrefix("-") else {
            io.writeErr("usage: umount <name>\n  umount Downloads  detach ~/mnt/Downloads (nothing inside it is deleted)\n")
            return 2
        }
        // Accept the mount point spelled out, too: umount ~/mnt/Downloads, umount mnt/Downloads.
        let name = arguments[0].split(separator: "/").last.map(String.init) ?? arguments[0]
        do {
            try MountStore.shared.unmount(name: name)
            io.writeOut("Unmounted ~/mnt/\(name)\n")
            return 0
        } catch {
            io.writeErr("umount: \(error.localizedDescription)\n")
            return 1
        }
    }

    private func present(_ sheet: AppModel.Sheet) {
        DispatchQueue.main.async { [weak model] in model?.presentedSheet = sheet }
    }

    private func ternCommand(_ arguments: [String], io: ShellIO) -> Int32 {
        guard let model else { return 1 }
        if arguments.first == "about" {
            io.writeOut(HelpText.about)
            return 0
        }
        if arguments.first == "diagnostics" {
            var report = ""
            DispatchQueue.main.sync { report = model.diagnosticsReport() }
            io.writeOut(report)
            return 0
        }
        var result = ""
        DispatchQueue.main.sync {
            result = model.settings.apply(command: arguments)
            model.refreshAppearance()
        }
        io.writeOut(result + "\n")
        return arguments.isEmpty ? 1 : 0
    }

    private func openCommand(_ arguments: [String], io: ShellIO, session: ShellSession) -> Int32 {
        guard let target = arguments.first else {
            io.writeErr("usage: open <file|directory|url>\n  open .        show this folder in the Files app\n  open file.txt open a file with another app\n  open https://example.com\n")
            return 2
        }
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
            DispatchQueue.main.async { UIApplication.shared.open(url) }
            return 0
        }
        let path = session.shell.resolvePath(target)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            io.writeErr("open: \(target): No such file or directory\n")
            return 1
        }
        // The Files app understands shareddocuments:// URLs pointing into the app container.
        let fileURL = URL(fileURLWithPath: path)
        if isDirectory.boolValue {
            if let filesURL = URL(string: "shareddocuments://" + fileURL.path) {
                DispatchQueue.main.async { UIApplication.shared.open(filesURL) }
            }
            return 0
        }
        DispatchQueue.main.async { [weak model] in
            model?.shareFile(at: fileURL)
        }
        return 0
    }

    private func historyCommand(_ arguments: [String], io: ShellIO, session: ShellSession) -> Int32 {
        if arguments.first == "-c" {
            session.history.clear()
            return 0
        }
        let entries = session.history.entries
        var slice = entries[...]
        if let first = arguments.first, let count = Int(first) {
            slice = entries.suffix(count)[...]
        }
        let offset = entries.count - slice.count
        var output = ""
        for (index, entry) in slice.enumerated() {
            output += String(format: "%5d  %@\n", offset + index + 1, entry)
        }
        io.writeOut(output)
        return 0
    }
}

extension AppModel {
    /// Presents the share sheet for a file (used by `open <file>`).
    func shareFile(at url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let root = scene.keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 80, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }
}
