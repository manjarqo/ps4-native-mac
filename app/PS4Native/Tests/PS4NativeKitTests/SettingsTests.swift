// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

@Suite struct SettingsTests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ps4n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func defaultsWithoutFile() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let s = GameSettings.load(titleID: "CUSA00557", settingsDir: d)
        #expect(s == GameSettings(lang: nil, pro: true, upscale: false, hud: true, metal: nil))
        #expect(s.extraLines.isEmpty)
    }

    @Test func roundTripKeepsUnknownLines() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        let s = GameSettings(lang: 8, pro: false, upscale: true, hud: false, metal: 3, extraLines: ["foo=1"])
        try s.save(titleID: "CUSA00557", settingsDir: d)
        #expect(GameSettings.load(titleID: "CUSA00557", settingsDir: d) == s)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: d.path)
        #expect(leftovers == ["CUSA00557.cfg"])
    }

    @Test func exactFileText() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        try GameSettings(lang: 8, pro: false, upscale: true, hud: true, metal: 4)
            .save(titleID: "CUSA00557", settingsDir: d)
        let text = try String(contentsOf: d.appendingPathComponent("CUSA00557.cfg"), encoding: .utf8)
        #expect(text == "lang=8\npro=0\nupscale=1\nhud=1\nmetal=4\n")
    }

    @Test func nilLangWritesNoLangLine() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        try GameSettings().save(titleID: "CUSA00001", settingsDir: d)
        let text = try String(contentsOf: d.appendingPathComponent("CUSA00001.cfg"), encoding: .utf8)
        #expect(text == "pro=1\nupscale=0\nhud=1\n")
    }

    @Test func runtimeNegativeLangMeansDefault() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        try "lang=-1\npro=0\n".write(to: d.appendingPathComponent("CUSA00001.cfg"), atomically: true, encoding: .utf8)
        let s = GameSettings.load(titleID: "CUSA00001", settingsDir: d)
        #expect(s.lang == nil)
        #expect(s.pro == false)
    }

    @Test func launchEnvironment() {
        #expect(GameSettings().launchEnvironment == ["PS4_NO_DIALOGS": "1"])
        #expect(GameSettings(metal: 3).launchEnvironment == ["PS4_NO_DIALOGS": "1", "PS4_GNM_METAL": "3"])
    }

    @Test func applyingRecommended() {
        let s = GameSettings(lang: 8, pro: true, upscale: false, hud: true).applying(recommended: ["pro": 0, "upscale": 1])
        #expect(s == GameSettings(lang: 8, pro: false, upscale: true, hud: true))
    }

    @Test func languageTable() {
        #expect(Languages.all.count == 20)
        #expect(Languages.all.first { $0.code == "pt-br" }?.pack == "brazilian")
        #expect(Languages.all.first { $0.orbis == 21 }?.code == "ar")
    }

    @Test func availableLanguages() throws {
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        #expect(Languages.available(content: d).map(\.code) == ["en"])
        let speech = d.appendingPathComponent("build/ps4/main/sound1/streams/speech")
        try FileManager.default.createDirectory(at: speech.appendingPathComponent("french"), withIntermediateDirectories: true)
        try Data().write(to: speech.appendingPathComponent("russian-sp.psarc"))
        #expect(Languages.available(content: d).map(\.code) == ["fr", "ru"])
    }

    @Test func titleIDValidation() throws {
        #expect(TitleID.isValid("CUSA00557"))
        for bad in ["", "cusa00557", "CUSA0055", "CUSA005577", "../CUSA0055", "CUSA0055/", "CUSA0055\u{660}"] {
            #expect(!TitleID.isValid(bad))
        }
        let d = try tempDir()
        defer { try? FileManager.default.removeItem(at: d) }
        #expect(throws: GameSettingsError.self) { try GameSettings().save(titleID: "../x", settingsDir: d) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: d.path).isEmpty)
        #expect(GameSettings.load(titleID: "", settingsDir: d) == GameSettings())
    }
}
