// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Runs the real `ps4-recomp` executable, one process per command.
public struct ProcessEngine: Engine {
    public let executable: URL

    public init(executable: URL) {
        self.executable = executable
    }

    public func run(_ arguments: [String], log: URL?,
                    onEvent: @escaping @Sendable (EngineEvent) -> Void) async throws -> EngineRun {
        if Task.isCancelled { throw EngineFailure(code: "cancelled", message: "cancelled") }
        let logFile = try log.map(EngineLog.init(url:))
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = logFile?.handle ?? FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let (exits, exited) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { p in
            exited.yield(p.terminationStatus)
            exited.finish()
        }
        try process.run()
        let running = RunningProcess(process)
        // The reader is not a child task, so a cancel reaches the engine (as SIGINT) and not the
        // read: the engine's own final `cancelled` event is still read and reported.
        let reader = Task.detached { () async throws -> EngineStream in
            var stream = EngineStream(log: logFile, onEvent: onEvent)
            for try await line in stdout.fileHandleForReading.bytes.lines { stream.feed(line) }
            return stream
        }
        return try await withTaskCancellationHandler {
            let stream: EngineStream
            do {
                stream = try await reader.value
            } catch {
                // The output cannot be read: stop the engine and wait for it, so that it does not
                // keep running (and holding the library lock) while the queue starts the next item.
                running.interrupt()
                for await _ in exits {}
                throw error
            }
            var status: Int32 = -1
            for await s in exits { status = s }
            if Task.isCancelled, stream.events.last.map({ $0.event != .done && $0.event != .error }) ?? true {
                // The engine died of the signal before it could report the cancel.
                _ = try? stream.finish(exitStatus: status)
                throw EngineFailure(code: "cancelled", message: "cancelled")
            }
            return try stream.finish(exitStatus: status)
        } onCancel: {
            running.interrupt()
        }
    }
}

/// The launched process, shared with the cancellation handler.
private final class RunningProcess: @unchecked Sendable {
    // Process is thread-safe for isRunning and interrupt(); it is only not marked Sendable.
    private let process: Process

    init(_ process: Process) { self.process = process }

    func interrupt() {
        if process.isRunning { process.interrupt() }
    }
}
