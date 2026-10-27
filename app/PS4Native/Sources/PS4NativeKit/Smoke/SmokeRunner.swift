// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The outcome of a smoke run: each step that ran, in order. `smoke.json` holds it.
public struct SmokeReport: Codable, Sendable, Equatable {
    public struct Step: Codable, Sendable, Equatable {
        public let name: String
        public let passed: Bool
        public let seconds: Double
        /// What went wrong, or a short note of what was checked.
        public let detail: String
    }

    /// The steps that ran; the run stops at the first one that fails.
    public let steps: [Step]
    /// The game the run added, "" when the add itself failed.
    public let titleID: String
    /// True when every step of `SmokeRunner.stepNames` ran and passed.
    public let passed: Bool

    init(steps: [Step], titleID: String) {
        self.steps = steps
        self.titleID = titleID
        passed = steps.map(\.name) == SmokeRunner.stepNames && steps.allSatisfy(\.passed)
    }
}

/// Drives an `AppModel` through the app's main path — add a PKG, import and analyse it, build
/// it, play it and record the play time — as a user would from the views. The packaged app runs
/// it in `--smoke` mode on `FakeEngine` (`engine(...)`) and the `/bin/sleep 1` launcher
/// (`launcher()`), so the run needs no real engine and starts no game.
@MainActor
public struct SmokeRunner {
    public nonisolated static let stepNames = ["add", "confirm", "import_and_analysis", "build", "play", "exit", "play_time"]

    /// How long a step may wait for the model.
    public let stepTimeout: Duration

    public init(stepTimeout: Duration = .seconds(60)) {
        self.stepTimeout = stepTimeout
    }

    private struct StepFailure: Error {
        let detail: String
    }

    /// Adds `<fixturesSource>/game.pkg` and takes it through to a finished play session.
    /// `fixturesSource` is the directory the fixtures' PKGs were recorded from (`$SRC`).
    public func run(model: AppModel, fixturesSource: URL) async -> SmokeReport {
        var steps: [SmokeReport.Step] = []
        var titleID = ""
        var candidate: AddCandidate?

        func step(_ name: String, _ body: () async throws -> String) async -> Bool {
            let start = ContinuousClock.now
            let passed: Bool, detail: String
            do {
                detail = try await body()
                passed = true
            } catch let failure as StepFailure {
                (passed, detail) = (false, failure.detail)
            } catch {
                (passed, detail) = (false, AppModel.describe(error))
            }
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            steps.append(.init(name: name, passed: passed, seconds: seconds, detail: detail))
            return passed
        }

        let pkg = fixturesSource.appendingPathComponent("game.pkg")
        var report: SmokeReport { SmokeReport(steps: steps, titleID: titleID) }
        guard await step("add", {
            await model.add([pkg])
            guard let c = model.pendingCandidates.first(where: { $0.url == pkg }) else {
                throw StepFailure(detail: "no add candidate for \(pkg.path)")
            }
            guard c.canConfirm, let inspect = c.inspect else {
                throw StepFailure(detail: c.message ?? "the candidate cannot be imported")
            }
            candidate = c
            titleID = inspect.titleID
            return "\(inspect.title) (\(inspect.titleID)), \(inspect.kind) \(inspect.appVer)"
        }) else { return report }
        guard await step("confirm", {
            guard let candidate else { throw StepFailure(detail: "no candidate") }
            try model.confirm(candidate, mode: .copy)
            return "import queued"
        }) else { return report }
        guard await step("import_and_analysis", {
            try await wait("the import and analysis") {
                model.analyses[titleID] != nil || failure(in: model.queue, titleID: titleID) != nil
            }
            try await wait("the queue") { !model.queue.items.contains { !$0.isFinished } }
            if let failed = failure(in: model.queue, titleID: titleID) { throw StepFailure(detail: failed) }
            guard let analysis = model.analyses[titleID] else { throw StepFailure(detail: "no analysis") }
            guard model.games.contains(where: { $0.titleID == titleID }) else {
                throw StepFailure(detail: "\(titleID) is not in the library after the import")
            }
            return "status \(analysis.verdict.status), coverage \(analysis.coverage)"
        }) else { return report }
        guard await step("build", {
            // As the user would: an other_version or experimental game is built after its
            // confirmation, never without it.
            let gate = model.buildGate(try model.record(titleID))
            if gate != .none {
                do {
                    try model.build(titleID)
                    throw StepFailure(detail: "the \(gate) build started without its confirmation")
                } catch AppError.buildNotConfirmed(titleID) {}
            }
            try model.build(titleID, confirmed: gate != .none)
            try await wait("the build") {
                model.queue.items.contains { $0.kind == .build && $0.titleID == titleID && $0.isFinished }
            }
            if let failed = failure(in: model.queue, titleID: titleID) { throw StepFailure(detail: failed) }
            let game = try model.record(titleID)
            guard model.primaryAction(game) == .play else {
                throw StepFailure(detail: "the game page offers \(model.primaryAction(game)) instead of play")
            }
            return "built with \(game.builtWith)"
        }) else { return report }
        guard await step("play", {
            try model.play(titleID)
            guard let running = model.launcher.running[titleID] else { throw StepFailure(detail: "the game is not running") }
            return "pid \(running.pid)"
        }) else { return report }
        guard await step("exit", {
            try await wait("the game to exit") { model.launcher.running[titleID] == nil }
            if model.lastCrashLog[titleID] != nil { throw StepFailure(detail: "the session ended in a crash") }
            return "exited normally"
        }) else { return report }
        guard await step("play_time", {
            try await wait("the play time") { (try? model.record(titleID).lastPlayed.isEmpty) == false }
            let seconds = try model.record(titleID).playSeconds
            guard seconds >= 1 else { throw StepFailure(detail: "play_seconds is \(seconds), expected at least 1") }
            return "play_seconds \(seconds)"
        }) else { return report }
        return report
    }

    /// The message of a failed or cancelled queue item of the game, nil when none failed.
    private func failure(in queue: EngineOperationQueue, titleID: String) -> String? {
        for item in queue.items where item.titleID == titleID {
            switch item.state {
            case .failed(let failure): return "\(item.kind): \(failure.message)"
            case .cancelled: return "\(item.kind) was cancelled"
            case .queued, .running, .done: continue
            }
        }
        return nil
    }

    /// Polls the main actor until `condition` holds; fails after `stepTimeout`.
    private func wait(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + stepTimeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw StepFailure(detail: "timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: The smoke run's environment, engine and launcher

    /// The overrides a smoke run must set, so it writes into scratch directories only.
    public nonisolated static let scratchKeys = ["PS4NATIVE_LIBRARY", "PS4RECOMP_DATA_DIR"]

    /// Why `environment` is not fit for a smoke run, nil when it is. Each of `scratchKeys` must
    /// be set, and must not resolve to (or into) the default library or data dir of `home`,
    /// the user's real home directory by default (not `$HOME`, which the environment may set).
    public nonisolated static func scratchProblem(environment: [String: String],
                                                  home: URL = FileManager.default.homeDirectory(forUser: NSUserName())
                                                      ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> String? {
        let defaults = Paths(environment: ["HOME": home.path])
        let protected = [defaults.libraryRoot, defaults.dataDir].map(resolved)
        for key in scratchKeys {
            guard let value = environment[key], !value.isEmpty else {
                return "\(key) must point at a scratch directory"
            }
            let path = resolved(URL(fileURLWithPath: value, isDirectory: true))
            if let real = protected.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return "\(key)=\(value) is the real \(real); point it at a scratch directory"
            }
        }
        return nil
    }

    /// The standardized path of `url` with the symlinks of its longest existing prefix resolved,
    /// so a path that does not exist yet still compares equal to the place it will be created.
    private nonisolated static func resolved(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var out = existing.resolvingSymlinksInPath()
        for part in rest { out.appendPathComponent(part) }
        let path = out.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }


    /// A `FakeEngine` replaying `fixtures`, with `$SRC` as `source`, `$TMP` as `temp` and `$LIB`
    /// as the library root, that also does what the real engine leaves on disk: an import writes
    /// its game into library.json, and a build leaves the bundle it reports, stamped with the
    /// record's app_ver. The bundle's executable is a script that only exits; the smoke launcher
    /// never runs it.
    public static func engine(fixtures: URL, source: URL, temp: URL, library: LibraryStore) -> FakeEngine {
        let engine = FakeEngine(fixtures: fixtures, substitutions: [
            "$LIB": library.root.path, "$SRC": source.path, "$TMP": temp.path,
        ])
        engine.afterRun = { arguments, doneLine in
            try await sideEffects(of: arguments, doneLine: doneLine, library: library)
        }
        return engine
    }

    /// A launcher that runs `/bin/sleep 1` in place of the game.
    public static func launcher() -> GameLauncher {
        GameLauncher(spawn: ProcessSpawner(standIn: URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"]))
    }

    private struct Done<R: Decodable>: Decodable {
        let result: R
    }

    private nonisolated static func sideEffects(of arguments: [String], doneLine: Data, library: LibraryStore) async throws {
        switch arguments.first {
        case "import":
            let result = try JSONDecoder().decode(Done<ImportResult>.self, from: doneLine).result
            guard let imported = try result.gameRecord else { return }
            try await library.update { file in
                var record = imported
                // The engine keeps the app's fields of a game already in the library.
                if let old = file.games.first(where: { $0.titleID == record.titleID }) {
                    record.builtWith = old.builtWith
                    record.lastPlayed = old.lastPlayed
                    record.playSeconds = old.playSeconds
                }
                file.games.removeAll { $0.titleID == record.titleID }
                file.games.append(record)
            }
        case "build":
            let result = try JSONDecoder().decode(Done<BuildResult>.self, from: doneLine).result
            guard let app = result.app else { return }
            let version = try library.snapshot().games.first { $0.titleID == result.titleID }?.appVer ?? ""
            try writeBundle(at: URL(fileURLWithPath: app, isDirectory: true), version: version)
        default:
            break
        }
    }

    private nonisolated static func writeBundle(at app: URL, version: String) throws {
        let fm = FileManager.default
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        let exe = macOS.appendingPathComponent("eboot")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleExecutable": "eboot", "CFBundleShortVersionString": version], format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
}
