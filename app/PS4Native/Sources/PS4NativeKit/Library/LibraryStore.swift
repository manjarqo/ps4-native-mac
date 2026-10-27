// SPDX-License-Identifier: GPL-2.0-or-later
import Darwin
import Foundation

/// The game library at `root`: library.json and games/<TITLE_ID>/{content,build,logs}, shared
/// with the engine. Every change to library.json or to a game's files holds the library lock,
/// as docs/game-manager-engine.md, "Lock contract", requires.
public struct LibraryStore: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    var libraryURL: URL { root.appendingPathComponent("library.json") }
    var lockURL: URL { root.appendingPathComponent(".lock") }
    var pendingURL: URL { root.appendingPathComponent("pending", isDirectory: true) }

    // MARK: Paths

    /// games/<TITLE_ID>/. Throws `LibraryError.badTitleID` for anything but a PS4 TITLE_ID.
    public func gameDir(titleID: String) throws -> URL {
        guard TitleID.isValid(titleID) else { throw LibraryError.badTitleID(titleID) }
        return root.appendingPathComponent("games", isDirectory: true).appendingPathComponent(titleID, isDirectory: true)
    }

    /// The game with its patches and DLC; a symlink to the source folder in reference mode.
    public func contentDir(titleID: String) throws -> URL {
        try gameDir(titleID: titleID).appendingPathComponent("content", isDirectory: true)
    }

    /// The build directory with the signed .app.
    public func buildDir(titleID: String) throws -> URL {
        try gameDir(titleID: titleID).appendingPathComponent("build", isDirectory: true)
    }

    /// The game's build and run logs, created by the app.
    public func logsDir(titleID: String) throws -> URL {
        try gameDir(titleID: titleID).appendingPathComponent("logs", isDirectory: true)
    }

    /// The first `*.app` directory in the build directory by name, nil when there is none.
    public func appBundle(titleID: String) throws -> URL? {
        let build = try buildDir(titleID: titleID)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: build.path) else { return nil }
        for name in names.sorted() where name.hasSuffix(".app") {
            let url = build.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return url }
        }
        return nil
    }

    // MARK: library.json

    /// library.json as it is now, read without the lock: for display only, never as the base of
    /// a change (use `update`). A library without the file is empty.
    public func snapshot() throws -> LibraryFile { try read() }

    /// Changes library.json under the library lock: waits for the lock (the engine holds it for
    /// a whole import), reads the file again, applies `body` and replaces the file atomically.
    /// Nothing is written when `body` throws. Throws `CancellationError` when cancelled while
    /// waiting, and `LibraryError.newerVersion` for a file of a newer schema, which is left as is.
    public func update(_ body: @Sendable (inout LibraryFile) throws -> Void) async throws {
        try await locked {
            var file = try read()
            try body(&file)
            try write(file)
        }
    }

    /// Removes a game under the library lock: its record, games/<TITLE_ID>/ and a pending patch
    /// (pending/<TITLE_ID>.json, pending/<TITLE_ID>.partial and pending/<TITLE_ID>/). Symlinks are
    /// removed, never followed, so the folder of a referenced game is untouched. Returns the bytes
    /// of the files removed.
    public func uninstall(titleID: String) async throws -> Int64 {
        let game = try gameDir(titleID: titleID)
        // The .json describing a pending patch goes first, so a half-removed pending/<ID>/ is ignored.
        let paths = [
            pendingURL.appendingPathComponent(titleID + ".json"),
            pendingURL.appendingPathComponent(titleID + ".partial", isDirectory: true),
            pendingURL.appendingPathComponent(titleID, isDirectory: true),
            game,
        ]
        return try await locked {
            var file = try read()
            let count = file.games.count
            file.games.removeAll { $0.titleID == titleID }
            if file.games.count != count { try write(file) }
            var freed: Int64 = 0
            for path in paths { freed += try removeTree(path) }
            return freed
        }
    }

    // MARK: Internals

    /// Runs `work` holding the library lock, creating the root if it is missing.
    private func locked<T>(_ work: () throws -> T) async throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try await FileLock.acquire(lockURL)
        defer { lock.release() }
        return try work()
    }

    private func read() throws -> LibraryFile {
        let data: Data
        do {
            data = try Data(contentsOf: libraryURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LibraryFile()
        }
        return try JSONDecoder().decode(LibraryFile.self, from: data)
    }

    /// Writes library.json as the engine does: games sorted by TITLE_ID, the current schema
    /// version, a temp file in the root synced to disk and renamed over the old file.
    private func write(_ file: LibraryFile) throws {
        var file = file
        file.version = LibraryFile.currentVersion
        file.games.sort { $0.titleID < $1.titleID }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(file)
        data.append(0x0A)

        let tmp = root.appendingPathComponent(".library.json-\(UUID().uuidString).tmp")
        do {
            try writeSynced(data, to: tmp)
            try tmp.withUnsafeFileSystemRepresentation { from in
                try libraryURL.withUnsafeFileSystemRepresentation { to in
                    guard rename(from!, to!) == 0 else { throw POSIXError.current() }
                }
            }
        } catch {
            tmp.withUnsafeFileSystemRepresentation { _ = unlink($0!) }
            throw error
        }
        // Make the rename itself durable. The new file is already in place, so a failure here
        // does not fail the update.
        root.withUnsafeFileSystemRepresentation { path in
            let dir = open(path!, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if dir >= 0 {
                _ = fsync(dir)
                close(dir)
            }
        }
    }

    /// Creates `url` with mode 0644 and `data`, flushed to the disk.
    private func writeSynced(_ data: Data, to url: URL) throws {
        let fd = url.withUnsafeFileSystemRepresentation { open($0!, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o644)) }
        guard fd >= 0 else { throw POSIXError.current() }
        defer { close(fd) }
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError.current()
                }
                offset += n
            }
        }
        guard fchmod(fd, 0o644) == 0 else { throw POSIXError.current() }
        // F_FULLFSYNC flushes the drive's cache as well, as Go's File.Sync does on Darwin; plain
        // fsync is the fallback for file systems that do not support it.
        if fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 { throw POSIXError.current() }
    }

    /// Removes `url` and everything under it without following symlinks (a symlink is unlinked,
    /// whatever it points to) and returns the sizes of the non-directory entries removed, from
    /// `lstat`. A missing `url` frees 0 bytes.
    private func removeTree(_ url: URL) throws -> Int64 {
        try url.withUnsafeFileSystemRepresentation { path -> Int64 in
            var st = stat()
            guard lstat(path!, &st) == 0 else {
                if errno == ENOENT { return 0 }
                throw POSIXError.current()
            }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                guard unlink(path!) == 0 else { throw POSIXError.current() }
                return Int64(st.st_size)
            }
            var freed: Int64 = 0
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
                freed += try removeTree(url.appendingPathComponent(name))
            }
            guard rmdir(path!) == 0 else { throw POSIXError.current() }
            return freed
        }
    }
}
