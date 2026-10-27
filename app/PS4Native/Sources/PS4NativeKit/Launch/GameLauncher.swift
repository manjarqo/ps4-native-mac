// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Observation

/// How a game process ended.
public enum ExitStatus: Sendable, Equatable {
    /// Exit status 0, or the SIGTERM sent by `GameLauncher.stop`.
    case normal
    /// A non-zero exit status.
    case code(Int32)
    /// Killed by a signal.
    case signal(Int32)
}

public enum LaunchError: Error, Equatable, Sendable {
    case alreadyRunning(String)
    /// The bundle's Info.plist names no executable, or that file cannot be run.
    case noExecutable(URL)
}

/// A game the launcher started and that has not exited yet.
public struct RunningGame: Sendable, Equatable {
    public let pid: Int32
    public let started: Date
    public let titleID: String
}

/// A started game process.
public protocol SpawnedGame: Sendable {
    var pid: Int32 { get }
    /// Sends `signal` to the process while it runs; does nothing once it has exited.
    func send(_ signal: Int32)
}

/// Starts game processes. `GameLauncher` uses `ProcessSpawner` unless another is injected.
public protocol GameSpawner: Sendable {
    /// Runs `executable` with exactly `environment`, stdout and stderr to `output` and stdin
    /// from /dev/null. `onExit` is called once, from any thread, when the process has ended.
    func spawn(_ executable: URL, environment: [String: String], output: FileHandle,
               onExit: @escaping @Sendable (ExitStatus) -> Void) throws -> any SpawnedGame
}

/// Spawns games with Foundation `Process`.
public struct ProcessSpawner: GameSpawner {
    /// The command run in place of every game, for the smoke run; nil runs the game.
    private let standIn: (executable: URL, arguments: [String])?

    public init() {
        standIn = nil
    }

    /// Runs `executable` with `arguments` instead of the game it is asked to spawn, with the
    /// game's environment and output, so a launch can be exercised without running a game.
    public init(standIn executable: URL, arguments: [String]) {
        standIn = (executable, arguments)
    }

    public func spawn(_ executable: URL, environment: [String: String], output: FileHandle,
                      onExit: @escaping @Sendable (ExitStatus) -> Void) throws -> any SpawnedGame {
        let process = Process()
        process.executableURL = standIn?.executable ?? executable
        process.arguments = standIn?.arguments ?? []
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { p in
            switch (p.terminationReason, p.terminationStatus) {
            case (.exit, 0): onExit(.normal)
            case (.exit, let code): onExit(.code(code))
            case (.uncaughtSignal, let signal): onExit(.signal(signal))
            @unknown default: onExit(.code(p.terminationStatus))
            }
        }
        try process.run()
        return SpawnedProcess(process)
    }
}

/// A `Process` shared with the stop timer.
private final class SpawnedProcess: SpawnedGame, @unchecked Sendable {
    // Process is thread-safe for isRunning and processIdentifier; it is only not marked Sendable.
    private let process: Process
    let pid: Int32

    init(_ process: Process) {
        self.process = process
        pid = process.processIdentifier
    }

    func send(_ signal: Int32) {
        // isRunning turns false when the process is reaped: a pid reused after that is never
        // signalled, short of a reuse between this check and the kill.
        if process.isRunning { kill(pid, signal) }
    }
}

/// Runs built games, one process per title, and reports how long each ran.
@MainActor @Observable
public final class GameLauncher {
    /// The games running now, by TITLE_ID.
    public private(set) var running: [String: RunningGame] = [:]

    /// Called on the main actor when a game has exited, with its whole seconds of play time.
    @ObservationIgnored
    public var onExit: (@MainActor (_ titleID: String, _ seconds: Int64, _ status: ExitStatus) -> Void)?

    /// How long `stop` waits after SIGTERM before it sends SIGKILL.
    public let stopTimeout: Duration

    private struct Session {
        let token: UUID
        let process: any SpawnedGame
        let start: ContinuousClock.Instant
        var stopping = false
        var killTimer: Task<Void, Never>?
    }

    @ObservationIgnored private let spawner: any GameSpawner
    @ObservationIgnored private var sessions: [String: Session] = [:]

    public init(spawn: any GameSpawner = ProcessSpawner(), stopTimeout: Duration = .seconds(10)) {
        spawner = spawn
        self.stopTimeout = stopTimeout
    }

    /// Runs `<app>/Contents/MacOS/<CFBundleExecutable>` with the app's environment merged with
    /// `environment`, its stdout and stderr appended to `log`.
    public func launch(titleID: String, app: URL, environment: [String: String], log: URL) throws {
        guard sessions[titleID] == nil else { throw LaunchError.alreadyRunning(titleID) }
        let executable = try Self.executable(of: app)
        let output = try EngineLog(url: log)
        let env = ProcessInfo.processInfo.environment.merging(environment) { _, given in given }
        let token = UUID()
        let process = try spawner.spawn(executable, environment: env, output: output.handle) { [weak self] status in
            Task { @MainActor in self?.exited(titleID, token: token, status: status) }
        }
        sessions[titleID] = Session(token: token, process: process, start: .now)
        running[titleID] = RunningGame(pid: process.pid, started: Date(), titleID: titleID)
    }

    /// Asks the game to quit with SIGTERM, and kills it with SIGKILL after `stopTimeout`.
    public func stop(titleID: String) {
        guard var session = sessions[titleID], !session.stopping else { return }
        session.stopping = true
        session.process.send(SIGTERM)
        let process = session.process, timeout = stopTimeout
        session.killTimer = Task {
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            process.send(SIGKILL)
        }
        sessions[titleID] = session
    }

    private func exited(_ titleID: String, token: UUID, status: ExitStatus) {
        guard let session = sessions[titleID], session.token == token else { return }
        session.killTimer?.cancel()
        sessions[titleID] = nil
        running[titleID] = nil
        let seconds = (ContinuousClock.now - session.start).components.seconds
        let reported = session.stopping && status == .signal(SIGTERM) ? .normal : status
        onExit?(titleID, seconds, reported)
    }

    /// The bundle's executable, from CFBundleExecutable in its Info.plist.
    static func executable(of app: URL) throws -> URL {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String, !name.isEmpty, !name.contains("/")
        else { throw LaunchError.noExecutable(app) }
        let exe = contents.appendingPathComponent("MacOS", isDirectory: true).appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: exe.path) else { throw LaunchError.noExecutable(app) }
        return exe
    }
}
