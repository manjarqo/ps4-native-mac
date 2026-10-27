// SPDX-License-Identifier: GPL-2.0-or-later
import Darwin
import Foundation

public enum SaveError: Error, Equatable, Sendable {
    case ditto(Int32, String)
    case noSaves(String)
    case invalidTitleID(String)
    /// The archive does not hold exactly one real directory named `<name> [<TITLE_ID>]`.
    case badArchive(String)
    case outsideSaves(String)
}

public struct SaveSlot: Sendable, Equatable, Identifiable {
    public let url: URL
    /// The `user_XXXXXXXX` directory name.
    public let user: String
    /// The slot directory name, e.g. `SAVEDATA00`.
    public let name: String
    public let param: SaveParam?
    public let bytes: Int64
    public var id: URL { url }
}

/// The runtime's save data: `<savesDir>/<Title [TITLE_ID]>/user_XXXXXXXX/<slot>/`.
public struct SaveStore: Sendable {
    public let savesDir: URL
    public let backupsDir: URL
    private let trash: @Sendable (URL) throws -> Void

    public init(savesDir: URL, backupsDir: URL,
                trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.savesDir = savesDir
        self.backupsDir = backupsDir
        self.trash = trash
    }

    /// Game directories whose name ends in `" [<TITLE_ID>]"` after at least one character, newest
    /// modification first and, at equal times, the greater name first: the runtime's rule
    /// (`ps4_find_save_dir_by_title_id`, by `lstat`, so a symlink is not a game directory).
    public func gameDirs(titleID: String) -> [URL] {
        guard TitleID.isValid(titleID) else { return [] }
        let suffix = Array(" [\(titleID)]".utf8)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: savesDir.path)) ?? []
        var dirs: [(name: [UInt8], url: URL, mtime: timespec)] = []
        var st = stat()
        for name in names {
            let bytes = Array(name.utf8)
            guard bytes.count > suffix.count, bytes.suffix(suffix.count).elementsEqual(suffix) else { continue }
            let url = savesDir.appendingPathComponent(name, isDirectory: true)
            guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
            dirs.append((bytes, url, st.st_mtimespec))
        }
        dirs.sort { a, b in
            if a.mtime.tv_sec != b.mtime.tv_sec { return a.mtime.tv_sec > b.mtime.tv_sec }
            if a.mtime.tv_nsec != b.mtime.tv_nsec { return a.mtime.tv_nsec > b.mtime.tv_nsec }
            return b.name.lexicographicallyPrecedes(a.name)
        }
        return dirs.map(\.url)
    }

    /// The slots of the newest game directory, by user then slot name.
    public func slots(titleID: String) -> [SaveSlot] {
        guard let game = gameDirs(titleID: titleID).first else { return [] }
        let fm = FileManager.default
        var out: [SaveSlot] = []
        let users = ((try? fm.contentsOfDirectory(at: game, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("user_") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for user in users {
            let slotDirs = ((try? fm.contentsOfDirectory(at: user, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for slot in slotDirs {
                let param = (try? Data(contentsOf: slot.appendingPathComponent("sce_sys/param.bin")))
                    .flatMap { try? SaveParam(data: $0) }
                out.append(SaveSlot(url: slot, user: user.lastPathComponent, name: slot.lastPathComponent,
                                    param: param, bytes: Self.size(of: slot)))
            }
        }
        return out
    }

    private static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }

    /// Zips the game directory into `<backups>/<TITLE_ID>-<yyyyMMdd-HHmmss>.zip`.
    @discardableResult
    public func backup(titleID: String) throws -> URL {
        guard TitleID.isValid(titleID) else { throw SaveError.invalidTitleID(titleID) }
        try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        var dest = backupsDir.appendingPathComponent("\(titleID)-\(f.string(from: Date())).zip")
        // Two backups in one second (restore backs up first) must not overwrite each other.
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = backupsDir.appendingPathComponent("\(titleID)-\(f.string(from: Date()))-\(n).zip")
            n += 1
        }
        try export(titleID: titleID, to: dest)
        return dest
    }

    /// Backups of this title, newest first.
    public func backups(titleID: String) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: backupsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard TitleID.isValid(titleID) else { return [] }
        let prefix = "\(titleID)-"
        var found: [(url: URL, modified: Date)] = []
        for u in items where u.lastPathComponent.hasPrefix(prefix) && u.pathExtension == "zip" {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            found.append((u, m ?? Date.distantPast))
        }
        found.sort { a, b in
            a.modified != b.modified ? a.modified > b.modified : a.url.lastPathComponent > b.url.lastPathComponent
        }
        return found.map { $0.url }
    }

    /// Unpacks the zip into a staging directory and checks it holds exactly one real directory named
    /// `<name> [<TITLE_ID>]`; only then backs up, moves the current game directory to the Trash and
    /// moves the staged one in. Any failure before that leaves the live save untouched.
    public func restore(titleID: String, from zip: URL) throws {
        guard TitleID.isValid(titleID) else { throw SaveError.invalidTitleID(titleID) }
        let fm = FileManager.default
        try fm.createDirectory(at: savesDir, withIntermediateDirectories: true)
        let staging = savesDir.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        try Self.ditto(["-x", "-k"], zip, staging)
        let staged = try Self.verifiedGameDir(in: staging, titleID: titleID)

        let current = gameDirs(titleID: titleID).first
        if current != nil { try backup(titleID: titleID) }
        if let current { try trash(current) }
        let dest = savesDir.appendingPathComponent(staged.lastPathComponent, isDirectory: true)
        try fm.moveItem(at: staged, to: dest)
        // The runtime picks the newest game directory by modification time.
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
    }

    private static func verifiedGameDir(in staging: URL, titleID: String) throws -> URL {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard entries.count == 1, let dir = entries.first else {
            throw SaveError.badArchive("expected one top-level directory, found \(entries.count) entries")
        }
        let v = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard v.isDirectory == true, v.isSymbolicLink != true else {
            throw SaveError.badArchive("\(dir.lastPathComponent) is not a directory")
        }
        guard dir.lastPathComponent.hasSuffix(" [\(titleID)]") else {
            throw SaveError.badArchive("\(dir.lastPathComponent) is not a save of \(titleID)")
        }
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw SaveError.badArchive("cannot read \(dir.lastPathComponent)")
        }
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw SaveError.badArchive("the archive contains a symbolic link: \(u.lastPathComponent)")
        }
        return dir
    }

    /// Zips the game directory to a chosen URL; a partial zip is removed on failure.
    public func export(titleID: String, to: URL) throws {
        guard TitleID.isValid(titleID) else { throw SaveError.invalidTitleID(titleID) }
        guard let game = gameDirs(titleID: titleID).first else { throw SaveError.noSaves(titleID) }
        do {
            try Self.ditto(["-c", "-k", "--keepParent"], game, to)
        } catch {
            try? FileManager.default.removeItem(at: to)
            throw error
        }
    }

    public func importZip(_ zip: URL, titleID: String) throws {
        try restore(titleID: titleID, from: zip)
    }

    /// Moves a slot directory to the Trash; refuses anything outside the saves directory.
    public func deleteSlot(_ slot: SaveSlot) throws {
        let root = savesDir.standardizedFileURL.path
        let path = slot.url.standardizedFileURL.path
        guard path.hasPrefix(root.hasSuffix("/") ? root : root + "/"), path.count > root.count + 1 else {
            throw SaveError.outsideSaves(path)
        }
        try trash(slot.url)
    }

    /// Moves every game directory of `titleID` (`gameDirs`) to the Trash, for an uninstall that
    /// does not keep the saves.
    public func trashSaves(titleID: String) throws {
        for dir in gameDirs(titleID: titleID) { try trash(dir) }
    }

    private static func ditto(_ flags: [String], _ source: URL, _ destination: URL) throws {
        for u in [source, destination] where !u.path.hasPrefix("/") {
            throw SaveError.badArchive("relative path: \(u.path)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = flags + [source.standardizedFileURL.path, destination.standardizedFileURL.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        // Read before waiting so a full pipe cannot stall ditto.
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw SaveError.ditto(p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
    }
}
