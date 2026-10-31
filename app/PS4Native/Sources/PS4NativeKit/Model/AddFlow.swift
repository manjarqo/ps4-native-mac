// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// An inspected PKG or folder in the add sheet, waiting for the user to import it.
public struct AddCandidate: Identifiable, Sendable, Equatable {
    /// The engine's refusal of a retail PKG (docs/game-manager-engine.md, "Retail PKGs and fpkg").
    public static let retailMessage = "this PKG is encrypted with console keys; use a dump of your own console or an fpkg"
    public static let noEbootMessage = "this folder has no eboot.bin"
    /// The room an import keeps free on top of what it writes.
    static let margin: Int64 = 1 << 30

    public let id: UUID
    public let url: URL
    /// nil when `inspect` failed.
    public let inspect: InspectResult?
    public let error: EngineFailure?
    /// Whether a folder holds eboot.bin; true for a PKG, whose files are only known on import.
    let hasEboot: Bool
    /// The import mode the sheet preselects; always `copy` for a PKG.
    public internal(set) var mode: ImportMode

    public var isFolder: Bool { inspect?.kind == "folder" }

    /// What the import needs on the library volume: the unpacked size (nothing for a folder
    /// used in place) plus 1 GiB.
    public var neededBytes: Int64 {
        (isFolder && mode == .reference ? 0 : inspect?.unpackedSize ?? 0) + Self.margin
    }

    /// `unsupported_input` for a retail PKG, a broken PKG or a folder without eboot.bin
    /// (docs/game-manager-engine.md, "Support statuses"); nil otherwise.
    public var status: String? { isUnsupported ? "unsupported_input" : nil }

    public var canConfirm: Bool { inspect != nil && error == nil && !isUnsupported }

    /// Why the candidate cannot be imported, for display; nil when it can.
    public var message: String? {
        if let error { return error.message }
        if inspect?.signing == "retail" { return Self.retailMessage }
        if isFolder && !hasEboot { return Self.noEbootMessage }
        return nil
    }

    private var isUnsupported: Bool {
        error?.code == "bad_pkg" || inspect?.signing == "retail" || (isFolder && !hasEboot)
    }
}

extension AppModel {
    /// How many `inspect` commands `add` runs at once.
    static let maxConcurrentInspects = 4

    /// Inspects each URL and appends the candidates, in the order of `urls`, to `pendingCandidates`.
    /// A URL given twice, or already on the add sheet, is inspected once.
    public func add(_ urls: [URL]) async {
        await add(urls, folderMode: .copy)
    }

    /// The first-run import of a dumped folder: `add` with "Use in place" preselected.
    public func importExistingFolder(_ url: URL) async {
        await add([url], folderMode: .reference)
    }

    private func add(_ urls: [URL], folderMode: ImportMode) async {
        var seen = Set(pendingCandidates.map(\.url.standardizedFileURL.path))
        let urls = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        let engine = engine
        let found = await withTaskGroup(of: (Int, AddCandidate).self) { group in
            var results = [AddCandidate?](repeating: nil, count: urls.count)
            for (i, url) in urls.enumerated() {
                if i >= Self.maxConcurrentInspects, let (j, c) = await group.next() { results[j] = c }
                group.addTask { (i, await Self.candidate(for: url, engine: engine, folderMode: folderMode)) }
            }
            for await (j, c) in group { results[j] = c }
            return results.compactMap { $0 }
        }
        pendingCandidates.append(contentsOf: found)
        await measureFreeSpace()
    }

    private nonisolated static func candidate(for url: URL, engine: any Engine, folderMode: ImportMode) async -> AddCandidate {
        do {
            let inspect = try await engine.inspect(url)
            let folder = inspect.kind == "folder"
            let hasEboot = !folder || FileManager.default.fileExists(atPath: url.appendingPathComponent("eboot.bin").path)
            return AddCandidate(id: UUID(), url: url, inspect: inspect, error: nil, hasEboot: hasEboot,
                                mode: folder ? folderMode : .copy)
        } catch {
            let failure = error as? EngineFailure ?? EngineFailure(code: "app", message: describe(error))
            return AddCandidate(id: UUID(), url: url, inspect: nil, error: failure, hasEboot: true, mode: .copy)
        }
    }

    /// Changes the preselected mode of a folder candidate.
    public func setMode(_ mode: ImportMode, for id: AddCandidate.ID) {
        guard let i = pendingCandidates.firstIndex(where: { $0.id == id }), pendingCandidates[i].isFolder else { return }
        pendingCandidates[i].mode = mode
    }

    /// Takes a candidate off the add sheet without importing it.
    public func dismiss(_ id: AddCandidate.ID) {
        pendingCandidates.removeAll { $0.id == id }
    }

    /// True when the import needs more than the library volume has free.
    public func spaceShort(_ c: AddCandidate) -> Bool {
        c.neededBytes > libraryFreeBytes
    }

    /// Queues the import of a candidate. When it succeeds, a game or patch that was applied is
    /// analysed; a pending patch and DLC are not.
    public func confirm(_ c: AddCandidate, mode: ImportMode) throws {
        guard let inspect = c.inspect, c.canConfirm else {
            throw AppError.cannotImport(c.message ?? "this item cannot be imported")
        }
        guard mode == .copy || c.isFolder else { throw AppError.cannotImport("reference mode applies to folders only") }
        let titleID = TitleID.isValid(inspect.titleID) ? inspect.titleID : nil
        // An update, DLC or re-import changes the content (and an update the bundle's version):
        // not under a running game or a build of it.
        if let titleID, launcher.running[titleID] != nil || uninstalling.contains(titleID) || hasActiveBuild(titleID) {
            throw AppError.busy(titleID)
        }
        pendingCandidates.removeAll { $0.id == c.id }
        Task { await measureFreeSpace() }
        let log = importLogURL(titleID)
        let engine = engine, root = library.root, url = c.url
        queue.enqueue(kind: .importGame, title: inspect.title, titleID: titleID, log: log) { [weak self] progress in
            let result = try await engine.importGame(url, library: root, mode: mode, log: log, onEvent: progress)
            await self?.imported(result)
        }
    }

    /// logs/<stamp>-import-<TITLE_ID>.log in the library root (the game directory may not exist
    /// yet), with "-2", "-3", ... added while a queued operation or a file already has the name:
    /// "Import all" confirms several items in one second, and each import keeps its own log.
    func importLogURL(_ titleID: String?) -> URL {
        let dir = library.root.appendingPathComponent("logs", isDirectory: true)
        let base = "\(Self.stamp())-import-\(titleID ?? "game")"
        let taken = Set(queue.items.map(\.log.lastPathComponent))
        var n = 1
        while true {
            let name = n == 1 ? "\(base).log" : "\(base)-\(n).log"
            let url = dir.appendingPathComponent(name)
            if !taken.contains(name) && !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    private func imported(_ result: ImportResult) async {
        refresh()
        await measureFreeSpace()
        guard !result.pending, result.kind == "game" || result.kind == "patch" else { return }
        do {
            try analyze(result.titleID)
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// `analysis(for:)` with games/<ID>/analysis.json read off the main actor, for the views.
    public func loadAnalysis(_ titleID: String) async -> GameAnalysis? {
        if let analysis = analyses[titleID] { return analysis }
        if let stored = storedAnalyses[titleID] { return stored }
        guard let dir = try? library.gameDir(titleID: titleID) else { return nil }
        let stored = await Task.detached { Self.readAnalysis(in: dir) }.value
        // An analysis that finished meanwhile wins.
        if let analysis = analyses[titleID] { return analysis }
        storedAnalyses[titleID] = stored
        return stored
    }

    /// The latest analysis of a game: this session's, else games/<ID>/analysis.json (read once).
    public func analysis(for titleID: String) -> GameAnalysis? {
        if let analysis = analyses[titleID] { return analysis }
        if let stored = storedAnalyses[titleID] { return stored }
        let stored = (try? library.gameDir(titleID: titleID)).flatMap(Self.readAnalysis(in:))
        storedAnalyses[titleID] = stored
        return stored
    }

    nonisolated static let analysisFile = "analysis.json"

    nonisolated static func readAnalysis(in gameDir: URL) -> GameAnalysis? {
        guard let data = try? Data(contentsOf: gameDir.appendingPathComponent(analysisFile)) else { return nil }
        return try? JSONDecoder().decode(GameAnalysis.self, from: data)
    }

    /// Queues `analyze-game` of the game's content. The verdict's status is written to the
    /// record; the analysis is kept in `analyses` and in games/<ID>/analysis.json, which is the
    /// app's own file next to content/ (never inside it, so a referenced folder is untouched).
    public func analyze(_ titleID: String) throws {
        let content = try library.contentDir(titleID: titleID)
        let file = try library.gameDir(titleID: titleID).appendingPathComponent(Self.analysisFile)
        let log = try logURL(titleID, "analyze")
        let title = games.first { $0.titleID == titleID }?.title ?? titleID
        let engine = engine, library = library
        queue.enqueue(kind: .analyze, title: title, titleID: titleID, log: log) { [weak self] progress in
            let analysis = try await engine.analyze(content: content, log: log, onEvent: progress)
            let data = try JSONEncoder().encode(analysis)
            // Under the library lock, so an uninstall cannot remove the game in between and
            // leave a stray games/<ID>/ behind.
            try await library.update { lib in
                guard let i = lib.games.firstIndex(where: { $0.titleID == titleID }) else { return }
                lib.games[i].status = analysis.verdict.status
                try data.write(to: file, options: .atomic)
            }
            await self?.analyzed(titleID, analysis)
        }
    }

    private func analyzed(_ titleID: String, _ analysis: GameAnalysis) {
        analyses[titleID] = analysis
        storedAnalyses[titleID] = nil
        refresh()
    }
}
