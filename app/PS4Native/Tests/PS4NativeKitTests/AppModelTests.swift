// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Synchronization
import Testing
@testable import PS4NativeKit

private let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
private let titleID = "CUSA00557"

/// A game "process" that never runs anything: it reports `status` after `after`.
private final class FakeSpawner: GameSpawner {
    struct FakeGame: SpawnedGame {
        let pid: Int32 = 4242
        func send(_ signal: Int32) {}
    }

    let after: Duration
    let status: PS4NativeKit.ExitStatus
    private let environments = Mutex<[[String: String]]>([])

    init(after: Duration = .milliseconds(10), status: PS4NativeKit.ExitStatus = .normal) {
        self.after = after
        self.status = status
    }

    var lastEnvironment: [String: String]? { environments.withLock { $0.last } }

    func spawn(_ executable: URL, environment: [String: String], output: FileHandle,
               onExit: @escaping @Sendable (PS4NativeKit.ExitStatus) -> Void) throws -> any SpawnedGame {
        environments.withLock { $0.append(environment) }
        let after = after, status = status
        Task {
            try? await Task.sleep(for: after)
            onExit(status)
        }
        return FakeGame()
    }
}

/// Moves trashed items into a directory of the sandbox.
private final class Trashed: Sendable {
    let dir: URL
    init(_ dir: URL) { self.dir = dir }
    func move(_ u: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: u, to: dir.appendingPathComponent(UUID().uuidString + "-" + u.lastPathComponent))
    }
}

/// Writes a bundle whose `Contents/MacOS/x` is an executable script (never run by these tests),
/// with `version` as its CFBundleShortVersionString, as the engine stamps the content's APP_VER.
private func makeApp(at app: URL, version: String) throws {
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let exe = macOS.appendingPathComponent("x")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: exe)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
    let plist = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleExecutable": "x", "CFBundleShortVersionString": version], format: .xml, options: 0)
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
}

/// A model on a temp library, data dir, Applications dir and defaults suite.
@MainActor private final class Harness {
    let root: URL
    let paths: Paths
    let engine: FakeEngine
    let spawner: FakeSpawner
    let library: LibraryStore
    let suiteName = "ps4native-tests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let model: AppModel

    var src: URL { root.appendingPathComponent("src") }
    var trash: URL { root.appendingPathComponent("trash") }
    var applications: URL { root.appendingPathComponent("Applications") }

    struct TrashFailed: Error {}

    init(spawner: FakeSpawner = FakeSpawner(), freeBytes: Int64 = 500_000_000_000, trashFails: Bool = false,
         sharing other: Harness? = nil, freeSpace: (@Sendable (URL) -> Int64)? = nil) throws {
        let fm = FileManager.default
        root = other?.root ?? fm.temporaryDirectory.appendingPathComponent("ps4n-model-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        paths = Paths(environment: [
            "HOME": root.path,
            "PS4NATIVE_LIBRARY": root.appendingPathComponent("library").path,
            "PS4RECOMP_DATA_DIR": root.appendingPathComponent("data").path,
            "PS4NATIVE_ENGINE": root.appendingPathComponent("engine").path,
        ])
        let library = LibraryStore(root: paths.libraryRoot)
        self.library = library
        // FakeEngine with the engine's side effects on disk (an import writes library.json, a
        // build leaves its bundle), the same engine the smoke run uses.
        engine = SmokeRunner.engine(fixtures: fixtures, source: root.appendingPathComponent("src"), temp: root,
                                    library: library)
        self.spawner = spawner
        let trashed = Trashed(root.appendingPathComponent("trash"))
        let saves = SaveStore(savesDir: paths.savesDir, backupsDir: paths.dataDir.appendingPathComponent("backups"),
                              trash: { if trashFails { throw TrashFailed() }; try trashed.move($0) })
        defaults = try #require(UserDefaults(suiteName: suiteName))
        model = AppModel(paths: paths, engine: engine, launcher: GameLauncher(spawn: spawner), queue: EngineOperationQueue(),
                         library: library, saves: saves, defaults: defaults, applicationsDir: root.appendingPathComponent("Applications"),
                         freeSpace: freeSpace ?? { _ in freeBytes },
                         toolchainCheck: { _ in ToolchainReport(clangVersion: 21, sdkVersion: 27, freeBytes: freeBytes, problems: []) })
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// A library record, as an import would leave it, with a bundle in the build dir when
    /// `built`, built from `bundleVersion` (the record's app_ver by default).
    func seed(_ record: GameRecord, built: Bool, bundleVersion: String? = nil) async throws {
        try await library.update { $0.games.append(record) }
        if built {
            try makeApp(at: try library.buildDir(titleID: record.titleID).appendingPathComponent("eboot.app"),
                        version: bundleVersion ?? record.appVer)
        }
        model.refresh()
    }

    func record() throws -> GameRecord {
        try #require(model.games.first { $0.titleID == titleID })
    }

    func lines(_ fixture: String) throws -> [String] {
        try String(contentsOf: fixtures.appending(path: "\(fixture).jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }
}

@MainActor @Suite struct AppModelTests {
    /// Waits until `condition` holds, polling the main actor.
    func wait(_ what: Comment, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out waiting: \(what)"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finished(_ queue: EngineOperationQueue) -> Bool {
        queue.items.allSatisfy { $0.state != .queued && $0.state != .running }
    }

    // MARK: Add flow

    @Test func addThenConfirmImportsAndAnalyses() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pkg = h.src.appendingPathComponent("game.pkg")
        await h.model.add([pkg])
        let candidate = try #require(h.model.pendingCandidates.first)
        #expect(h.model.pendingCandidates.count == 1)
        #expect(candidate.url == pkg && candidate.error == nil && candidate.canConfirm && candidate.status == nil)
        #expect(candidate.inspect?.titleID == titleID && candidate.mode == .copy)
        // unpacked_size of the fixture plus the 1 GiB margin.
        #expect(candidate.neededBytes == 1_749_791 + 1 << 30)

        try h.model.confirm(candidate, mode: .copy)
        #expect(h.model.pendingCandidates.isEmpty)
        try await wait("import and analysis") {
            h.model.queue.items.count == 2 && finished(h.model.queue) && h.model.analyses[titleID] != nil
        }
        #expect(h.model.queue.items.map(\.kind) == [.importGame, .analyze])
        #expect(h.model.queue.items.allSatisfy { $0.state == .done })

        struct Done: Decodable { let result: GameAnalysis }
        let recorded = try JSONDecoder().decode(Done.self, from: Data(try #require(h.lines("analyze-game").last).utf8)).result
        try await wait("status") { (try? h.record().status) == recorded.verdict.status }
        #expect(try h.record().status == recorded.verdict.status)
        #expect(try #require(h.library.snapshot().games.first).status == recorded.verdict.status)
        #expect(h.model.analyses[titleID] == recorded)
        let importCall = try #require(h.engine.calls.first { $0.first == "import" })
        #expect(importCall == ["import", pkg.path, "--library", h.paths.libraryRoot.path, "--mode", "copy", "--json"])
        let content = try h.library.contentDir(titleID: titleID)
        #expect(h.engine.calls.last == ["analyze-game", content.path, "--json"])
    }

    @Test func pendingPatchIsNotAnalysed() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.engine.setScript("import", lines: [
            #"{"event":"warning","op":"import","message":"base game not in the library; patch kept as pending"}"#,
            #"{"event":"done","op":"import","result":{"title_id":"CUSA00557","kind":"patch","pending":true}}"#,
        ], exitOK: true)
        await h.model.add([h.src.appendingPathComponent("patch.pkg")])
        try h.model.confirm(try #require(h.model.pendingCandidates.first), mode: .copy)
        try await wait("import") { finished(h.model.queue) }
        #expect(h.model.queue.items.map(\.kind) == [.importGame])
        #expect(h.model.queue.items.first?.state == .done)
    }

    @Test func retailCandidateCannotBeConfirmed() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.engine.setScript("inspect", lines: try h.lines("inspect-retail"), exitOK: true)
        await h.model.add([h.src.appendingPathComponent("retail.pkg")])
        let candidate = try #require(h.model.pendingCandidates.first)
        #expect(candidate.inspect?.signing == "retail")
        #expect(!candidate.canConfirm && candidate.status == "unsupported_input")
        #expect(candidate.message == AddCandidate.retailMessage)
        #expect(throws: AppError.cannotImport(AddCandidate.retailMessage)) { try h.model.confirm(candidate, mode: .copy) }
        #expect(h.model.queue.items.isEmpty)
        #expect(h.model.pendingCandidates.count == 1)
    }

    @Test func addOfThreeURLsGivesThreeCandidatesInOrder() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let urls = ["a.pkg", "b.pkg", "c.pkg"].map { h.src.appendingPathComponent($0) }
        await h.model.add(urls)
        #expect(h.model.pendingCandidates.map(\.url) == urls)
        #expect(h.engine.calls.filter { $0.first == "inspect" }.count == 3)
    }

    @Test func badPKGAndFolderWithoutEbootAreUnsupported() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.engine.setScript("inspect", lines: [#"{"event":"error","op":"inspect","code":"bad_pkg","message":"not a PKG"}"#], exitOK: false)
        await h.model.add([h.src.appendingPathComponent("broken.pkg")])
        let broken = try #require(h.model.pendingCandidates.last)
        #expect(broken.inspect == nil && broken.error == EngineFailure(code: "bad_pkg", message: "not a PKG"))
        #expect(broken.status == "unsupported_input" && !broken.canConfirm && broken.message == "not a PKG")

        h.engine.setScript("inspect", lines: [#"{"event":"error","op":"inspect","code":"bad_input","message":"no such file"}"#], exitOK: false)
        await h.model.add([h.src.appendingPathComponent("gone.pkg")])
        let gone = try #require(h.model.pendingCandidates.last)
        #expect(gone.status == nil && !gone.canConfirm && gone.message == "no such file")

        h.engine.setScript("inspect", lines: try h.lines("inspect-folder"), exitOK: true)
        let folder = h.src.appendingPathComponent("CUSA00557")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sce_sys"), withIntermediateDirectories: true)
        await h.model.add([folder])
        let noEboot = try #require(h.model.pendingCandidates.last)
        #expect(noEboot.status == "unsupported_input" && !noEboot.canConfirm)
        #expect(noEboot.message == AddCandidate.noEbootMessage)
    }

    @Test func importExistingFolderPreselectsReferenceMode() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.engine.setScript("inspect", lines: try h.lines("inspect-folder"), exitOK: true)
        let folder = h.src.appendingPathComponent("CUSA00557")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sce_sys"), withIntermediateDirectories: true)
        try Data([0]).write(to: folder.appendingPathComponent("eboot.bin"))
        await h.model.importExistingFolder(folder)
        let candidate = try #require(h.model.pendingCandidates.first)
        #expect(candidate.canConfirm && candidate.mode == .reference && candidate.status == nil)
        #expect(candidate.neededBytes == 1 << 30)
        h.model.setMode(.copy, for: candidate.id)
        let copied = try #require(h.model.pendingCandidates.first)
        #expect(copied.mode == .copy && copied.neededBytes == 1_749_716 + 1 << 30)

        try h.model.confirm(try #require(h.model.pendingCandidates.first), mode: .reference)
        try await wait("import") { h.model.queue.items.count == 2 && finished(h.model.queue) }
        #expect(h.engine.calls.contains { $0.first == "import" && $0.contains("reference") })
    }

    @Test func referenceModeIsForFoldersOnly() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.add([h.src.appendingPathComponent("game.pkg")])
        let candidate = try #require(h.model.pendingCandidates.first)
        #expect(throws: AppError.cannotImport("reference mode applies to folders only")) {
            try h.model.confirm(candidate, mode: .reference)
        }
        #expect(h.model.queue.items.isEmpty)
    }

    @Test func spaceShortComparesWithTheLibraryVolume() async throws {
        let h = try Harness(freeBytes: 1 << 30)
        defer { h.cleanUp() }
        await h.model.add([h.src.appendingPathComponent("game.pkg")])
        #expect(h.model.spaceShort(try #require(h.model.pendingCandidates.first)))
        let roomy = try Harness(freeBytes: 2 << 30)
        defer { roomy.cleanUp() }
        await roomy.model.add([roomy.src.appendingPathComponent("game.pkg")])
        #expect(!roomy.model.spaceShort(try #require(roomy.model.pendingCandidates.first)))
    }

    @Test func addSkipsURLsAlreadyPending() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        let pkg = h.src.appendingPathComponent("game.pkg")
        await h.model.add([pkg, pkg])
        await h.model.add([pkg])
        #expect(h.model.pendingCandidates.map(\.url) == [pkg])
        #expect(h.engine.calls.filter { $0.first == "inspect" }.count == 1)
    }

    @Test func updateOfARunningGameIsBusy() async throws {
        let h = try Harness(spawner: FakeSpawner(after: .seconds(30)))
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, builtWith: "0.3.0"), built: true)
        try h.model.play(titleID)
        await h.model.add([h.src.appendingPathComponent("patch.pkg")])
        let candidate = try #require(h.model.pendingCandidates.first)
        #expect(throws: AppError.busy(titleID)) { try h.model.confirm(candidate, mode: .copy) }
        #expect(h.model.queue.items.isEmpty && h.model.pendingCandidates.count == 1)
    }

    @Test func updateDuringABuildIsBusy() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, builtWith: "0.3.0"), built: false)
        // A build that stays running until it is cancelled.
        h.model.queue.enqueue(kind: .build, title: "x", titleID: titleID, log: h.root.appendingPathComponent("x.log")) { _ in
            try await Task.sleep(for: .seconds(30))
        }
        await h.model.add([h.src.appendingPathComponent("dlc.pkg")])
        #expect(throws: AppError.busy(titleID)) { try h.model.confirm(try #require(h.model.pendingCandidates.first), mode: .copy) }
        h.model.queue.items.forEach { h.model.queue.cancel($0.id) }
        try await wait("cancel") { finished(h.model.queue) }
    }

    @Test func analysisIsKeptForTheNextLaunch() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game"), built: false)
        try h.model.analyze(titleID)
        try await wait("analysis") { finished(h.model.queue) && h.model.analyses[titleID] != nil }
        let file = try h.library.gameDir(titleID: titleID).appendingPathComponent("analysis.json")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let next = try Harness(sharing: h)
        defer { next.cleanUp() }
        next.model.refresh()
        #expect(next.model.analyses.isEmpty)
        #expect(await next.model.loadAnalysis(titleID) == h.model.analyses[titleID])
        #expect(next.model.analysis(for: titleID) == h.model.analyses[titleID])
        #expect(next.model.analysis(for: "CUSA00001") == nil)
        #expect(await next.model.loadAnalysis("CUSA00001") == nil)
        _ = try await next.model.uninstall(titleID, keepSaves: true)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(next.model.analysis(for: titleID) == nil)
    }

    // MARK: Build and play

    @Test func buildRecordsBuiltWithAndOffersPlay() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.start()
        #expect(h.model.engineVersion == "0.3.0")
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game", status: "other_version"), built: false)
        #expect(h.model.primaryAction(try h.record()) == .build)
        #expect(h.model.buildGate(try h.record()) == .confirmVersion)
        #expect(throws: AppError.buildNotConfirmed(titleID)) { try h.model.build(titleID) }
        #expect(h.model.queue.items.isEmpty)

        try h.model.build(titleID, confirmed: true)
        #expect(h.model.primaryAction(try h.record()) == .busy)
        #expect(throws: AppError.busy(titleID)) { try h.model.build(titleID, confirmed: true) }
        let item = try #require(h.model.queue.items.first)
        let logs = try h.library.logsDir(titleID: titleID)
        #expect(item.kind == .build && item.log.deletingLastPathComponent() == logs)
        #expect(item.log.lastPathComponent.wholeMatch(of: /\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d-build\.log/) != nil)
        try await wait("build") { finished(h.model.queue) && (try? h.record().builtWith) == "0.3.0" }
        #expect(h.model.queue.items.first?.state == .done)
        #expect(try h.record().builtWith == "0.3.0")
        #expect(h.model.primaryAction(try h.record()) == .play)
        #expect(h.model.rebuildOffer(try h.record()) == nil)
    }

    @Test func playAddsPlayTimeAndLastPlayed() async throws {
        let spawner = FakeSpawner(after: .milliseconds(1100))
        let h = try Harness(spawner: spawner)
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game", status: "playable", builtWith: "0.3.0", playSeconds: 5),
                         built: true)
        try GameSettings(metal: 4).save(titleID: titleID, settingsDir: h.paths.settingsDir)
        try h.model.play(titleID)
        #expect(h.model.primaryAction(try h.record()) == .running)
        #expect(h.model.isBusy(titleID))
        #expect(throws: LaunchError.alreadyRunning(titleID)) { try h.model.play(titleID) }
        #expect(spawner.lastEnvironment?["PS4_NO_DIALOGS"] == "1" && spawner.lastEnvironment?["PS4_GNM_METAL"] == "4")

        try await wait("exit") { (try? h.record().playSeconds) ?? 0 >= 6 }
        let record = try h.record()
        #expect(record.playSeconds >= 6)
        #expect(ISO8601DateFormatter().date(from: record.lastPlayed) != nil)
        #expect(h.model.lastCrashLog[titleID] == nil)
        #expect(!h.model.isBusy(titleID))
    }

    @Test func crashExitKeepsTheRunLog() async throws {
        let h = try Harness(spawner: FakeSpawner(status: .signal(SIGSEGV)))
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game", builtWith: "0.3.0"), built: true)
        try h.model.play(titleID)
        try await wait("crash") { h.model.lastCrashLog[titleID] != nil }
        let log = try #require(h.model.lastCrashLog[titleID])
        let logs = try h.library.logsDir(titleID: titleID)
        #expect(log.deletingLastPathComponent() == logs)
        #expect(log.lastPathComponent.hasSuffix("-run.log"))
        #expect(h.model.latestLog(titleID, kind: "run") == log)
        h.model.dismissCrash(titleID)
        #expect(h.model.lastCrashLog[titleID] == nil)
        #expect(h.model.latestLog(titleID, kind: "run") == log)
    }

    @Test func playWithoutABuildIsRefused() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID), built: false)
        #expect(throws: AppError.notBuilt(titleID)) { try h.model.play(titleID) }
    }

    // MARK: Offers

    @Test func rebuildOfferForANewerEngine() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.start()
        try await h.seed(GameRecord(titleID: titleID, status: "playable", builtWith: "0.2.0"), built: true)
        #expect(h.model.rebuildOffer(try h.record()) == "Rebuild available: v0.2.0 → v0.3.0")
        // The offer is a banner: the game it was built into still plays.
        #expect(h.model.primaryAction(try h.record()) == .play)
    }

    @Test func contentNewerThanTheBuildNeedsARebuild() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.start()
        try await h.seed(GameRecord(titleID: titleID, appVer: "01.05", status: "playable", builtWith: "0.3.0"),
                         built: true, bundleVersion: "01.00")
        #expect(h.model.rebuildOffer(try h.record()) == "Rebuild needed after the update")
        #expect(h.model.primaryAction(try h.record()) == .play)
        // The status plays no part: an analysed game built from its current content needs nothing.
        #expect(h.model.rebuildOffer(GameRecord(titleID: titleID, appVer: "01.00", status: "", builtWith: "0.3.0")) == nil)
        // Without a build there is nothing to rebuild.
        #expect(h.model.rebuildOffer(GameRecord(titleID: "CUSA00001", appVer: "01.05")) == nil)
    }

    /// A content with neither APP_VER nor VERSION: the record's app_ver is "" and the engine
    /// stamps the bundle "1.0". That is no update, so there is no offer, and PLAY stays.
    @Test func emptyAppVerNeverAsksForARebuild() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.start()
        try await h.seed(GameRecord(titleID: titleID, appVer: "", status: "playable", builtWith: "0.3.0"),
                         built: true, bundleVersion: "1.0")
        #expect(h.model.rebuildOffer(try h.record()) == nil)
        #expect(h.model.primaryAction(try h.record()) == .play)
    }

    // MARK: Status gating

    @Test func buildGateFollowsTheSupportStatus() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        for (status, gate) in [("playable", BuildGate.none), ("in_progress", .none), ("", .none),
                               ("other_version", .confirmVersion), ("experimental", .analysisReport),
                               ("unsupported_input", .refused)] {
            #expect(h.model.buildGate(GameRecord(titleID: titleID, status: status)) == gate, "\(status)")
        }
    }

    @Test func gatedBuildsWaitForTheConfirmation() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.start()
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game", status: "experimental"), built: false)
        #expect(throws: AppError.buildNotConfirmed(titleID)) { try h.model.build(titleID) }
        #expect(h.model.queue.items.isEmpty)
        // "Build anyway" from the analysis report.
        try h.model.build(titleID, confirmed: true)
        #expect(h.model.queue.items.map(\.kind) == [.build])
        try await wait("build") { finished(h.model.queue) }
        #expect(h.model.queue.items.first?.state == .done)
    }

    @Test func unsupportedInputIsNeverBuilt() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, status: "unsupported_input"), built: false)
        #expect(throws: AppError.cannotBuild(titleID)) { try h.model.build(titleID) }
        #expect(throws: AppError.cannotBuild(titleID)) { try h.model.build(titleID, confirmed: true) }
        #expect(h.model.queue.items.isEmpty)
    }

    @Test func otherVersionWarningNamesTheTestedVersions() {
        let game = GameRecord(titleID: titleID, title: "Test Game", appVer: "01.00")
        let text = AppModel.otherVersionWarning(game, tested: ["01.32", "01.33"])
        #expect(text.contains("Version v1.00 of Test Game") && text.contains("Tested: v1.32, v1.33."))
        let none = AppModel.otherVersionWarning(GameRecord(titleID: titleID), tested: [])
        #expect(none.contains("This version of \(titleID)") && none.contains("No version of it is listed as tested."))
    }

    /// The real flow: a patch import clears the status and the analysis that follows fills it
    /// again, but the offer stays until the game is rebuilt.
    @Test func patchOnABuiltGameOffersARebuildUntilRebuilt() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.start()
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game", appVer: "01.00", version: "01.00",
                                    status: "other_version", builtWith: "0.3.0"), built: true)
        #expect(h.model.primaryAction(try h.record()) == .play)

        let patchInspect = try #require(h.lines("inspect").first)
            .replacingOccurrences(of: #""kind":"game""#, with: #""kind":"patch""#)
            .replacingOccurrences(of: #""app_ver":"01.00""#, with: #""app_ver":"01.05""#)
            .replacingOccurrences(of: #""category":"gd""#, with: #""category":"gp""#)
        h.engine.setScript("inspect", lines: [patchInspect], exitOK: true)
        h.engine.setScript("import", lines: try h.lines("import-patch"), exitOK: true)
        await h.model.add([h.src.appendingPathComponent("patch.pkg")])
        let candidate = try #require(h.model.pendingCandidates.first)
        #expect(candidate.inspect?.kind == "patch" && candidate.canConfirm)
        try h.model.confirm(candidate, mode: .copy)
        try await wait("import and analysis") {
            h.model.queue.items.count == 2 && finished(h.model.queue) && h.model.analyses[titleID] != nil
        }
        #expect(h.model.queue.items.map(\.kind) == [.importGame, .analyze])
        #expect(h.model.queue.items.allSatisfy { $0.state == .done })
        let patched = try h.record()
        #expect(patched.appVer == "01.05" && patched.patches == ["01.05"] && patched.status == "other_version")
        #expect(h.model.rebuildOffer(patched) == "Rebuild needed after the update")
        #expect(h.model.primaryAction(patched) == .play)

        try h.model.build(titleID, confirmed: true)
        try await wait("rebuild") { finished(h.model.queue) && h.model.queue.items.count == 3 }
        #expect(h.model.rebuildOffer(try h.record()) == nil)
        #expect(h.model.primaryAction(try h.record()) == .play)
    }

    // MARK: Uninstall

    @Test func uninstallWhileRunningIsBusy() async throws {
        let h = try Harness(spawner: FakeSpawner(after: .seconds(30)))
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, builtWith: "0.3.0"), built: true)
        try h.model.play(titleID)
        await #expect(throws: AppError.busy(titleID)) { _ = try await h.model.uninstall(titleID, keepSaves: true) }
        #expect(try h.record().titleID == titleID)
    }

    @Test func uninstallWithoutKeepSavesTrashesTheSaves() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, builtWith: "0.3.0"), built: true)
        let saveDir = h.paths.savesDir.appendingPathComponent("Test Game [\(titleID)]/user_10000000/SAVEDATA00")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        let freed = try await h.model.uninstall(titleID, keepSaves: false)
        #expect(freed > 0)
        #expect(h.model.games.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: try h.library.gameDir(titleID: titleID).path))
        #expect(!FileManager.default.fileExists(atPath: h.paths.savesDir.appendingPathComponent("Test Game [\(titleID)]").path))
        let trashed = try FileManager.default.contentsOfDirectory(atPath: h.trash.path)
        #expect(trashed.count == 1 && trashed[0].hasSuffix("Test Game [\(titleID)]"))
    }

    @Test func uninstallKeepingSavesLeavesThem() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID), built: false)
        let saveDir = h.paths.savesDir.appendingPathComponent("Test Game [\(titleID)]")
        try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        _ = try await h.model.uninstall(titleID, keepSaves: true)
        #expect(h.model.games.isEmpty)
        #expect(FileManager.default.fileExists(atPath: saveDir.path))
        #expect(!FileManager.default.fileExists(atPath: h.trash.path))
    }

    @Test func uninstallInProgressIsBusy() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, builtWith: "0.3.0"), built: true)
        // Holding the library lock keeps the uninstall waiting inside its await.
        let lock = try await FileLock.acquire(h.library.lockURL)
        let removal = Task { try await h.model.uninstall(titleID, keepSaves: true) }
        try await wait("uninstall started") { h.model.uninstalling.contains(titleID) }
        #expect(h.model.isBusy(titleID))
        #expect(h.model.primaryAction(try h.record()) == .busy)
        #expect(throws: AppError.busy(titleID)) { try h.model.play(titleID) }
        #expect(throws: AppError.busy(titleID)) { try h.model.build(titleID) }
        await #expect(throws: AppError.busy(titleID)) { _ = try await h.model.uninstall(titleID, keepSaves: true) }
        lock.release()
        #expect(try await removal.value > 0)
        #expect(h.model.uninstalling.isEmpty && !h.model.isBusy(titleID))
        #expect(h.model.games.isEmpty)
    }

    @Test func uninstallRemovesOurApplicationsLinkOnly() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game"), built: true)
        try h.model.addToApplications(titleID)
        let ours = h.applications.appendingPathComponent("Test Game.app")
        let foreign = h.applications.appendingPathComponent("Chess.app")
        try FileManager.default.createSymbolicLink(atPath: foreign.path, withDestinationPath: "/System/Applications/Chess.app")
        _ = try await h.model.uninstall(titleID, keepSaves: true)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: ours.path)) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: foreign.path) == "/System/Applications/Chess.app")
    }

    @Test func failedSaveTrashStillReportsTheFreedBytes() async throws {
        let h = try Harness(trashFails: true)
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID), built: true)
        try FileManager.default.createDirectory(at: h.paths.savesDir.appendingPathComponent("Test Game [\(titleID)]"),
                                                withIntermediateDirectories: true)
        do {
            _ = try await h.model.uninstall(titleID, keepSaves: false)
            Issue.record("the save trash failure was not reported")
        } catch AppError.savesNotTrashed(let freed, _) {
            #expect(freed > 0)
        }
        // The game is gone and the list refreshed all the same.
        #expect(h.model.games.isEmpty && h.model.uninstalling.isEmpty)
    }

    // MARK: Shortcut

    @Test func addToApplicationsLinksTheBuiltApp() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, title: "Test: Game"), built: true)
        let app = try #require(try h.library.appBundle(titleID: titleID))
        let link = h.applications.appendingPathComponent("Test- Game.app")
        try h.model.addToApplications(titleID)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == app.path)
        // A link of ours is replaced.
        try h.model.addToApplications(titleID)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == app.path)
    }

    @Test func addToApplicationsNeverReplacesSomethingElse() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game"), built: true)
        let link = h.applications.appendingPathComponent("Test Game.app")
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        #expect(throws: AppError.shortcutExists(link)) { try h.model.addToApplications(titleID) }
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: link.path, isDirectory: &isDir) && isDir.boolValue)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System/Applications/Chess.app")
        #expect(throws: AppError.shortcutExists(link)) { try h.model.addToApplications(titleID) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "/System/Applications/Chess.app")
    }

    // MARK: First run

    @Test func firstRunUntilDone() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        await h.model.start()
        #expect(h.model.firstRunNeeded)
        #expect(h.model.toolchain?.problems == [])
        h.model.finishFirstRun()
        #expect(!h.model.firstRunNeeded)
        #expect(h.defaults.bool(forKey: AppModel.firstRunDoneKey))
        #expect(AppModel.firstRunDoneKey == "ps4native.firstRunDone")
        await h.model.start()
        #expect(!h.model.firstRunNeeded)
    }

    @Test func noFirstRunWithAGameInTheLibrary() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID), built: false)
        await h.model.start()
        #expect(!h.model.firstRunNeeded)
        #expect(h.model.games.map(\.titleID) == [titleID])
    }

    // MARK: Data for the views

    @Test func buildSizeIsMeasuredForBuiltGamesOnly() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game"), built: true)
        try await h.seed(GameRecord(titleID: "CUSA00341", title: "Other"), built: false)
        #expect(h.model.isBuilt(titleID) && !h.model.isBuilt("CUSA00341"))
        await h.model.measureBuilds()
        let app = try h.library.buildDir(titleID: titleID).appendingPathComponent("eboot.app/Contents")
        let expected = try [app.appendingPathComponent("MacOS/x"), app.appendingPathComponent("Info.plist")]
            .reduce(Int64(0)) { $0 + Int64(try Data(contentsOf: $1).count) }
        #expect(h.model.buildBytes[titleID] == expected)
        #expect(h.model.buildBytes["CUSA00341"] == nil)
    }

    @Test func measuredGameDirIsWhatUninstallFrees() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID, title: "Test Game"), built: true)
        // A referenced folder: content/ is a symlink, and its files are not the library's.
        let folder = h.src.appendingPathComponent("dump")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 5000).write(to: folder.appendingPathComponent("eboot.bin"))
        try FileManager.default.createSymbolicLink(at: try h.library.contentDir(titleID: titleID), withDestinationURL: folder)
        let logs = try h.library.logsDir(titleID: titleID)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: logs.appendingPathComponent("old-run.log"))

        let measured = await h.model.measureGameDir(titleID)
        #expect(measured > 1000 && measured < 5000)
        #expect(try await h.model.uninstall(titleID, keepSaves: true) == measured)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("eboot.bin").path))
        #expect(await h.model.measureGameDir(titleID) == 0)
    }

    @Test func latestLogIsTheNewestOfItsKind() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        try await h.seed(GameRecord(titleID: titleID), built: false)
        #expect(h.model.latestLog(titleID, kind: "build") == nil)
        let logs = try h.library.logsDir(titleID: titleID)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for name in ["2026-10-01_10-00-00-build.log", "2026-10-03_09-00-00-build.log", "2026-10-04_09-00-00-run.log",
                     "2026-10-02_10-00-00-build.log"] {
            try Data().write(to: logs.appendingPathComponent(name))
        }
        #expect(h.model.latestLog(titleID, kind: "build") == nil)
        await h.model.scanLogs()
        #expect(h.model.latestLog(titleID, kind: "build")?.lastPathComponent == "2026-10-03_09-00-00-build.log")
        #expect(h.model.latestLog(titleID, kind: "run")?.lastPathComponent == "2026-10-04_09-00-00-run.log")
        #expect(h.model.latestLog("bad", kind: "build") == nil)

        // A build's log is the newest as soon as it is queued, before its file exists.
        h.model.queue.enqueue(kind: .build, title: "x", titleID: "CUSA00341", log: h.root.appendingPathComponent("x.log")) { _ in
            try await Task.sleep(for: .seconds(30))
        }
        try h.model.build(titleID)
        let item = try #require(h.model.queue.items.last)
        #expect(h.model.latestLog(titleID, kind: "build") == item.log)
        await h.model.scanLogs()
        #expect(h.model.latestLog(titleID, kind: "build") == item.log)
        h.model.queue.items.forEach { h.model.queue.cancel($0.id) }
        try await wait("cancel") { finished(h.model.queue) }
    }

    @Test func settingsAreSavedToTheRuntimeFile() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        #expect(await h.model.settings(for: titleID) == GameSettings())
        let changed = GameSettings(lang: 8, pro: false, upscale: true, hud: false, metal: 4)
        h.model.saveSettings(changed, for: titleID)
        #expect(await h.model.settings(for: titleID) == changed)
        #expect(GameSettings.load(titleID: titleID, settingsDir: h.paths.settingsDir) == changed)
        #expect(h.model.lastError == nil)
        h.model.saveSettings(changed, for: "bad")
        #expect(h.model.lastError != nil)
    }

    @Test func reportedErrorsAreReadable() async throws {
        let h = try Harness()
        defer { h.cleanUp() }
        h.model.report(AppError.busy(titleID))
        let busy = try #require(h.model.lastError)
        #expect(busy.contains(titleID) && !busy.contains("couldn’t be completed"))
        h.model.report(AppError.savesNotTrashed(freed: 2_000_000_000, message: "denied"))
        let saves = try #require(h.model.lastError)
        #expect(saves.contains("denied") && saves.contains("2 GB"))
        h.model.report(AppError.cannotBuild(titleID))
        #expect(h.model.lastError?.contains("cannot be built") == true)
        h.model.report(SaveError.noSaves(titleID))
        #expect(h.model.lastError?.contains("couldn’t be completed") == false)
        h.model.dismissError()
        #expect(h.model.lastError == nil)
    }

    @Test func freeSpaceIsMeasuredAtStartAddAndConfirm() async throws {
        let free = Mutex<Int64>(111)
        let h = try Harness(freeSpace: { _ in free.withLock { $0 } })
        defer { h.cleanUp() }
        #expect(h.model.libraryFreeBytes == 0)
        await h.model.start()
        #expect(h.model.libraryFreeBytes == 111)
        free.withLock { $0 = 2 << 40 }
        await h.model.add([h.src.appendingPathComponent("game.pkg")])
        #expect(h.model.libraryFreeBytes == 2 << 40)
        let candidate = try #require(h.model.pendingCandidates.first)
        #expect(!h.model.spaceShort(candidate))
        free.withLock { $0 = 333 }
        #expect(!h.model.spaceShort(candidate))
        try h.model.confirm(candidate, mode: .copy)
        try await wait("free space after confirm") { h.model.libraryFreeBytes == 333 }
        try await wait("import") { finished(h.model.queue) }
    }
}
