// SPDX-License-Identifier: GPL-2.0-or-later
import Darwin
import Foundation

// What the views show besides the library records: sizes, logs, settings and readable errors.
extension AppModel {
    /// True when `refresh()` found a built bundle for the game.
    public func isBuilt(_ titleID: String) -> Bool { builtApps[titleID] != nil }

    /// The bytes of games/<TITLE_ID>/ as `uninstall` counts them: every entry but directories,
    /// a symlink as itself (a referenced folder is never followed). 0 when the directory is missing.
    public func measureGameDir(_ titleID: String) async -> Int64 {
        guard let dir = try? library.gameDir(titleID: titleID) else { return 0 }
        return await Task.detached { Self.diskBytes(dir) }.value
    }

    /// The `lstat` sizes of the entries under `dir` other than directories; symlinks are not followed.
    nonisolated static func diskBytes(_ dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(atPath: dir.path) else { return 0 }
        var total: Int64 = 0
        var st = stat()
        for case let name as String in e {
            guard lstat(dir.appendingPathComponent(name).path, &st) == 0, st.st_mode & S_IFMT != S_IFDIR else { continue }
            total += Int64(st.st_size)
        }
        return total
    }

    /// The game's newest `logs/<stamp>-<kind>.log`, as last started or found by `scanLogs()`;
    /// its file may not exist yet while the operation is queued.
    public func latestLog(_ titleID: String, kind: String) -> URL? {
        latestLogs[titleID]?[kind]
    }

    /// Lists each game's logs directory off the main actor and keeps, per kind, the newer of
    /// the log found there and the one already known (the stamps sort by time).
    public func scanLogs() async {
        let dirs = games.compactMap { g in (try? library.logsDir(titleID: g.titleID)).map { (g.titleID, $0) } }
        let found = await Task.detached { dirs.map { ($0.0, Self.newestLogs(in: $0.1)) } }.value
        var merged: [String: [String: URL]] = [:]
        for (id, logs) in found {
            merged[id] = logs.merging(latestLogs[id] ?? [:]) { a, b in a.lastPathComponent >= b.lastPathComponent ? a : b }
        }
        if merged != latestLogs { latestLogs = merged }
    }

    /// The newest `<yyyy-MM-dd_HH-mm-ss>-<kind>.log` of each kind in `dir`.
    nonisolated static func newestLogs(in dir: URL) -> [String: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var newest: [String: String] = [:]
        let stampLength = "yyyy-MM-dd_HH-mm-ss-".count
        for name in names where name.hasSuffix(".log") && name.count > stampLength + 4 {
            let kind = String(name.dropFirst(stampLength).dropLast(4))
            if name > newest[kind, default: ""] { newest[kind] = name }
        }
        return newest.mapValues { dir.appendingPathComponent($0) }
    }

    /// The game's runtime settings (`settings/<TITLE_ID>.cfg`), read off the main actor; the
    /// defaults when it has none.
    public func settings(for titleID: String) async -> GameSettings {
        let dir = paths.settingsDir
        return await Task.detached { GameSettings.load(titleID: titleID, settingsDir: dir) }.value
    }

    /// Writes the game's runtime settings; a failure goes to `lastError`.
    public func saveSettings(_ settings: GameSettings, for titleID: String) {
        do {
            try settings.save(titleID: titleID, settingsDir: paths.settingsDir)
        } catch {
            report(error)
        }
    }

    /// Shows a failure of a view's call into the model (or into its stores) as `lastError`.
    public func report(_ error: any Error) {
        lastError = Self.describe(error)
    }

    public func dismissError() {
        lastError = nil
    }

    nonisolated static func describeApp(_ error: AppError) -> String {
        switch error {
        case .busy(let id): "\(id) is running or has an operation in progress; try again when it has finished"
        case .notInLibrary(let id): "\(id) is not in the library"
        case .notBuilt(let id): "\(id) has not been built yet"
        case .cannotImport(let why): "This item cannot be imported: \(why)"
        case .shortcutExists(let url): "\(url.path) already exists and is not a link of PS4 Native; it was left alone"
        case .cannotBuild(let id): "\(id) cannot be built: its content is not supported"
        case .buildNotConfirmed(let id): "The build of \(id) needs a confirmation first"
        case let .savesNotTrashed(freed, message):
            "The game was removed and \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) freed, "
                + "but its saves could not be moved to the Trash: \(message)"
        }
    }

    nonisolated static func describeSave(_ error: SaveError) -> String {
        switch error {
        case let .ditto(status, output): "ditto failed with status \(status): \(output)"
        case .noSaves(let id): "\(id) has no saves yet"
        case .invalidTitleID(let id): "\(id) is not a PS4 title ID"
        case .badArchive(let why): "This archive is not a save of this game: \(why)"
        case .outsideSaves(let path): "\(path) is not inside the saves directory"
        }
    }
}
