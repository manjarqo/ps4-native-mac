// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Observation

public enum AppError: Error, Equatable, Sendable {
    /// The game runs, is being uninstalled, or has an operation queued or running.
    case busy(String)
    case notInLibrary(String)
    /// The game has no built `.app` yet.
    case notBuilt(String)
    /// An add candidate that cannot be imported, with the reason to show.
    case cannotImport(String)
    /// Something that is not a link of ours is at the shortcut's path; it is left alone.
    case shortcutExists(URL)
    /// The game was uninstalled and `freed` bytes were freed, but its saves could not be moved
    /// to the Trash.
    case savesNotTrashed(freed: Int64, message: String)
    /// The game's content cannot be built (`unsupported_input`).
    case cannotBuild(String)
    /// The build of an `other_version` or `experimental` game waits for the user's confirmation
    /// (`build(_:confirmed:)`).
    case buildNotConfirmed(String)
}

/// The large button of a game page. A built game keeps PLAY; a rebuild is offered by a banner.
public enum PrimaryAction: Sendable, Equatable {
    case play, build, running
    /// An import, analysis or build of the game is queued or running, or it is being uninstalled.
    case busy
}

/// What a Build or Rebuild of a game asks first, from its support status.
public enum BuildGate: Sendable, Equatable {
    /// `playable`, `in_progress`, or not analysed yet: the build starts.
    case none
    /// `other_version`: a confirmation that names the tested versions.
    case confirmVersion
    /// `experimental`: the analysis report, with "Build anyway".
    case analysisReport
    /// `unsupported_input`: no build.
    case refused
}

/// The built bundle of a game, as `refresh()` found it.
struct BuiltApp: Equatable {
    let url: URL
    /// CFBundleShortVersionString: the content's APP_VER (falling back to VERSION) at build time.
    let version: String?
}

/// The app's view model: the library, the add flow, builds, play sessions, rebuild offers,
/// uninstall and the first run. Views call into it and show its state.
@MainActor @Observable
public final class AppModel {
    /// Set in the defaults once the user has finished the first-run sheet.
    public static let firstRunDoneKey = "ps4native.firstRunDone"

    public let paths: Paths
    public let launcher: GameLauncher
    public let queue: EngineOperationQueue
    public let library: LibraryStore
    public let saves: SaveStore

    /// library.json's games, refreshed after every operation and on `refresh()`.
    public private(set) var games: [GameRecord] = []
    public var selection: String?
    /// The engine's version, read by `start()`; nil until then or when the engine fails.
    public private(set) var engineVersion: String?
    public private(set) var toolchain: ToolchainReport?
    /// True after `start()` when the library is empty and the first run was never finished.
    public private(set) var firstRunNeeded = false
    /// The analyses finished in this session, by TITLE_ID; `analysis(for:)` also reads older
    /// ones from games/<ID>/analysis.json.
    public internal(set) var analyses: [String: GameAnalysis] = [:]
    /// The run log of a game whose last session ended in a crash, by TITLE_ID.
    public private(set) var lastCrashLog: [String: URL] = [:]
    /// The inspected items of the add sheet, in the order they were added.
    public internal(set) var pendingCandidates: [AddCandidate] = []
    /// The last failure of a step that has no queue item (a library read or write, the engine
    /// version), for display.
    public internal(set) var lastError: String?
    /// The games being uninstalled now.
    public private(set) var uninstalling: Set<String> = []

    /// The games used in place (content/ is a symlink to their folder), read by `refresh()`.
    public private(set) var usedInPlace: Set<String> = []
    /// Each game's built bundle, read by `refresh()` so that views do no disk I/O.
    var builtApps: [String: BuiltApp] = [:]
    /// The bytes of each built game's build directory, measured off the main actor after
    /// `refresh()` (`measureBuilds()`).
    public private(set) var buildBytes: [String: Int64] = [:]
    /// The free bytes of the library volume, measured off the main actor at `start()`, after
    /// `add` and when an import is confirmed or done (`measureFreeSpace()`); 0 until then.
    public private(set) var libraryFreeBytes: Int64 = 0
    /// The newest log of each kind ("build", "run", "analyze") by TITLE_ID: set when an
    /// operation or session is started, and merged with the logs directory by `scanLogs()`.
    var latestLogs: [String: [String: URL]] = [:]

    @ObservationIgnored let engine: any Engine
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let applicationsDir: URL
    @ObservationIgnored let freeSpace: @Sendable (URL) -> Int64
    @ObservationIgnored private let toolchainCheck: @Sendable (URL) -> ToolchainReport
    /// The log of each running game's session.
    @ObservationIgnored private var runLogs: [String: URL] = [:]
    /// analysis.json files read by `analysis(for:)`, nil for a game that has none.
    @ObservationIgnored var storedAnalyses: [String: GameAnalysis?] = [:]
    /// The `measureBuilds()` started by the last `refresh()`.
    @ObservationIgnored private var measureTask: Task<Void, Never>?

    /// `applicationsDir` is where `addToApplications` puts its links; `freeSpace` gives the free
    /// bytes of a URL's volume; `toolchainCheck` checks the toolchain for a library root.
    public init(paths: Paths, engine: any Engine, launcher: GameLauncher, queue: EngineOperationQueue,
                library: LibraryStore, saves: SaveStore, defaults: UserDefaults = .standard,
                applicationsDir: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
                freeSpace: @escaping @Sendable (URL) -> Int64 = Toolchain.freeBytes(at:),
                toolchainCheck: @escaping @Sendable (URL) -> ToolchainReport = { Toolchain.check(library: $0) }) {
        self.paths = paths
        self.engine = engine
        self.launcher = launcher
        self.queue = queue
        self.library = library
        self.saves = saves
        self.defaults = defaults
        self.applicationsDir = applicationsDir
        self.freeSpace = freeSpace
        self.toolchainCheck = toolchainCheck
        launcher.onExit = { [weak self] titleID, seconds, status in
            self?.gameExited(titleID, seconds: seconds, status: status)
        }
    }

    /// Reads the library, decides whether the first run is needed, asks the engine its version
    /// and checks the toolchain.
    public func start() async {
        firstRunNeeded = refresh() && games.isEmpty && defaults.object(forKey: Self.firstRunDoneKey) == nil
        do {
            engineVersion = try await engine.version().version
        } catch {
            lastError = Self.describe(error)
        }
        await checkToolchain()
        await measureFreeSpace()
    }

    /// Reads the free space of the library volume off the main actor into `libraryFreeBytes`.
    public func measureFreeSpace() async {
        let measure = freeSpace, root = library.root
        let free = await Task.detached { measure(root) }.value
        if free != libraryFreeBytes { libraryFreeBytes = free }
    }

    /// Checks the toolchain off the main actor (it runs `xcrun` and `clang`).
    public func checkToolchain() async {
        let check = toolchainCheck, root = library.root
        toolchain = await Task.detached { check(root) }.value
    }

    /// Re-reads library.json and each game's built bundle. Returns false, keeping the old
    /// list, when library.json cannot be read.
    @discardableResult
    public func refresh() -> Bool {
        do {
            games = try library.snapshot().games
        } catch {
            lastError = Self.describe(error)
            return false
        }
        var built: [String: BuiltApp] = [:]
        for g in games {
            if let url = try? library.appBundle(titleID: g.titleID) {
                built[g.titleID] = BuiltApp(url: url, version: Self.bundleVersion(url))
            }
        }
        if built != builtApps { builtApps = built }
        let inPlace = Set(games.map(\.titleID).filter { (try? library.isUsedInPlace(titleID: $0)) == true })
        if inPlace != usedInPlace { usedInPlace = inPlace }
        measureTask?.cancel()
        measureTask = Task { [weak self] in
            await self?.measureBuilds()
            await self?.scanLogs()
        }
        return true
    }

    /// Measures the build directory of each built game off the main actor into `buildBytes`.
    public func measureBuilds() async {
        let dirs = builtApps.keys.compactMap { id in (try? library.buildDir(titleID: id)).map { (id, $0) } }
        let sizes = await Task.detached {
            Dictionary(uniqueKeysWithValues: dirs.map { ($0.0, Self.diskBytes($0.1)) })
        }.value
        guard !Task.isCancelled else { return }
        if sizes != buildBytes { buildBytes = sizes }
    }

    public func finishFirstRun() {
        defaults.set(true, forKey: Self.firstRunDoneKey)
        firstRunNeeded = false
    }

    // MARK: Build and play

    /// Queues a build of the game's content into its build directory; on success the engine's
    /// version is stored as the record's `built_with`. A game whose `buildGate` asks first is
    /// built only with `confirmed` (the user accepted the warning or the report); an
    /// `unsupported_input` game never is.
    public func build(_ titleID: String, confirmed: Bool = false) throws {
        let game = try record(titleID)
        switch buildGate(game) {
        case .none: break
        case .refused: throw AppError.cannotBuild(titleID)
        case .confirmVersion, .analysisReport: if !confirmed { throw AppError.buildNotConfirmed(titleID) }
        }
        guard !isBusy(titleID) else { throw AppError.busy(titleID) }
        let content = try library.contentDir(titleID: titleID), buildDir = try library.buildDir(titleID: titleID)
        let log = try logURL(titleID, "build")
        let engine = engine, library = library
        queue.enqueue(kind: .build, title: game.title, titleID: titleID, log: log) { [weak self] progress in
            let result = try await engine.build(content: content, buildDir: buildDir, log: log, onEvent: progress)
            try await library.update { file in
                guard let i = file.games.firstIndex(where: { $0.titleID == titleID }) else { return }
                file.games[i].builtWith = result.builtWith
            }
            await self?.refresh()
        }
    }

    /// Starts the built game with its settings' environment, logging to `logs/<date>-run.log`. A
    /// game used in place with DLC is also given `PS4_ADDCONT_DIR`, its games/<ID>/addcont.
    public func play(_ titleID: String) throws {
        _ = try record(titleID)
        if uninstalling.contains(titleID) || hasActiveBuild(titleID) { throw AppError.busy(titleID) }
        guard let app = try library.appBundle(titleID: titleID) else { throw AppError.notBuilt(titleID) }
        var environment = GameSettings.load(titleID: titleID, settingsDir: paths.settingsDir).launchEnvironment
        if let dlc = try library.launchAddcontDir(titleID: titleID) { environment["PS4_ADDCONT_DIR"] = dlc.path }
        let log = try logURL(titleID, "run")
        try launcher.launch(titleID: titleID, app: app, environment: environment, log: log)
        runLogs[titleID] = log
        lastCrashLog[titleID] = nil
    }

    /// The crash banner's "dismiss": forgets the crashed session's log (it stays the newest run log).
    public func dismissCrash(_ titleID: String) {
        lastCrashLog[titleID] = nil
    }

    private func gameExited(_ titleID: String, seconds: Int64, status: ExitStatus) {
        let log = runLogs.removeValue(forKey: titleID)
        if status != .normal, let log { lastCrashLog[titleID] = log }
        let now = ISO8601DateFormatter().string(from: Date())
        let library = library
        Task {
            do {
                try await library.update { file in
                    guard let i = file.games.firstIndex(where: { $0.titleID == titleID }) else { return }
                    file.games[i].playSeconds += seconds
                    file.games[i].lastPlayed = now
                }
            } catch {
                lastError = Self.describe(error)
            }
            refresh()
        }
    }

    // MARK: Offers

    /// The rebuild banner: the build is older than the engine, or the content's version (after
    /// an update) is not the one the bundle was built from. The engine stamps the bundle's
    /// CFBundleShortVersionString with the same version rule as the record's `app_ver`; a
    /// content with no version gets the engine's "1.0" instead, so an empty `app_ver` never
    /// asks for a rebuild. The offer never replaces PLAY.
    public func rebuildOffer(_ g: GameRecord) -> String? {
        guard let built = builtApps[g.titleID] else { return nil }
        if !g.builtWith.isEmpty, let engineVersion, g.builtWith != engineVersion {
            return "Rebuild available: v\(g.builtWith) → v\(engineVersion)"
        }
        if !g.appVer.isEmpty, let version = built.version, version != g.appVer { return "Rebuild needed after the update" }
        return nil
    }

    public func primaryAction(_ g: GameRecord) -> PrimaryAction {
        if launcher.running[g.titleID] != nil { return .running }
        if uninstalling.contains(g.titleID) || hasActiveOperation(g.titleID) { return .busy }
        return builtApps[g.titleID] == nil ? .build : .play
    }

    /// What Build or Rebuild asks before the build starts (the spec's support statuses).
    public func buildGate(_ g: GameRecord) -> BuildGate {
        switch g.status {
        case "other_version": .confirmVersion
        case "experimental": .analysisReport
        case "unsupported_input": .refused
        default: .none
        }
    }

    /// The confirmation of an `other_version` build: the content's version and the tested ones.
    public nonisolated static func otherVersionWarning(_ g: GameRecord, tested: [String]) -> String {
        let name = g.title.isEmpty ? g.titleID : g.title
        let current = g.appVer.isEmpty ? "This version" : "Version \(GameVersion.display(g.appVer))"
        let list = tested.map(GameVersion.display).joined(separator: ", ")
        return "\(current) of \(name) has not been tested. "
            + (list.isEmpty ? "No version of it is listed as tested." : "Tested: \(list).")
            + " The build may fail, or the game may not run correctly."
    }

    /// True while the game runs, is being uninstalled or has an operation queued or running:
    /// Rebuild and Uninstall wait.
    public func isBusy(_ titleID: String) -> Bool {
        launcher.running[titleID] != nil || uninstalling.contains(titleID) || hasActiveOperation(titleID)
    }

    private func hasActiveOperation(_ titleID: String) -> Bool {
        queue.items.contains { $0.titleID == titleID && !$0.isFinished }
    }

    func hasActiveBuild(_ titleID: String) -> Bool {
        queue.items.contains { $0.titleID == titleID && $0.kind == .build && !$0.isFinished }
    }

    /// CFBundleShortVersionString of a bundle; nil when its Info.plist has none.
    static func bundleVersion(_ app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict["CFBundleShortVersionString"] as? String
    }

    // MARK: Uninstall and shortcut

    /// Removes the game from the library, and our links to it in the Applications directory, and
    /// returns the bytes freed. Without `keepSaves` its save directories go to the Trash as well;
    /// when that fails after the game is removed, `AppError.savesNotTrashed` carries the bytes freed.
    public func uninstall(_ titleID: String, keepSaves: Bool) async throws -> Int64 {
        guard !isBusy(titleID) else { throw AppError.busy(titleID) }
        uninstalling.insert(titleID)
        defer {
            uninstalling.remove(titleID)
            refresh()
        }
        let gameDir = try library.gameDir(titleID: titleID)
        let freed = try await library.uninstall(titleID: titleID)
        analyses[titleID] = nil
        storedAnalyses[titleID] = nil
        lastCrashLog[titleID] = nil
        latestLogs[titleID] = nil
        if selection == titleID { selection = nil }
        removeShortcuts(into: gameDir)
        if !keepSaves {
            do {
                try saves.trashSaves(titleID: titleID)
            } catch {
                throw AppError.savesNotTrashed(freed: freed, message: Self.describe(error))
            }
        }
        return freed
    }

    /// Links `<Applications>/<TITLE>.app` to the built bundle. A link of ours (into the library)
    /// at that path is replaced; anything else there is never touched.
    public func addToApplications(_ titleID: String) throws {
        let game = try record(titleID)
        guard let app = try library.appBundle(titleID: titleID) else { throw AppError.notBuilt(titleID) }
        let link = applicationsDir.appendingPathComponent(Self.shortcutName(game) + ".app", isDirectory: false)
        let fm = FileManager.default
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path) {
            guard isInside(resolve(target), library.root) else { throw AppError.shortcutExists(link) }
            try fm.removeItem(at: link)
        } else if (try? fm.attributesOfItem(atPath: link.path)) != nil {
            throw AppError.shortcutExists(link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: app)
    }

    /// Removes the symlinks in the Applications directory that point into `gameDir`. A link that
    /// cannot be removed stays; it points nowhere once the game is gone.
    private func removeShortcuts(into gameDir: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: applicationsDir.path) else { return }
        for name in names {
            let link = applicationsDir.appendingPathComponent(name, isDirectory: false)
            guard let target = try? fm.destinationOfSymbolicLink(atPath: link.path), isInside(resolve(target), gameDir)
            else { continue }
            try? fm.removeItem(at: link)
        }
    }

    /// The standardized path of a link target, relative ones taken from the Applications directory.
    private func resolve(_ target: String) -> String {
        URL(fileURLWithPath: target, relativeTo: applicationsDir).standardizedFileURL.path
    }

    private func isInside(_ path: String, _ dir: URL) -> Bool {
        let root = dir.standardizedFileURL.path
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The title as a file name ("/" and ":" replaced), the TITLE_ID when it is empty.
    static func shortcutName(_ game: GameRecord) -> String {
        let name = String(game.title.map { $0 == "/" || $0 == ":" ? "-" : $0 }).trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.hasPrefix(".") ? game.titleID : name
    }

    // MARK: Helpers

    func record(_ titleID: String) throws -> GameRecord {
        guard let game = games.first(where: { $0.titleID == titleID }) else { throw AppError.notInLibrary(titleID) }
        return game
    }

    /// games/<TITLE_ID>/logs/<yyyy-MM-dd_HH-mm-ss>-<kind>.log, from now on the game's newest of its kind.
    func logURL(_ titleID: String, _ kind: String) throws -> URL {
        let url = try library.logsDir(titleID: titleID).appendingPathComponent("\(Self.stamp())-\(kind).log")
        latestLogs[titleID, default: [:]][kind] = url
        return url
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func stamp() -> String { stampFormatter.string(from: Date()) }

    nonisolated static func describe(_ error: any Error) -> String {
        switch error {
        case let failure as EngineFailure: failure.message
        case LibraryError.newerVersion(let v): "library.json has schema version \(v), newer than this app reads"
        case LibraryError.badTitleID(let id): "\(id) is not a PS4 title ID"
        case let app as AppError: describeApp(app)
        case let save as SaveError: describeSave(save)
        case LaunchError.alreadyRunning(let id): "\(id) is already running"
        case LaunchError.noExecutable(let app): "\(app.lastPathComponent) has no executable; build the game again"
        default: error.localizedDescription
        }
    }
}
