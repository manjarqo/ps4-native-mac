// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Synchronization
import Testing
@testable import PS4NativeKit

@Suite struct LibraryTests {
    /// A flag shared with a task.
    final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// A fresh temp directory removed by `cleanup`.
    func makeTemp(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ps4n-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cleanup(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    func readJSON(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    let sample = #"""
        {"version":1,"x_top":1,"games":[{"title_id":"CUSA00557","content_id":"EP9000-CUSA00557_00-THELASTOFUS00000",
        "title":"The Last of Us","app_ver":"01.00","version":"01.00","patches":[],"dlc":["PROMOJOELSKIN001"],
        "content_bytes":123,"status":"","built_with":"","last_played":"","play_seconds":7,"x_game":{"a":[1,2]}}]}
        """#

    @Test func roundTripKeepsUnknownFields() async throws {
        let root = try makeTemp("lib")
        defer { cleanup(root) }
        let file = root.appendingPathComponent("library.json")
        try Data(sample.utf8).write(to: file)
        let store = LibraryStore(root: root)
        try await store.update { $0.games[0].status = "playable" }

        let top = try readJSON(file)
        #expect(top["x_top"] as? Int == 1)
        #expect(top["version"] as? Int == 1)
        let games = try #require(top["games"] as? [[String: Any]])
        #expect(games.count == 1)
        #expect(games[0]["status"] as? String == "playable")
        #expect(games[0]["content_bytes"] as? Int == 123)
        #expect(games[0]["dlc"] as? [String] == ["PROMOJOELSKIN001"])
        let xGame = try #require(games[0]["x_game"] as? [String: Any])
        #expect(xGame["a"] as? [Int] == [1, 2])
        let left = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(left == [".lock", "library.json"])

        let snap = try store.snapshot()
        #expect(snap.version == 1)
        #expect(snap.extra["x_top"] == .number(1))
        #expect(snap.games.map(\.id) == ["CUSA00557"])
        #expect(snap.games[0].extra["x_game"] == .object(["a": .array([.number(1), .number(2)])]))
        #expect(snap.games[0].playSeconds == 7)
    }

    @Test func knownKeyWinsOverExtra() throws {
        var g = try JSONDecoder().decode(GameRecord.self, from: Data(#"{"title_id":"CUSA00557","status":"playable"}"#.utf8))
        g.extra["status"] = .string("stale")
        g.extra["x"] = .bool(true)
        let back = try JSONDecoder().decode(GameRecord.self, from: JSONEncoder().encode(g))
        #expect(back.status == "playable")
        #expect(back.extra == ["x": .bool(true)])
    }

    @Test func newerVersionIsRefusedAndUntouched() async throws {
        let root = try makeTemp("lib")
        defer { cleanup(root) }
        let file = root.appendingPathComponent("library.json")
        let bytes = Data(#"{"version":2,"games":[{"title_id":"CUSA00557"}]}"#.utf8)
        try bytes.write(to: file)
        let store = LibraryStore(root: root)
        await #expect(throws: LibraryError.newerVersion(2)) { try await store.update { $0.games.removeAll() } }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(throws: LibraryError.newerVersion(2)) { _ = try store.snapshot() }
        await #expect(throws: LibraryError.newerVersion(2)) { _ = try await store.uninstall(titleID: "CUSA00557") }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func nullArraysAndMissingVersion() throws {
        let f = try JSONDecoder().decode(LibraryFile.self, from: Data(
            #"{"games":[{"title_id":"CUSA00557","patches":null,"dlc":null}]}"#.utf8))
        #expect(f.version == 1)
        #expect(f.games[0].patches == [])
        #expect(f.games[0].dlc == [])
        #expect(f.games[0].extra.isEmpty)
    }

    @Test func missingFileIsEmpty() throws {
        let root = try makeTemp("lib")
        defer { cleanup(root) }
        let snap = try LibraryStore(root: root.appendingPathComponent("none")).snapshot()
        #expect(snap.games.isEmpty && snap.version == 1)
    }

    @Test func lockExcludesAnotherHolder() async throws {
        let root = try makeTemp("lib")
        defer { cleanup(root) }
        let store = LibraryStore(root: root)
        let lock = try await FileLock.acquire(root.appendingPathComponent(".lock"))
        let finished = Flag()
        let task = Task {
            try await store.update { $0.extra["x"] = .string("y") }
            finished.set()
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!finished.isSet)
        lock.release()
        try await task.value
        #expect(finished.isSet)
        #expect(try store.snapshot().extra["x"] == .string("y"))
    }

    @Test func cancellingAWaitingUpdateThrows() async throws {
        let root = try makeTemp("lib")
        defer { cleanup(root) }
        let store = LibraryStore(root: root)
        let lock = try await FileLock.acquire(root.appendingPathComponent(".lock"))
        defer { lock.release() }
        let task = Task { try await store.update { $0.extra["x"] = .null } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }

    @Test func engineWaitsForTheAppLock() async throws {
        let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../..").standardized
        let exe = repo.appending(path: "ps4-recomp"), elf = repo.appending(path: "hello_world.elf")
        try #require(FileManager.default.isExecutableFile(atPath: exe.path), "build ps4-recomp in the repo root first")
        try #require(FileManager.default.fileExists(atPath: elf.path), "hello_world.elf is missing from the repo root")

        let tmp = try makeTemp("interop")
        defer { cleanup(tmp) }
        let src = tmp.appendingPathComponent("src", isDirectory: true), root = tmp.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("sce_sys"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: elf, to: src.appendingPathComponent("eboot.bin"))
        try SFOBuilder.build([
            ("TITLE_ID", .string("CUSA00557")),
            ("CONTENT_ID", .string("EP9000-CUSA00557_00-THELASTOFUS00000")),
            ("TITLE", .string("Synthetic")),
            ("APP_VER", .string("01.00")),
            ("VERSION", .string("01.00")),
            ("CATEGORY", .string("gd")),
        ]).write(to: src.appendingPathComponent("sce_sys/param.sfo"))

        // A file written by the app, which the engine must read and keep the unknown field of.
        let store = LibraryStore(root: root)
        try await store.update { $0.extra["x_app"] = .string("kept") }

        let lock = try await FileLock.acquire(root.appendingPathComponent(".lock"))
        let sawLock = Flag(), finished = Flag()
        let engine = ProcessEngine(executable: exe)
        let task = Task {
            let r = try await engine.importGame(src, library: root, mode: .reference, log: nil) { ev in
                if ev.event == .progress && ev.stage == "lock" { sawLock.set() }
            }
            finished.set()
            return r
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while !sawLock.isSet && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(sawLock.isSet)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!finished.isSet)
        lock.release()
        let result = try await task.value
        let game = try #require(try result.gameRecord)
        #expect(game.titleID == "CUSA00557" && game.title == "Synthetic")
        let after = try store.snapshot()
        #expect(after.games.map(\.id) == ["CUSA00557"])
        #expect(after.extra["x_app"] == .string("kept"))
        let content = try store.contentDir(titleID: "CUSA00557")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: content.path).hasSuffix("/src"))
    }

    @Test func uninstallUnlinksAReferencedContent() async throws {
        let tmp = try makeTemp("uninstall")
        defer { cleanup(tmp) }
        let root = tmp.appendingPathComponent("lib", isDirectory: true)
        let target = tmp.appendingPathComponent("folder", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: target.appendingPathComponent("eboot.bin"))
        let store = LibraryStore(root: root)
        let game = try store.gameDir(titleID: "CUSA00557")
        try fm.createDirectory(at: try store.buildDir(titleID: "CUSA00557").appendingPathComponent("Game.app"),
                               withIntermediateDirectories: true)
        try Data(count: 1000).write(to: try store.buildDir(titleID: "CUSA00557").appendingPathComponent("Game.app/bin"))
        try fm.createSymbolicLink(at: try store.contentDir(titleID: "CUSA00557"), withDestinationURL: target)
        // The DLC of the game used in place, kept in the library next to content/.
        let dlc = try store.referencedAddcontDir(titleID: "CUSA00557").appendingPathComponent("PROMOJOELSKIN001")
        try fm.createDirectory(at: dlc, withIntermediateDirectories: true)
        try Data(count: 500).write(to: dlc.appendingPathComponent("dlc.dat"))
        let pending = root.appendingPathComponent("pending", isDirectory: true)
        try fm.createDirectory(at: pending.appendingPathComponent("CUSA00557"), withIntermediateDirectories: true)
        try Data(#"{"app_ver":"01.09"}"#.utf8).write(to: pending.appendingPathComponent("CUSA00557.json"))
        try Data(sample.utf8).write(to: root.appendingPathComponent("library.json"))
        #expect(try store.appBundle(titleID: "CUSA00557")?.lastPathComponent == "Game.app")

        let freed = try await store.uninstall(titleID: "CUSA00557")
        #expect(freed >= 1500)
        #expect(try store.snapshot().games.isEmpty)
        #expect(try store.snapshot().extra["x_top"] == .number(1))
        #expect(!fm.fileExists(atPath: game.path))
        #expect(!fm.fileExists(atPath: pending.appendingPathComponent("CUSA00557").path))
        #expect(!fm.fileExists(atPath: pending.appendingPathComponent("CUSA00557.json").path))
        #expect(try String(contentsOf: target.appendingPathComponent("eboot.bin"), encoding: .utf8) == "keep me")
        #expect(try store.appBundle(titleID: "CUSA00557") == nil)
    }

    @Test func launchAddcontDirOnlyForAGameUsedInPlaceWithDLC() throws {
        let tmp = try makeTemp("addcont")
        defer { cleanup(tmp) }
        let fm = FileManager.default
        let store = LibraryStore(root: tmp.appendingPathComponent("lib", isDirectory: true))
        let folder = tmp.appendingPathComponent("folder", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let inPlace = "CUSA00557", copied = "CUSA04529", missing = "CUSA00552"
        try fm.createDirectory(at: try store.gameDir(titleID: inPlace), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: try store.contentDir(titleID: inPlace), withDestinationURL: folder)
        // A copied game: content/ is a directory (with its own addcont/, which the runtime scans).
        try fm.createDirectory(at: try store.contentDir(titleID: copied).appendingPathComponent("addcont/X"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: try store.referencedAddcontDir(titleID: copied), withIntermediateDirectories: true)

        #expect(try store.isUsedInPlace(titleID: inPlace))
        #expect(try !store.isUsedInPlace(titleID: copied) && !store.isUsedInPlace(titleID: missing))
        #expect(try store.launchAddcontDir(titleID: inPlace) == nil) // no DLC yet
        let dlc = try store.referencedAddcontDir(titleID: inPlace)
        #expect(dlc.path == store.root.path + "/games/CUSA00557/addcont")
        try fm.createDirectory(at: dlc.appendingPathComponent("PROMOJOELSKIN001"), withIntermediateDirectories: true)
        #expect(try store.launchAddcontDir(titleID: inPlace) == dlc)
        #expect(try store.launchAddcontDir(titleID: copied) == nil)
        #expect(try store.launchAddcontDir(titleID: missing) == nil)
    }

    @Test func badTitleIDIsRefused() async throws {
        let root = try makeTemp("lib")
        defer { cleanup(root) }
        let store = LibraryStore(root: root)
        #expect(throws: LibraryError.badTitleID("../x")) { _ = try store.gameDir(titleID: "../x") }
        #expect(throws: LibraryError.badTitleID("../x")) { _ = try store.appBundle(titleID: "../x") }
        await #expect(throws: LibraryError.badTitleID("../x")) { _ = try await store.uninstall(titleID: "../x") }
    }

    @Test func importResultGameRecord() throws {
        let line = #"{"result":{"title_id":"CUSA00557","kind":"game","pending":false,"game":{"title_id":"CUSA00557","title":"T","patches":null,"dlc":null,"content_bytes":4096}}}"#
        struct Envelope: Decodable { let result: ImportResult }
        let r = try JSONDecoder().decode(Envelope.self, from: Data(line.utf8)).result
        let g = try #require(try r.gameRecord)
        #expect(g.titleID == "CUSA00557" && g.contentBytes == 4096 && g.patches.isEmpty)
        let pending = try JSONDecoder().decode(Envelope.self, from: Data(
            #"{"result":{"title_id":"CUSA00557","kind":"patch","pending":true}}"#.utf8)).result
        #expect(try pending.gameRecord == nil)
    }
}
