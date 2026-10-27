// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

private let fixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!

@Test func decodesEveryRecordedStream() throws {
    for name in ["inspect", "inspect-retail", "inspect-folder", "import", "import-patch", "import-dlc",
                 "import-retail", "analyze-game", "build", "version"] {
        let text = try String(contentsOf: fixtures.appending(path: "\(name).jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(!lines.isEmpty, "\(name) is empty")
        for line in lines {
            #expect(throws: Never.self) { try JSONDecoder().decode(EngineEvent.self, from: Data(line.utf8)) }
        }
    }
}

@Test func typedResults() async throws {
    let engine = FakeEngine(fixtures: fixtures, substitutions: ["$LIB": "/tmp/lib", "$SRC": "/tmp/src", "$TMP": "/tmp"])
    let inspect = try await engine.inspect(URL(filePath: "/tmp/src/game.pkg"))
    #expect(inspect.kind == "game" && inspect.signing == "fake" && inspect.titleID == "CUSA00557")
    let retail = try await engine.inspect(URL(filePath: "/tmp/src/retail.pkg"), fixture: "inspect-retail")
    #expect(retail.signing == "retail")
    let analysis = try await engine.analyze(content: URL(filePath: "/tmp/lib/games/CUSA00557/content"), log: nil) { _ in }
    #expect(analysis.titleID == "CUSA00557")
    let version = try await engine.version()
    #expect(!version.version.isEmpty)
}

@Test func errorStreamThrowsItsCode() async throws {
    let engine = FakeEngine(fixtures: fixtures, substitutions: [:])
    await #expect(throws: EngineFailure(code: "retail_pkg", message: "this PKG is encrypted with console keys; use a dump of your own console or an fpkg")) {
        _ = try await engine.importGame(URL(filePath: "/x.pkg"), library: URL(filePath: "/lib"), mode: .copy, log: nil, fixture: "import-retail") { _ in }
    }
}

@Test func streamWithoutResultIsACrash() async throws {
    let engine = FakeEngine(fixtures: fixtures, substitutions: [:])
    engine.setScript("analyze-game", lines: [#"{"event":"progress","op":"analyze-game","stage":"analyze","done":0,"total":1,"unit":"stages"}"#], exitOK: false)
    await #expect(throws: EngineFailure.self) { _ = try await engine.analyze(content: URL(filePath: "/c"), log: nil) { _ in } }
}

@Test func cancelEndsWithCancelled() async throws {
    let engine = FakeEngine(fixtures: fixtures, substitutions: [:], delay: .milliseconds(200))
    let task = Task { try await engine.build(content: URL(filePath: "/c"), buildDir: URL(filePath: "/b"), log: nil) { _ in } }
    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do { _ = try await task.value; Issue.record("not cancelled") } catch let f as EngineFailure { #expect(f.code == "cancelled") }
}

@Test func processEngineRunsTheRealBinary() async throws {
    // The real engine, when it is built in the repo (CI builds it first); skipped with a recorded reason otherwise.
    let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
    let exe = repo.appending(path: "ps4-recomp")
    try #require(FileManager.default.isExecutableFile(atPath: exe.path), "build ps4-recomp in the repo root first")
    let engine = ProcessEngine(executable: exe)
    let v = try await engine.version()
    #expect(!v.version.isEmpty)
    let log = FileManager.default.temporaryDirectory.appending(path: "engine-\(UUID()).log")
    await #expect(throws: EngineFailure.self) { _ = try await engine.analyze(content: URL(filePath: "/nonexistent"), log: log) { _ in } }
}

/// The children of this process whose command name is `name`, zombies included.
private func children(named name: String) -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
    let stride = MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
    size = procs.count * stride
    guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return [] }
    let me = getpid()
    return procs.prefix(size / stride).compactMap { p in
        guard p.kp_eproc.e_ppid == me else { return nil }
        let comm = withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return comm == name ? p.kp_proc.p_pid : nil
    }
}

/// Cancel is SIGINT. analyze-game has no cancel of its own: the signal ends the real engine
/// without a `cancelled` event, the run still ends as cancelled, and only once the process has
/// exited and been reaped (no child of that name is left, not even a zombie).
@Test func cancelOfARealAnalysisStopsTheEngine() async throws {
    let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
    let exe = repo.appending(path: "ps4-recomp")
    try #require(FileManager.default.isExecutableFile(atPath: exe.path), "build ps4-recomp in the repo root first")
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appending(path: "ps4n-cancel-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? fm.removeItem(at: tmp) }
    let content = tmp.appending(path: "content", directoryHint: .isDirectory)
    try fm.createDirectory(at: content.appending(path: "sce_sys"), withIntermediateDirectories: true)
    // A copy of the engine under a name of its own (at most 16 characters, the kernel's command
    // name), so that engines started by tests running in parallel are not counted.
    let name = "ps4rc-" + UUID().uuidString.prefix(8).lowercased()
    let copy = tmp.appending(path: name)
    try fm.copyItem(at: exe, to: copy)
    try SFOBuilder.build([
        ("TITLE_ID", .string("CUSA00557")), ("TITLE", .string("Synthetic")),
        ("APP_VER", .string("01.00")), ("CATEGORY", .string("gd")),
    ]).write(to: content.appending(path: "sce_sys/param.sfo"))
    // eboot.bin is a FIFO that nobody writes: the analysis blocks reading it until the cancel.
    let eboot = content.appending(path: "eboot.bin")
    try #require(mkfifo(eboot.path, 0o600) == 0)

    let started = LibraryTests.Flag(), ended = LibraryTests.Flag()
    let engine = ProcessEngine(executable: copy)
    let task = Task {
        defer { ended.set() }
        return try await engine.analyze(content: content, log: tmp.appending(path: "analyze.log")) { ev in
            if ev.event == .progress { started.set() }
        }
    }
    // Should the cancel not stop the engine, a writer that opens and closes the FIFO ends its
    // read (EOF) after 30 s, so the test fails instead of hanging.
    let path = eboot.path
    let watchdog = Task.detached {
        try await Task.sleep(for: .seconds(30))
        if !ended.isSet { let fd = open(path, O_WRONLY | O_NONBLOCK); if fd >= 0 { close(fd) } }
    }
    defer { watchdog.cancel() }
    let deadline = ContinuousClock.now + .seconds(20)
    while !started.isSet && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    try #require(started.isSet, "the engine reported no progress")
    try await Task.sleep(for: .milliseconds(200))
    #expect(children(named: name).count == 1)
    #expect(!ended.isSet)

    task.cancel()
    do {
        _ = try await task.value
        Issue.record("the analysis was not cancelled")
    } catch let failure as EngineFailure {
        #expect(failure == EngineFailure(code: "cancelled", message: "cancelled"))
    }
    #expect(children(named: name).isEmpty)
}
