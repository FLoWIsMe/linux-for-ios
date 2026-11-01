import Foundation
import UIKit

/// Folders the user picked in the Files app (Downloads, iCloud Drive, another app's folder), attached
/// under `~/mnt` as symbolic links so every command can use them like any other directory.
///
/// iOS lets a sandboxed app reach a folder outside its container only through the URL the document
/// picker hands back. The URL carries a sandbox extension: calling `startAccessingSecurityScopedResource`
/// opens the folder for the whole process, which is what makes `ls ~/mnt/Downloads` work for ls, vim,
/// lg2 and everything else that runs in-process. A bookmark made from that URL is implicitly
/// security scoped on iOS and survives relaunches, so the store resolves every bookmark at startup,
/// starts accessing it again and refreshes the link in `~/mnt`.
final class MountStore {
    struct Mount: Codable {
        var name: String
        var bookmark: Data
        /// Last known real path, kept so `mount` can describe an entry whose bookmark no longer resolves.
        var path: String
    }

    /// What `mount` prints about one entry.
    struct Entry {
        let name: String
        let path: String
        /// Files app style description of `path`: "iCloud Drive/Downloads", "On My iPhone/Notes".
        let location: String
        let isAvailable: Bool
        let isCloud: Bool
        var mountPoint: String { "~/mnt/" + name }
    }

    enum MountError: LocalizedError {
        case invalidName(String)
        case alreadyMounted(String)
        case folderAlreadyMounted(String)
        case notMounted(String)
        case insideHome
        case mountPointOccupied(String)
        case accessDenied(String)
        case bookmark(Error)

        var errorDescription: String? {
            switch self {
            case .invalidName(let name):
                return "'\(name)' is not a valid mount name. Use letters, digits, dots, dashes and underscores."
            case .alreadyMounted(let name):
                return "~/mnt/\(name) is already mounted. Run umount \(name) first."
            case .folderAlreadyMounted(let name):
                return "that folder is already mounted at ~/mnt/\(name)."
            case .notMounted(let name):
                return "~/mnt/\(name) is not mounted."
            case .insideHome:
                return "that folder is already inside your home directory; cd to it instead."
            case .mountPointOccupied(let name):
                return "~/mnt/\(name) exists and is not a mount. Move it away first."
            case .accessDenied(let location):
                return "iOS did not grant access to \(location)."
            case .bookmark(let error):
                return "could not keep access to the folder: \(error.localizedDescription)"
            }
        }
    }

    static let shared = MountStore(homeDirectory: SystemEnvironment.homeDirectory,
                                   libraryDirectory: SystemEnvironment.libraryDirectory)

    /// `~/mnt`. Created on the first mount and removed again after the last umount, so the Files app
    /// does not show an empty folder to people who never use the feature.
    let mountDirectory: String

    private let homeDirectory: String
    private let storeURL: URL
    private let lock = NSLock()
    private var mounts: [Mount] = []
    /// URLs whose security scope is open, by mount name. Kept so umount can close the scope.
    private var accessed: [String: URL] = [:]
    private var unavailable: Set<String> = []
    /// "iPhone" or "iPad", for "On My iPhone". Read once here, on the main thread, during bootstrap.
    private let deviceWord: String

    init(homeDirectory: String, libraryDirectory: String) {
        self.homeDirectory = homeDirectory
        deviceWord = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        mountDirectory = homeDirectory + "/mnt"
        storeURL = URL(fileURLWithPath: libraryDirectory + "/Application Support/mounts.json")
        if let data = try? Data(contentsOf: storeURL),
           let saved = try? JSONDecoder().decode([Mount].self, from: data) {
            mounts = saved
        }
    }

    // MARK: Startup

    /// Reopens every saved folder and repairs the links in `~/mnt`. Called once from bootstrap, before
    /// the first shell starts, so `~/.ternrc` can already refer to mounted folders.
    func restoreAll() {
        lock.lock(); defer { lock.unlock() }
        var dirty = false
        unavailable = []
        for index in mounts.indices {
            let mount = mounts[index]
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: mount.bookmark, options: [.withoutUI], relativeTo: nil,
                                     bookmarkDataIsStale: &stale) else {
                unavailable.insert(mount.name)
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            accessed[mount.name] = url
            if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                mounts[index].bookmark = fresh
                dirty = true
            }
            if url.path != mount.path {
                mounts[index].path = url.path
                dirty = true
            }
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                unavailable.insert(mount.name)
            }
            try? refreshLink(name: mount.name, path: url.path)
        }
        if dirty { save() }
    }

    // MARK: Mounting

    func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return mounts.map { mount in
            Entry(name: mount.name, path: mount.path, location: friendlyLocation(for: mount.path),
                  isAvailable: !unavailable.contains(mount.name),
                  isCloud: MountStore.isCloudPath(mount.path, url: accessed[mount.name]))
        }
    }

    func isMounted(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mounts.contains { $0.name == name }
    }

    /// Attaches the folder behind a document picker URL at `~/mnt/<name>`.
    func mount(name: String, url: URL) throws -> Entry {
        try MountStore.validate(name: name)
        let path = url.standardizedFileURL.path
        if path == homeDirectory || path.hasPrefix(homeDirectory + "/") {
            throw MountError.insideHome
        }
        lock.lock(); defer { lock.unlock() }
        if mounts.contains(where: { $0.name == name }) { throw MountError.alreadyMounted(name) }
        if let existing = mounts.first(where: { $0.path == path }) { throw MountError.folderAlreadyMounted(existing.name) }

        let granted = url.startAccessingSecurityScopedResource()
        guard granted || FileManager.default.isReadableFile(atPath: path) else {
            throw MountError.accessDenied(friendlyLocation(for: path))
        }
        let bookmark: Data
        do {
            bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            if granted { url.stopAccessingSecurityScopedResource() }
            throw MountError.bookmark(error)
        }
        do {
            try refreshLink(name: name, path: path)
        } catch {
            if granted { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        accessed[name] = url
        mounts.append(Mount(name: name, bookmark: bookmark, path: path))
        save()
        return Entry(name: name, path: path, location: friendlyLocation(for: path), isAvailable: true,
                     isCloud: MountStore.isCloudPath(path, url: url))
    }

    /// Removes the link and forgets the folder. Nothing inside the folder is touched.
    func unmount(name: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let index = mounts.firstIndex(where: { $0.name == name }) else { throw MountError.notMounted(name) }
        let link = mountDirectory + "/" + name
        if isSymbolicLink(link) {
            try FileManager.default.removeItem(atPath: link)
        }
        accessed.removeValue(forKey: name)?.stopAccessingSecurityScopedResource()
        unavailable.remove(name)
        mounts.remove(at: index)
        save()
        if let remaining = try? FileManager.default.contentsOfDirectory(atPath: mountDirectory), remaining.isEmpty {
            try? FileManager.default.removeItem(atPath: mountDirectory)
        }
    }

    static func validate(name: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !name.isEmpty, name.count <= 64, name != ".", name != "..",
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw MountError.invalidName(name)
        }
    }

    // MARK: Describing locations

    /// A Files app style description of a real path: "iCloud Drive/Downloads", "On My iPhone/Notes".
    func friendlyLocation(for path: String) -> String {
        func rest(after marker: String) -> String? {
            guard let range = path.range(of: marker) else { return nil }
            let tail = String(path[range.upperBound...])
            return tail.hasPrefix("/") ? String(tail.dropFirst()) : tail
        }
        if let tail = rest(after: "/Mobile Documents/com~apple~CloudDocs") {
            return tail.isEmpty ? "iCloud Drive" : "iCloud Drive/" + tail
        }
        if let tail = rest(after: "/File Provider Storage") {
            return tail.isEmpty ? "On My \(deviceWord)" : "On My \(deviceWord)/" + tail
        }
        if let tail = rest(after: "/Mobile Documents/") {
            // Another app's iCloud container: iCloud~com~example~app/Documents/Folder.
            let parts = tail.split(separator: "/").map(String.init)
            let container = parts.first.map { $0.replacingOccurrences(of: "iCloud~", with: "").replacingOccurrences(of: "~", with: ".") } ?? ""
            let remainder = parts.dropFirst().filter { $0 != "Documents" }.joined(separator: "/")
            return "iCloud/" + container + (remainder.isEmpty ? "" : "/" + remainder)
        }
        return path
    }

    private static func isCloudPath(_ path: String, url: URL?) -> Bool {
        if path.contains("/Mobile Documents/") { return true }
        if let url, let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]) {
            return values.isUbiquitousItem ?? false
        }
        return false
    }

    // MARK: Files

    private func refreshLink(name: String, path: String) throws {
        let fm = FileManager.default
        let link = mountDirectory + "/" + name
        if isSymbolicLink(link) {
            if (try? fm.destinationOfSymbolicLink(atPath: link)) == path { return }
            try fm.removeItem(atPath: link)
        } else if fm.fileExists(atPath: link) {
            throw MountError.mountPointOccupied(name)
        }
        try fm.createDirectory(atPath: mountDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: path)
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if mounts.isEmpty {
            try? fm.removeItem(at: storeURL)
            return
        }
        if let data = try? JSONEncoder().encode(mounts) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
