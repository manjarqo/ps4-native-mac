// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

private let smokeFixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

/// The smoke run on FakeEngine and a temp library, with `/bin/sleep 1` standing in for the game.
@MainActor @Suite struct SmokeRunnerTests {
    @MainActor final class Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ps4n-smoke-\(UUID().uuidString)")
        let suite = "ps4native-smoke-tests-\(UUID().uuidString)"
        let engine: FakeEngine
        let defaults: UserDefaults
        let model: AppModel

        var source: URL { root.appendingPathComponent("src", isDirectory: true) }

        init() throws {
            let paths = Paths(environment: [
                "HOME": root.path,
                "PS4NATIVE_LIBRARY": root.appendingPathComponent("library").path,
                "PS4RECOMP_DATA_DIR": root.appendingPathComponent("data").path,
                "PS4NATIVE_ENGINE": root.appendingPathComponent("engine").path,
            ])
            let library = LibraryStore(root: paths.libraryRoot)
            engine = SmokeRunner.engine(fixtures: smokeFixtures, source: root.appendingPathComponent("src"),
                                        temp: root, library: library)
            defaults = try #require(UserDefaults(suiteName: suite))
            model = AppModel(paths: paths, engine: engine, launcher: SmokeRunner.launcher(), queue: EngineOperationQueue(),
                             library: library,
                             saves: SaveStore(savesDir: paths.savesDir, backupsDir: paths.libraryRoot.appendingPathComponent("backups")),
                             defaults: defaults, applicationsDir: root.appendingPathComponent("Applications"),
                             freeSpace: { _ in 500_000_000_000 },
                             toolchainCheck: { _ in ToolchainReport(clangVersion: 21, sdkVersion: 27, freeBytes: 500_000_000_000, problems: []) })
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func everyStepPasses() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let report = await SmokeRunner().run(model: box.model, fixturesSource: box.source)
        #expect(report.steps.map(\.name) == SmokeRunner.stepNames)
        #expect(report.steps.allSatisfy { $0.passed }, "\(report.steps.filter { !$0.passed })")
        #expect(report.passed)
        #expect(report.titleID == "CUSA00557")
        let game = try #require(box.model.games.first)
        #expect(game.playSeconds >= 1 && !game.lastPlayed.isEmpty)
        #expect(box.model.primaryAction(game) == .play)
        #expect(box.engine.calls.map { $0.first ?? "" } == ["inspect", "import", "analyze-game", "build"])
        #expect(box.engine.calls.first == ["inspect", box.source.appendingPathComponent("game.pkg").path, "--json"])

        // The report is what the app writes to smoke.json.
        let decoded = try JSONDecoder().decode(SmokeReport.self, from: JSONEncoder().encode(report))
        #expect(decoded == report)
    }

    @Test func aFailingBuildFailsTheReportAtBuild() async throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        box.engine.setScript("build", lines: [
            #"{"event":"progress","op":"build","stage":"load","done":1,"total":4,"unit":"stages","message":"loading the ELF"}"#,
            #"{"event":"error","op":"build","code":"build_failed","message":"clang exited with status 1"}"#,
        ], exitOK: false)
        let report = await SmokeRunner().run(model: box.model, fixturesSource: box.source)
        #expect(!report.passed)
        #expect(report.steps.map(\.name) == Array(SmokeRunner.stepNames.prefix(4)))
        #expect(report.steps.dropLast().allSatisfy { $0.passed })
        let build = try #require(report.steps.last)
        #expect(build.name == "build" && !build.passed)
        #expect(build.detail.contains("clang exited with status 1"))
        #expect(box.model.launcher.running.isEmpty)
        #expect(box.model.games.first?.playSeconds == 0)
    }

    @Test func smokeEnvironmentMustNotBeTheRealLibraryOrDataDir() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ps4n-smoke-env-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        try fm.createDirectory(at: support.appendingPathComponent("PS4Native"), withIntermediateDirectories: true)
        // A link to the real home, so a path through it resolves to the real dirs.
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: home)
        let scratch = root.appendingPathComponent("scratch").path
        func problem(_ library: String?, _ data: String?) -> String? {
            var env = ["HOME": scratch]
            if let library { env["PS4NATIVE_LIBRARY"] = library }
            if let data { env["PS4RECOMP_DATA_DIR"] = data }
            return SmokeRunner.scratchProblem(environment: env, home: home)
        }

        #expect(problem(scratch + "/lib", scratch + "/data") == nil)
        #expect(problem(nil, scratch + "/data")?.contains("PS4NATIVE_LIBRARY") == true)
        #expect(problem(scratch + "/lib", "")?.contains("PS4RECOMP_DATA_DIR") == true)
        // The real dirs, spelled directly, with a trailing slash and "..", through a symlink,
        // and a directory inside them; the data dir need not exist yet.
        for library in [support.path + "/PS4Native", support.path + "/PS4Native/",
                        support.path + "/x/../PS4Native", link.path + "/Library/Application Support/PS4Native",
                        support.path + "/PS4Native/games"] {
            #expect(problem(library, scratch + "/data")?.contains("PS4NATIVE_LIBRARY") == true, "\(library)")
        }
        #expect(problem(scratch + "/lib", link.path + "/Library/Application Support/PS4Recomp")?
            .contains("PS4RECOMP_DATA_DIR") == true)
        // A sibling whose name only starts with the real one's is fine.
        #expect(problem(support.path + "/PS4NativeScratch", scratch + "/data") == nil)
    }
}
