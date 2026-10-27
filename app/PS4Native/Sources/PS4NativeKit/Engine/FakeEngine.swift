// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Synchronization

/// An `Engine` that replays recorded `--json` streams, for tests and previews.
///
/// A command `ps4-recomp <subcommand> …` replays `<fixtures>/<subcommand>.jsonl`, or the lines
/// set with `setScript`. Placeholders such as `$LIB`, `$SRC` and `$TMP` in the recorded lines
/// are replaced by `substitutions`. A cancel ends the stream with a `cancelled` error event,
/// as the real engine does. A replay has none of the engine's side effects on disk; `afterRun`
/// can supply them.
public final class FakeEngine: Engine {
    /// Called after a successful replay with the command's arguments and its `done` line; an
    /// error it throws fails the command.
    public typealias AfterRun = @Sendable (_ arguments: [String], _ doneLine: Data) async throws -> Void

    private struct Script {
        let lines: [String]
        let exitOK: Bool
    }

    private struct State {
        var scripts: [String: Script] = [:]
        var calls: [[String]] = []
        var afterRun: AfterRun?
    }

    public let fixtures: URL
    private let substitutions: [(String, String)]
    private let delay: Duration
    private let state = Mutex(State())

    public init(fixtures: URL, substitutions: [String: String], delay: Duration = .zero) {
        self.fixtures = fixtures
        // Longest placeholder first, so one that contains another is replaced whole.
        self.substitutions = substitutions.sorted { ($0.key.count, $0.key) > ($1.key.count, $1.key) }
            .map { ($0.key, $0.value) }
        self.delay = delay
    }

    /// The argument lists of every command run so far, in order.
    public var calls: [[String]] { state.withLock { $0.calls } }

    /// Runs after each successful replay, for example to write what an import adds to the library.
    public var afterRun: AfterRun? {
        get { state.withLock { $0.afterRun } }
        set { state.withLock { $0.afterRun = newValue } }
    }

    /// Replays `lines` for `subcommand` instead of its fixture file. `exitOK` is the exit status
    /// reported when the lines end without a result (0 when true, 1 when false).
    public func setScript(_ subcommand: String, lines: [String], exitOK: Bool) {
        state.withLock { $0.scripts[subcommand] = Script(lines: lines, exitOK: exitOK) }
    }

    public func run(_ arguments: [String], log: URL?,
                    onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> EngineRun {
        try await replay(arguments, fixture: nil, log: log, onEvent: onEvent)
    }

    /// Replays the stream for `arguments`; `fixture` names a fixture file to use instead of the
    /// subcommand's.
    func replay(_ arguments: [String], fixture: String?, log: URL?,
                onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> EngineRun {
        let subcommand = arguments.first ?? ""
        let script: Script = try state.withLock { s in
            s.calls.append(arguments)
            if fixture == nil, let script = s.scripts[subcommand] { return script }
            let url = fixtures.appending(path: "\(fixture ?? subcommand).jsonl")
            let text = try String(contentsOf: url, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let failed = lines.last?.contains(#""event":"error""#) ?? false
            return Script(lines: lines, exitOK: !failed)
        }
        var stream = EngineStream(log: try log.map(EngineLog.init(url:)), onEvent: onEvent)
        for (i, line) in script.lines.enumerated() {
            do {
                if i > 0, delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
            } catch {
                stream.feed(Self.cancelledLine(op: subcommand))
                return try stream.finish(exitStatus: 1)
            }
            stream.feed(substitute(line))
        }
        let run = try stream.finish(exitStatus: script.exitOK ? 0 : 1)
        if let afterRun { try await afterRun(arguments, run.doneLine) }
        return run
    }

    private static func cancelledLine(op: String) -> String {
        let event: [String: String] = ["event": "error", "op": op, "code": "cancelled", "message": "cancelled"]
        // A dictionary of strings always serialises.
        let data = (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private func substitute(_ line: String) -> String {
        var out = line
        for (placeholder, value) in substitutions { out = out.replacingOccurrences(of: placeholder, with: value) }
        return out
    }
}

// The typed helpers of `Engine`, replaying a named fixture instead of the subcommand's.
public extension FakeEngine {
    func inspect(_ src: URL, fixture: String) async throws -> InspectResult {
        try await replay(EngineCommand.inspect(src), fixture: fixture, log: nil) { _ in }.result(InspectResult.self)
    }

    func importGame(_ src: URL, library: URL, mode: ImportMode, log: URL?, fixture: String,
                    onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> ImportResult {
        try await replay(EngineCommand.importGame(src, library: library, mode: mode), fixture: fixture,
                         log: log, onEvent: onEvent).result(ImportResult.self)
    }

    func analyze(content: URL, log: URL?, fixture: String,
                 onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> GameAnalysis {
        try await replay(EngineCommand.analyze(content: content), fixture: fixture, log: log, onEvent: onEvent)
            .result(GameAnalysis.self)
    }

    func build(content: URL, buildDir: URL, log: URL?, fixture: String,
               onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> BuildResult {
        try await replay(EngineCommand.build(content: content, buildDir: buildDir), fixture: fixture,
                         log: log, onEvent: onEvent).result(BuildResult.self)
    }

    func version(fixture: String) async throws -> VersionResult {
        try await replay(EngineCommand.version, fixture: fixture, log: nil) { _ in }.result(VersionResult.self)
    }
}
