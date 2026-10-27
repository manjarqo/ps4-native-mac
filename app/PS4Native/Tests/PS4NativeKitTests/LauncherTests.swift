// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

/// The launcher runs real processes, but only `/bin/sleep`, `/usr/bin/false` and shell scripts,
/// each through a temp `.app` whose `Contents/MacOS/x` is the script.
@MainActor @Suite struct LauncherTests {
    struct Exit: Sendable, Equatable {
        let titleID: String
        let seconds: Int64
        let status: PS4NativeKit.ExitStatus
    }

    final class Sandbox {
        let root: URL
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ps4n-launch-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        var log: URL { root.appendingPathComponent("logs/run.log") }

        /// A bundle whose executable is `script`, run by /bin/sh.
        func app(_ script: String) throws -> URL {
            let app = root.appendingPathComponent("Game-\(UUID().uuidString).app")
            let macOS = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let exe = macOS.appendingPathComponent("x")
            try Data("#!/bin/sh\n\(script)\n".utf8).write(to: exe)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "x"], format: .xml, options: 0)
            try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
            return app
        }
    }

    /// Collects the launcher's exits.
    func exits(of launcher: GameLauncher) -> AsyncStream<Exit> {
        let (stream, sink) = AsyncStream.makeStream(of: Exit.self)
        launcher.onExit = { titleID, seconds, status in sink.yield(Exit(titleID: titleID, seconds: seconds, status: status)) }
        return stream
    }

    func next(_ stream: AsyncStream<Exit>) async throws -> Exit {
        var it = stream.makeAsyncIterator()
        return try #require(await it.next())
    }

    @Test func launchTracksTheGameAndRefusesASecondLaunch() async throws {
        let box = try Sandbox()
        let launcher = GameLauncher()
        let stream = exits(of: launcher)
        let app = try box.app("exec /bin/sleep 30")
        try launcher.launch(titleID: "CUSA00557", app: app, environment: [:], log: box.log)
        let game = try #require(launcher.running["CUSA00557"])
        #expect(game.titleID == "CUSA00557" && game.pid > 0)
        #expect(throws: LaunchError.alreadyRunning("CUSA00557")) {
            try launcher.launch(titleID: "CUSA00557", app: app, environment: [:], log: box.log)
        }
        launcher.stop(titleID: "CUSA00557")
        let exit = try await next(stream)
        // SIGTERM from stop is a normal end.
        #expect(exit == Exit(titleID: "CUSA00557", seconds: exit.seconds, status: .normal))
        #expect(launcher.running.isEmpty)
    }

    @Test func stopKillsAGameThatIgnoresSIGTERM() async throws {
        let box = try Sandbox()
        let launcher = GameLauncher(stopTimeout: .milliseconds(300))
        let stream = exits(of: launcher)
        // The shell ignores SIGTERM (macOS sleep does not keep an inherited ignore, so it is not
        // exec'd); stop signals the shell only, and the short sleeps end on their own.
        try launcher.launch(titleID: "CUSA00557", app: try box.app("trap '' TERM\necho ready\nwhile :; do /bin/sleep 0.05; done"),
                            environment: [:], log: box.log)
        // The first exec of a new script can take a while; stop only once the trap is set.
        let deadline = ContinuousClock.now + .seconds(20)
        while (try? String(contentsOf: box.log, encoding: .utf8)) != "ready\n", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let start = ContinuousClock.now
        launcher.stop(titleID: "CUSA00557")
        let exit = try await next(stream)
        #expect(exit.status == .signal(SIGKILL))
        #expect(ContinuousClock.now - start >= .milliseconds(300))
        #expect(launcher.running.isEmpty)
    }

    @Test func normalExit() async throws {
        let box = try Sandbox()
        let launcher = GameLauncher()
        let stream = exits(of: launcher)
        try launcher.launch(titleID: "CUSA00557", app: try box.app("exit 0"), environment: [:], log: box.log)
        let exit = try await next(stream)
        #expect(exit.titleID == "CUSA00557" && exit.status == .normal && exit.seconds >= 0)
        #expect(launcher.running.isEmpty)
    }

    @Test func exitCodeIsReported() async throws {
        let box = try Sandbox()
        let launcher = GameLauncher()
        let stream = exits(of: launcher)
        try launcher.launch(titleID: "CUSA00557", app: try box.app("exec /usr/bin/false"), environment: [:], log: box.log)
        #expect(try await next(stream).status == .code(1))
    }

    @Test func playTimeIsMeasured() async throws {
        let box = try Sandbox()
        let launcher = GameLauncher()
        let stream = exits(of: launcher)
        try launcher.launch(titleID: "CUSA00557", app: try box.app("exec /bin/sleep 1.2"), environment: [:], log: box.log)
        let exit = try await next(stream)
        #expect(exit.status == .normal && exit.seconds >= 1)
    }

    @Test func logHoldsStdoutAndStderrAppended() async throws {
        let box = try Sandbox()
        try FileManager.default.createDirectory(at: box.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("earlier run\n".utf8).write(to: box.log)
        let launcher = GameLauncher()
        let stream = exits(of: launcher)
        try launcher.launch(titleID: "CUSA00557", app: try box.app("echo out\necho err >&2"), environment: [:], log: box.log)
        _ = try await next(stream)
        #expect(try String(contentsOf: box.log, encoding: .utf8) == "earlier run\nout\nerr\n")
    }

    @Test func environmentReachesTheGame() async throws {
        let box = try Sandbox()
        let launcher = GameLauncher()
        let stream = exits(of: launcher)
        try launcher.launch(titleID: "CUSA00557", app: try box.app(#"echo "dialogs=$PS4_NO_DIALOGS home=$HOME""#),
                            environment: ["PS4_NO_DIALOGS": "1"], log: box.log)
        _ = try await next(stream)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        // The given variables are merged into the app's own environment.
        #expect(try String(contentsOf: box.log, encoding: .utf8) == "dialogs=1 home=\(home)\n")
    }

    @Test func bundleWithoutExecutableIsRefused() throws {
        let box = try Sandbox()
        let app = box.root.appendingPathComponent("Empty.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let launcher = GameLauncher()
        #expect(throws: LaunchError.noExecutable(app)) {
            try launcher.launch(titleID: "CUSA00557", app: app, environment: [:], log: box.log)
        }
        #expect(launcher.running.isEmpty)
    }
}
