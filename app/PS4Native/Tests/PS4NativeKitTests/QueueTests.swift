// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

private let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
private let log = URL(filePath: "/tmp/unused.log")

/// Counts the works running at once.
private actor Concurrency {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var order: [String] = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    func enter(_ name: String) {
        current += 1
        peak = max(peak, current)
        order.append("+" + name)
        waiting.removeValue(forKey: name)?.forEach { $0.resume() }
    }

    /// Returns once `name` has entered.
    func waitFor(_ name: String) async {
        if order.contains("+" + name) { return }
        await withCheckedContinuation { waiting[name, default: []].append($0) }
    }

    func leave(_ name: String) {
        current -= 1
        order.append("-" + name)
    }
}

@MainActor @Suite struct QueueTests {
    func item(_ queue: EngineOperationQueue, _ id: OperationItem.ID) throws -> OperationItem {
        try #require(queue.items.first { $0.id == id })
    }

    /// Waits until `condition` holds, polling the main actor.
    func wait(_ what: Comment, timeout: Duration = .seconds(20), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out waiting: \(what)"); return }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func finished(_ queue: EngineOperationQueue) -> Bool {
        queue.items.allSatisfy { $0.state != .queued && $0.state != .running }
    }

    private func timed(_ c: Concurrency, _ name: String) -> @Sendable (_ progress: @escaping @Sendable (EngineEvent) -> Void) async throws -> Void {
        { _ in
            await c.enter(name)
            try await Task.sleep(for: .milliseconds(150))
            await c.leave(name)
        }
    }

    @Test func buildsRunOneAtATime() async throws {
        let queue = EngineOperationQueue()
        let c = Concurrency()
        let a = queue.enqueue(kind: .build, title: "A", titleID: "CUSA00001", log: log, work: timed(c, "a"))
        let b = queue.enqueue(kind: .build, title: "B", titleID: "CUSA00002", log: log, work: timed(c, "b"))
        #expect(try item(queue, b).state == .queued)
        try await wait("builds") { finished(queue) }
        #expect(await c.peak == 1)
        #expect(await c.order == ["+a", "-a", "+b", "-b"])
        #expect(try item(queue, a).state == .done && item(queue, b).state == .done)
    }

    @Test func importsAndAnalysesShareALane() async throws {
        let queue = EngineOperationQueue()
        let c = Concurrency()
        _ = queue.enqueue(kind: .importGame, title: "A", titleID: nil, log: log, work: timed(c, "import"))
        _ = queue.enqueue(kind: .analyze, title: "A", titleID: "CUSA00001", log: log, work: timed(c, "analyze"))
        try await wait("import lane") { finished(queue) }
        #expect(await c.order == ["+import", "-import", "+analyze", "-analyze"])
    }

    /// A work that stays running until `other` has entered too.
    private func meeting(_ c: Concurrency, _ name: String, _ other: String) -> @Sendable (_ progress: @escaping @Sendable (EngineEvent) -> Void) async throws -> Void {
        { _ in
            await c.enter(name)
            await c.waitFor(other)
            await c.leave(name)
        }
    }

    // The two works wait for each other, so this hangs (and hits the limit) unless the lanes overlap.
    @Test(.timeLimit(.minutes(1))) func buildAndImportRunTogether() async throws {
        let queue = EngineOperationQueue()
        let c = Concurrency()
        _ = queue.enqueue(kind: .build, title: "A", titleID: "CUSA00001", log: log, work: meeting(c, "build", "import"))
        _ = queue.enqueue(kind: .importGame, title: "B", titleID: nil, log: log, work: meeting(c, "import", "build"))
        _ = queue.enqueue(kind: .build, title: "C", titleID: "CUSA00003", log: log, work: timed(c, "build2"))
        try await wait("both lanes") { finished(queue) }
        #expect(await c.peak == 2)
        #expect(queue.items.allSatisfy { $0.state == .done })
    }

    @Test func buildFractionsOfTheRecordedStream() throws {
        let text = try String(contentsOf: fixtures.appending(path: "build.jsonl"), encoding: .utf8)
        let events = try text.split(separator: "\n").map { try JSONDecoder().decode(EngineEvent.self, from: Data($0.utf8)) }
        let fractions = events.filter { $0.event == .progress }.map { OperationItem.fraction(of: $0, kind: .build) }
        #expect(Array(fractions.prefix(4)) == [0.25, 0.5, 0.75, 0.75])
        #expect(fractions[4] == 0.75 + 1.0 / 145 / 4)
        #expect(fractions.last == 1.0)
        #expect(zip(fractions, fractions.dropFirst()).allSatisfy { $0! <= $1! })
        // Non-build operations report done/total, and nothing without a total.
        let copy = EngineEvent(event: .progress, op: "import", stage: "copy", done: 1, total: 4, unit: "bytes")
        #expect(OperationItem.fraction(of: copy, kind: .importGame) == 0.25)
        let lock = EngineEvent(event: .progress, op: "import", stage: "lock", done: 0, total: 0, unit: "stages")
        #expect(OperationItem.fraction(of: lock, kind: .importGame) == nil)
    }

    @Test func buildProgressThroughTheQueue() async throws {
        let engine = FakeEngine(fixtures: fixtures, substitutions: ["$LIB": "/tmp/lib"], delay: .milliseconds(20))
        let queue = EngineOperationQueue()
        let id = queue.enqueue(kind: .build, title: "Hello", titleID: "CUSA00557", log: log) { progress in
            _ = try await engine.build(content: URL(filePath: "/c"), buildDir: URL(filePath: "/b"), log: nil, onEvent: progress)
        }
        var seen: [Double] = []
        var stages: [String] = []
        while let it = queue.items.first(where: { $0.id == id }), it.state == .queued || it.state == .running {
            if let f = it.fraction, seen.last != f { seen.append(f) }
            if stages.last != it.stage, !it.stage.isEmpty { stages.append(it.stage) }
            try await Task.sleep(for: .milliseconds(2))
        }
        let done = try item(queue, id)
        #expect(done.state == .done)
        #expect(done.stage == "compile" && done.fraction == 1.0 && done.detail == "compiling")
        // A poll can miss any short-lived state, so the samples need only be an in-order
        // subsequence of the stream's values (the exact mapping is buildFractionsOfTheRecordedStream).
        #expect(isOrderedSubsequence(stages, of: ["load", "cfg", "emit", "compile"]), "\(stages)")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }, "\(seen)")
        // Every value is a stage quarter or 3/4 + files/total/4.
        for f in seen {
            let files = (f - 0.75) * 4 * 145
            #expect(f == 0.25 || f == 0.5 || (f >= 0.75 && abs(files - files.rounded()) < 1e-6), "\(f)")
        }
    }

    func isOrderedSubsequence(_ sample: [String], of expected: [String]) -> Bool {
        var rest = expected[...]
        for s in sample {
            guard let i = rest.firstIndex(of: s) else { return false }
            rest = rest[(i + 1)...]
        }
        return true
    }

    @Test func cancellingARunningBuild() async throws {
        let engine = FakeEngine(fixtures: fixtures, substitutions: [:], delay: .milliseconds(50))
        let queue = EngineOperationQueue()
        let id = queue.enqueue(kind: .build, title: "Hello", titleID: "CUSA00557", log: log) { progress in
            _ = try await engine.build(content: URL(filePath: "/c"), buildDir: URL(filePath: "/b"), log: nil, onEvent: progress)
        }
        try await wait("first progress") {
            guard let it = try? item(queue, id) else { return false }
            return it.state == .running && !it.stage.isEmpty
        }
        queue.cancel(id)
        try await wait("cancel") { finished(queue) }
        #expect(try item(queue, id).state == .cancelled)
    }

    @Test func cancellingAQueuedItem() async throws {
        let queue = EngineOperationQueue()
        let c = Concurrency()
        let a = queue.enqueue(kind: .build, title: "A", titleID: "CUSA00001", log: log, work: timed(c, "a"))
        let b = queue.enqueue(kind: .build, title: "B", titleID: "CUSA00002", log: log, work: timed(c, "b"))
        queue.cancel(b)
        #expect(try item(queue, b).state == .cancelled)
        try await wait("first build") { finished(queue) }
        #expect(await c.order == ["+a", "-a"])
        #expect(try item(queue, a).state == .done)
        queue.clearFinished()
        #expect(queue.items.isEmpty)
    }

    @Test func failingWorkKeepsItsCode() async throws {
        let engine = FakeEngine(fixtures: fixtures, substitutions: [:])
        let queue = EngineOperationQueue()
        let id = queue.enqueue(kind: .importGame, title: "retail.pkg", titleID: nil, log: log) { progress in
            _ = try await engine.importGame(URL(filePath: "/x.pkg"), library: URL(filePath: "/lib"), mode: .copy,
                                            log: nil, fixture: "import-retail", onEvent: progress)
        }
        try await wait("failure") { finished(queue) }
        guard case .failed(let failure) = try item(queue, id).state else {
            Issue.record("not failed: \(try item(queue, id).state)")
            return
        }
        #expect(failure.code == "retail_pkg")
    }

    @Test func clearFinishedKeepsLiveItems() async throws {
        let queue = EngineOperationQueue()
        let c = Concurrency()
        _ = queue.enqueue(kind: .analyze, title: "A", titleID: "CUSA00001", log: log) { _ in }
        try await wait("analysis") { finished(queue) }
        let b = queue.enqueue(kind: .build, title: "B", titleID: "CUSA00002", log: log, work: timed(c, "b"))
        queue.clearFinished()
        #expect(queue.items.map(\.id) == [b])
        try await wait("build") { finished(queue) }
    }
}
