// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

@Suite struct SFOTests {
    @Test func roundTrip() throws {
        let data = SFOBuilder.build([
            ("TITLE_ID", .string("CUSA00552")),
            ("TITLE", .string("Joel’s Game")),
            ("APP_VER", .string("01.09")),
            ("CATEGORY", .string("gd")),
            ("PARENTAL_LEVEL", .int(5)),
        ])
        let sfo = try SFO(data: data)
        #expect(sfo.titleID == "CUSA00552")
        #expect(sfo.title == "Joel’s Game")
        #expect(sfo.appVersion == "01.09")
        #expect(sfo.category == "gd")
        #expect(sfo.int("PARENTAL_LEVEL") == 5)
        #expect(sfo.string("PARENTAL_LEVEL") == nil)
        #expect(sfo.int("TITLE") == nil)
    }

    @Test func appVersionFallsBackToVersion() throws {
        let missing = try SFO(data: SFOBuilder.build([("VERSION", .string("01.00"))]))
        #expect(missing.appVersion == "01.00")
        let empty = try SFO(data: SFOBuilder.build([("APP_VER", .string("")), ("VERSION", .string("01.00"))]))
        #expect(empty.appVersion == "01.00")
        #expect(try SFO(data: SFOBuilder.build([("TITLE", .string("x"))])).appVersion == nil)
    }

    @Test func badMagicAndTruncation() throws {
        #expect(throws: SFOError.badMagic) { try SFO(data: Data(repeating: 0xFF, count: 64)) }
        #expect(throws: SFOError.badMagic) { try SFO(data: Data()) }
        let good = SFOBuilder.build([("TITLE", .string("Hello world"))])
        #expect(throws: SFOError.truncated) { try SFO(data: good.prefix(good.count - 8)) }
        #expect(throws: SFOError.truncated) { try SFO(data: good.prefix(24)) }
    }

    @Test func saveParam() throws {
        var buf = [UInt8](repeating: 0, count: 1328)
        func put(_ s: String, at o: Int) { for (i, c) in s.utf8.enumerated() { buf[o + i] = c } }
        put("Joel", at: 0)
        put("Chapter 3", at: 128)
        put("Winter", at: 256)
        let t: Int64 = 1_760_000_000
        for i in 0..<8 { buf[1288 + i] = UInt8((t >> (8 * Int64(i))) & 0xFF) }
        let p = try SaveParam(data: Data(buf))
        #expect(p.title == "Joel")
        #expect(p.subtitle == "Chapter 3")
        #expect(p.detail == "Winter")
        #expect(p.modified == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(try SaveParam(data: Data(repeating: 0, count: 1328)).modified == nil)
        #expect(throws: SFOError.truncated) { try SaveParam(data: Data(count: 100)) }
    }

    @Test func pathsDefaults() {
        let p = Paths(environment: ["HOME": "/home/fake"], bundle: .main)
        #expect(p.libraryRoot.path == "/home/fake/Library/Application Support/PS4Native")
        #expect(p.dataDir.path == "/home/fake/Library/Application Support/PS4Recomp")
        #expect(p.savesDir.path == "/home/fake/Library/Application Support/PS4Recomp/saves")
        #expect(p.settingsDir.path == "/home/fake/Library/Application Support/PS4Recomp/settings")
        #expect(p.engineKit.lastPathComponent == "engine")
        #expect(p.engineExecutable.lastPathComponent == "ps4-recomp")
        #expect(p.engineExecutable.deletingLastPathComponent().path == p.engineKit.path)
    }

    @Test func pathsOverrides() {
        let p = Paths(environment: [
            "HOME": "/home/fake", "PS4NATIVE_LIBRARY": "/lib", "PS4RECOMP_DATA_DIR": "/data",
            "PS4NATIVE_ENGINE": "/eng",
        ], bundle: .main)
        #expect(p.libraryRoot.path == "/lib")
        #expect(p.dataDir.path == "/data")
        #expect(p.savesDir.path == "/data/saves")
        #expect(p.settingsDir.path == "/data/settings")
        #expect(p.engineExecutable.path == "/eng/ps4-recomp")
        let s = Paths(environment: ["PS4RECOMP_DATA_DIR": "/data", "PS4_SAVEDATA_DIR": "/sv"], bundle: .main)
        #expect(s.savesDir.path == "/sv")
    }
}
