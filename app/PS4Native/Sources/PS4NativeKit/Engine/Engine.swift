// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A failed engine command: the code and message of its final `error` event, `crashed` when the
/// stream ended without a result, or `cancelled`. Codes are listed in docs/game-manager-engine.md.
public struct EngineFailure: Error, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    static func crashed(status: Int32) -> EngineFailure {
        EngineFailure(code: "crashed", message: "the engine exited with status \(status) without a result")
    }
}

/// A finished, successful engine command.
public struct EngineRun: Sendable {
    /// Every event of the stream, the final `done` included.
    public let events: [EngineEvent]
    /// The raw `done` line, which carries the command's result.
    public let doneLine: Data

    public init(events: [EngineEvent], doneLine: Data) {
        self.events = events
        self.doneLine = doneLine
    }

    private struct Envelope<R: Decodable>: Decodable { let result: R }

    /// Decodes `{"result": …}` from the `done` line.
    public func result<R: Decodable>(_: R.Type) throws -> R {
        try JSONDecoder().decode(Envelope<R>.self, from: doneLine).result
    }

    /// Ends a stream: success when the last event is `done`, its error when it is `error`,
    /// and `crashed` otherwise.
    static func finish(events: [EngineEvent], doneLine: Data?, exitStatus: Int32) throws -> EngineRun {
        switch events.last?.event {
        case .done?:
            if let doneLine { return EngineRun(events: events, doneLine: doneLine) }
        case .error?:
            let last = events[events.count - 1]
            throw EngineFailure(code: last.code ?? "", message: last.message ?? "")
        default:
            break
        }
        throw EngineFailure.crashed(status: exitStatus)
    }
}

/// Runs one `ps4-recomp` command with `--json` and streams its events.
public protocol Engine: Sendable {
    /// Runs `ps4-recomp <arguments>`; the arguments include `--json`. The engine's stderr goes to
    /// `log` when it is set. Throws `EngineFailure` when the command fails, crashes or is cancelled.
    func run(_ arguments: [String], log: URL?, onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> EngineRun
}

/// How `import` adds a folder: a copy (APFS clone when possible) or a symlink to the folder.
public enum ImportMode: String, Sendable, CaseIterable {
    case copy, reference
}

/// The command lines of the typed helpers, shared by `Engine` and `FakeEngine`.
enum EngineCommand {
    static func inspect(_ src: URL) -> [String] { ["inspect", src.path, "--json"] }
    static func importGame(_ src: URL, library: URL, mode: ImportMode) -> [String] {
        ["import", src.path, "--library", library.path, "--mode", mode.rawValue, "--json"]
    }
    static func analyze(content: URL) -> [String] { ["analyze-game", content.path, "--json"] }
    static func build(content: URL, buildDir: URL) -> [String] {
        ["build", content.appending(path: "eboot.bin").path, "-o", buildDir.path, "--json"]
    }
    static let version = ["version", "--json"]
}

public extension Engine {
    func inspect(_ src: URL) async throws -> InspectResult {
        try await run(EngineCommand.inspect(src), log: nil) { _ in }.result(InspectResult.self)
    }

    func importGame(_ src: URL, library: URL, mode: ImportMode, log: URL?,
                    onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> ImportResult {
        try await run(EngineCommand.importGame(src, library: library, mode: mode), log: log, onEvent: onEvent)
            .result(ImportResult.self)
    }

    func analyze(content: URL, log: URL?,
                 onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> GameAnalysis {
        try await run(EngineCommand.analyze(content: content), log: log, onEvent: onEvent).result(GameAnalysis.self)
    }

    func build(content: URL, buildDir: URL, log: URL?,
               onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> BuildResult {
        try await run(EngineCommand.build(content: content, buildDir: buildDir), log: log, onEvent: onEvent)
            .result(BuildResult.self)
    }

    func version() async throws -> VersionResult {
        try await run(EngineCommand.version, log: nil) { _ in }.result(VersionResult.self)
    }
}

/// Collects the lines of one engine `--json` stream: decodes each into an `EngineEvent`, hands
/// it on, keeps the raw `done` line, and writes lines that are not events to the log.
struct EngineStream {
    private(set) var events: [EngineEvent] = []
    private(set) var doneLine: Data?
    private(set) var nonJSONLines = 0
    private let log: EngineLog?
    private let onEvent: @Sendable (EngineEvent) -> Void
    private let decoder = JSONDecoder()

    init(log: EngineLog?, onEvent: @escaping @Sendable (EngineEvent) -> Void) {
        self.log = log
        self.onEvent = onEvent
    }

    mutating func feed(_ line: String) {
        let data = Data(line.utf8)
        guard let event = try? decoder.decode(EngineEvent.self, from: data) else {
            nonJSONLines += 1
            log?.write("[app] non-JSON engine line: \(line)\n")
            return
        }
        if event.event == .done { doneLine = data }
        events.append(event)
        onEvent(event)
    }

    func finish(exitStatus: Int32) throws -> EngineRun {
        if nonJSONLines > 0 { log?.write("[app] \(nonJSONLines) non-JSON engine line(s) in this run\n") }
        return try EngineRun.finish(events: events, doneLine: doneLine, exitStatus: exitStatus)
    }
}

/// An engine log file opened for appending. The engine's stderr and the app's own notes about
/// the run share it; O_APPEND keeps their writes from overwriting each other.
final class EngineLog: Sendable {
    let handle: FileHandle

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func write(_ text: String) {
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
