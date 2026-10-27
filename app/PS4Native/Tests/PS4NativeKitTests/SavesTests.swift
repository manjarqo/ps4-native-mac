// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

@Suite struct SavesTests {
    final class Trashed: @unchecked Sendable {
        let dir: URL
        init(_ dir: URL) { self.dir = dir }
        func move(_ u: URL) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: u, to: dir.appendingPathComponent(UUID().uuidString + "-" + u.lastPathComponent))
        }
    }

    struct Env {
        let root: URL, store: SaveStore, trash: URL, game: URL, slot: URL
    }

    func makeEnv() throws -> Env {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ps4n-saves-\(UUID().uuidString)")
        let saves = root.appendingPathComponent("saves"), trash = root.appendingPathComponent("trash")
        let game = saves.appendingPathComponent("A [CUSA00557]")
        let slot = game.appendingPathComponent("user_10000000/SAVEDATA01")
        try fm.createDirectory(at: slot.appendingPathComponent("sce_sys"), withIntermediateDirectories: true)
        var param = [UInt8](repeating: 0, count: 1328)
        Array("Joel".utf8).enumerated().forEach { param[$0.offset] = $0.element }
        try Data(param).write(to: slot.appendingPathComponent("sce_sys/param.bin"))
        try Data("one".utf8).write(to: slot.appendingPathComponent("USR-DATA"))
        let t = Trashed(trash)
        let store = SaveStore(savesDir: saves, backupsDir: root.appendingPathComponent("backups"), trash: { try t.move($0) })
        return Env(root: root, store: store, trash: trash, game: game, slot: slot)
    }

    @Test func slotsListed() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let slots = e.store.slots(titleID: "CUSA00557")
        #expect(slots.count == 1)
        #expect(slots[0].param?.title == "Joel")
        #expect(slots[0].user == "user_10000000")
        #expect(slots[0].name == "SAVEDATA01")
        #expect(slots[0].bytes == 1328 + 3)
        #expect(e.store.slots(titleID: "CUSA99999").isEmpty)
    }

    @Test func newestGameDirFirst() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let other = e.store.savesDir.appendingPathComponent("B [CUSA00557]")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: e.game.path)
        #expect(e.store.gameDirs(titleID: "CUSA00557").map(\.lastPathComponent) == ["B [CUSA00557]", "A [CUSA00557]"])
    }

    /// The runtime's rule (ps4_game_key.c): a name that is only " [<ID>]" is not a game
    /// directory, nor is a symlink; equal times put the greater name first.
    @Test func gameDirsMatchTheRuntime() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let fm = FileManager.default
        for name in ["B [CUSA00557]", " [CUSA00557]", "C [CUSA00557]"] {
            try fm.createDirectory(at: e.store.savesDir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: e.store.savesDir.appendingPathComponent("Z [CUSA00557]"), withDestinationURL: e.game)
        let same = Date(timeIntervalSince1970: 1_800_000_000)
        for name in ["A [CUSA00557]", "B [CUSA00557]", " [CUSA00557]", "C [CUSA00557]"] {
            try fm.setAttributes([.modificationDate: same], ofItemAtPath: e.store.savesDir.appendingPathComponent(name).path)
        }
        #expect(e.store.gameDirs(titleID: "CUSA00557").map(\.lastPathComponent) == ["C [CUSA00557]", "B [CUSA00557]", "A [CUSA00557]"])
        // A newer time still wins over a greater name.
        try fm.setAttributes([.modificationDate: same.addingTimeInterval(1)], ofItemAtPath: e.game.path)
        #expect(e.store.gameDirs(titleID: "CUSA00557").first?.lastPathComponent == "A [CUSA00557]")
    }

    @Test func backupRestoreAndDelete() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let zip = try e.store.backup(titleID: "CUSA00557")
        #expect(zip.pathExtension == "zip")
        #expect(FileManager.default.fileExists(atPath: zip.path))
        let usr = e.slot.appendingPathComponent("USR-DATA")
        try Data("two".utf8).write(to: usr)
        try e.store.restore(titleID: "CUSA00557", from: zip)
        #expect(try String(contentsOf: usr, encoding: .utf8) == "one")
        #expect(e.store.backups(titleID: "CUSA00557").count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.trash.path).count == 1)

        let slot = try #require(e.store.slots(titleID: "CUSA00557").first)
        try e.store.deleteSlot(slot)
        #expect(!FileManager.default.fileExists(atPath: slot.url.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.trash.path).count == 2)
    }

    @Test func exportAndFailure() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let out = e.root.appendingPathComponent("out.zip")
        try e.store.export(titleID: "CUSA00557", to: out)
        #expect(FileManager.default.fileExists(atPath: out.path))
        let bad = e.root.appendingPathComponent("missing.zip")
        #expect(throws: SaveError.self) { try e.store.restore(titleID: "CUSA00557", from: bad) }
    }

    func fileText(_ e: Env) throws -> String {
        try String(contentsOf: e.slot.appendingPathComponent("USR-DATA"), encoding: .utf8)
    }

    @Test func failedRestoreLeavesSaveIntact() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let corrupt = e.root.appendingPathComponent("corrupt.zip")
        try Data("not a zip".utf8).write(to: corrupt)
        for zip in [e.root.appendingPathComponent("missing.zip"), corrupt] {
            #expect(throws: SaveError.self) { try e.store.restore(titleID: "CUSA00557", from: zip) }
            #expect(try fileText(e) == "one")
        }
        #expect(e.store.backups(titleID: "CUSA00557").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: e.trash.path))
        let left = try FileManager.default.contentsOfDirectory(atPath: e.store.savesDir.path)
        #expect(left == ["A [CUSA00557]"])
    }

    @Test func wrongTitleZipRejected() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let other = e.store.savesDir.appendingPathComponent("B [CUSA00001]/user_1/SAVEDATA00")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let zip = e.root.appendingPathComponent("other.zip")
        try e.store.export(titleID: "CUSA00001", to: zip)
        #expect(throws: SaveError.self) { try e.store.restore(titleID: "CUSA00557", from: zip) }
        #expect(try fileText(e) == "one")
        #expect(e.store.backups(titleID: "CUSA00557").isEmpty)
    }

    @Test func arbitraryArchiveRejected() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let src = e.root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("A [CUSA00557]"), withIntermediateDirectories: true)
        try Data().write(to: src.appendingPathComponent("stray.txt"))
        let zip = e.root.appendingPathComponent("two.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", src.path, zip.path]
        try p.run(); p.waitUntilExit()
        // The archive holds one top-level entry (src contents under "src/" is absent with no --keepParent): two here.
        #expect(throws: SaveError.self) { try e.store.restore(titleID: "CUSA00557", from: zip) }
        #expect(try fileText(e) == "one")
    }

    @Test func restoredDirIsNewest() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let zip = try e.store.backup(titleID: "CUSA00557")
        try e.store.restore(titleID: "CUSA00557", from: zip)
        let dir = try #require(e.store.gameDirs(titleID: "CUSA00557").first)
        let m = try #require(try dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        #expect(abs(m.timeIntervalSinceNow) < 60)
    }

    @Test func invalidTitleIDRejected() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        #expect(e.store.gameDirs(titleID: "").isEmpty)
        #expect(e.store.slots(titleID: "").isEmpty)
        #expect(e.store.backups(titleID: "").isEmpty)
        #expect(throws: SaveError.invalidTitleID("")) { try e.store.backup(titleID: "") }
        #expect(throws: SaveError.invalidTitleID("../x")) { try e.store.restore(titleID: "../x", from: e.root) }
        #expect(throws: SaveError.invalidTitleID("x")) { try e.store.export(titleID: "x", to: e.root) }
    }

    @Test func deleteSlotRefusesOutsideSaves() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let outside = e.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let fake = SaveSlot(url: outside, user: "u", name: "n", param: nil, bytes: 0)
        #expect(throws: SaveError.self) { try e.store.deleteSlot(fake) }
        let sneaky = SaveSlot(url: e.store.savesDir.appendingPathComponent("../elsewhere"), user: "u", name: "n", param: nil, bytes: 0)
        #expect(throws: SaveError.self) { try e.store.deleteSlot(sneaky) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func failedExportRemovesPartialZip() throws {
        let e = try makeEnv()
        defer { try? FileManager.default.removeItem(at: e.root) }
        let file = e.root.appendingPathComponent("plain-file")
        try Data().write(to: file)
        let out = file.appendingPathComponent("out.zip") // a parent that is a file: ditto cannot write there
        #expect(throws: SaveError.self) { try e.store.export(titleID: "CUSA00557", to: out) }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }
}
