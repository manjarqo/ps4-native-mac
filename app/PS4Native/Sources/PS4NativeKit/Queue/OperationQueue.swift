// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Observation

/// One import, analysis or build in the `EngineOperationQueue`.
public struct OperationItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case importGame, analyze, build
    }

    public enum State: Sendable, Equatable {
        case queued, running, done, failed(EngineFailure), cancelled
    }

    public let id: UUID
    public let kind: Kind
    public let titleID: String?
    public let title: String
    public internal(set) var state: State = .queued
    /// The stage of the last progress event.
    public internal(set) var stage = ""
    /// Overall progress in 0...1; nil while it is unknown.
    public internal(set) var fraction: Double?
    /// The message of the last progress or warning event.
    public internal(set) var detail = ""
    public let log: URL
    public let created: Date

    /// Done, failed or cancelled.
    public var isFinished: Bool {
        switch state {
        case .queued, .running: false
        case .done, .failed, .cancelled: true
        }
    }

    /// The overall fraction after `event`: done/total, and for a build the four stages as
    /// quarters, `compile` filling the last one by files (3/4 + files/total/4).
    static func fraction(of event: EngineEvent, kind: Kind) -> Double? {
        guard let done = event.done, let total = event.total, total > 0 else { return nil }
        let part = Double(done) / Double(total)
        if kind == .build, event.stage == "compile" { return 0.75 + part / 4 }
        return part
    }
}

/// Runs the app's engine operations: builds one at a time, and imports and analyses one at a
/// time in a second lane, so one build and one import can run together.
@MainActor @Observable
public final class EngineOperationQueue {
    public typealias Progress = @Sendable (EngineEvent) -> Void
    public typealias Work = @Sendable (_ progress: @escaping Progress) async throws -> Void

    /// Every operation, in the order it was enqueued, until `clearFinished` removes it.
    public private(set) var items: [OperationItem] = []

    @ObservationIgnored private var works: [OperationItem.ID: Work] = [:]
    @ObservationIgnored private var tasks: [OperationItem.ID: Task<Void, Never>] = [:]

    public init() {}

    /// Adds an operation; it starts when its lane is free. `work` gets the engine events to
    /// show and is cancelled by `cancel`.
    @discardableResult
    public func enqueue(kind: OperationItem.Kind, title: String, titleID: String?, log: URL,
                        work: @escaping Work) -> OperationItem.ID {
        let item = OperationItem(id: UUID(), kind: kind, titleID: titleID, title: title, log: log, created: Date())
        items.append(item)
        works[item.id] = work
        startNext()
        return item.id
    }

    /// Cancels a running operation (its engine gets SIGINT), or takes a queued one out of
    /// its lane. Either ends as `.cancelled`.
    public func cancel(_ id: OperationItem.ID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[i].state {
        case .queued:
            works[id] = nil
            items[i].state = .cancelled
        case .running:
            tasks[id]?.cancel()
        case .done, .failed, .cancelled:
            break
        }
    }

    /// Removes the operations that are done, failed or cancelled.
    public func clearFinished() {
        items.removeAll { $0.isFinished }
    }

    private static func lane(_ kind: OperationItem.Kind) -> Int {
        kind == .build ? 0 : 1
    }

    /// Starts the first queued item of each lane that has nothing running.
    private func startNext() {
        var busy = Set(items.filter { $0.state == .running }.map { Self.lane($0.kind) })
        for i in items.indices where items[i].state == .queued {
            let lane = Self.lane(items[i].kind)
            guard !busy.contains(lane), let work = works.removeValue(forKey: items[i].id) else { continue }
            busy.insert(lane)
            items[i].state = .running
            start(items[i].id, kind: items[i].kind, work: work)
        }
    }

    private func start(_ id: OperationItem.ID, kind: OperationItem.Kind, work: @escaping Work) {
        // The events come through a stream, so the item sees them in order on the main actor.
        let (events, sink) = AsyncStream.makeStream(of: EngineEvent.self)
        tasks[id] = Task {
            // The work is a child task: cancelling this task cancels it.
            async let outcome = Self.perform(work, events: sink)
            for await event in events { apply(event, to: id, kind: kind) }
            finish(id, await outcome)
        }
    }

    private nonisolated static func perform(_ work: Work, events: AsyncStream<EngineEvent>.Continuation) async -> (any Error)? {
        defer { events.finish() }
        do {
            try await work { events.yield($0) }
            return nil
        } catch {
            return error
        }
    }

    private func apply(_ event: EngineEvent, to id: OperationItem.ID, kind: OperationItem.Kind) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        switch event.event {
        case .progress:
            items[i].stage = event.stage ?? ""
            items[i].fraction = OperationItem.fraction(of: event, kind: kind)
            items[i].detail = event.message ?? ""
        case .warning:
            items[i].detail = event.message ?? ""
        case .error, .done:
            break
        }
    }

    private func finish(_ id: OperationItem.ID, _ error: (any Error)?) {
        tasks[id] = nil
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].state = Self.state(after: error) }
        startNext()
    }

    private static func state(after error: (any Error)?) -> OperationItem.State {
        switch error {
        case nil: .done
        case let failure as EngineFailure: failure.code == "cancelled" ? .cancelled : .failed(failure)
        case is CancellationError: .cancelled
        // An error of the app's own part of the work, such as a library write.
        case let other?: .failed(EngineFailure(code: "app", message: other.localizedDescription))
        }
    }
}
