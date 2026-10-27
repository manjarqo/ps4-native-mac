// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The title ID rule shared with the library and the engine: four capital letters and five digits.
/// Checked before an ID becomes part of any path.
public enum TitleID {
    public static func isValid(_ id: String) -> Bool {
        let b = Array(id.utf8)
        return b.count == 9 && b[..<4].allSatisfy { $0 >= 65 && $0 <= 90 } && b[4...].allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

public enum GameSettingsError: Error, Equatable, Sendable {
    case invalidTitleID(String)
}

/// Per-game settings in `<settingsDir>/<TITLE_ID>.cfg`, the file the runtime reads (ps4_settings.m).
public struct GameSettings: Sendable, Equatable {
    /// Orbis language code; nil means the system default.
    public var lang: Int?
    public var pro: Bool
    public var upscale: Bool
    public var hud: Bool
    /// Renderer backend: 3, 4, or nil for automatic.
    public var metal: Int?
    /// `key=value` lines this app does not know, kept as they were.
    public var extraLines: [String]

    public init(lang: Int? = nil, pro: Bool = true, upscale: Bool = false, hud: Bool = true,
                metal: Int? = nil, extraLines: [String] = []) {
        self.lang = lang
        self.pro = pro
        self.upscale = upscale
        self.hud = hud
        self.metal = metal
        self.extraLines = extraLines
    }

    static func fileURL(titleID: String, settingsDir: URL) -> URL {
        settingsDir.appendingPathComponent("\(titleID).cfg")
    }

    /// Reads the file; a missing or unreadable one gives the defaults.
    public static func load(titleID: String, settingsDir: URL) -> GameSettings {
        var s = GameSettings()
        guard TitleID.isValid(titleID),
              let text = try? String(contentsOf: fileURL(titleID: titleID, settingsDir: settingsDir), encoding: .utf8)
        else { return s }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            let value = Int(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces))
            switch (key, value) {
            case ("lang", let v?): s.lang = v < 0 ? nil : v
            case ("pro", let v?): s.pro = v != 0
            case ("upscale", let v?): s.upscale = v != 0
            case ("hud", let v?): s.hud = v != 0
            case ("metal", let v?): s.metal = (v == 3 || v == 4) ? v : nil
            case ("lang", nil), ("pro", nil), ("upscale", nil), ("hud", nil), ("metal", nil): break
            default: s.extraLines.append(line)
            }
        }
        return s
    }

    var fileText: String {
        var t = ""
        if let lang { t += "lang=\(lang)\n" }
        t += "pro=\(pro ? 1 : 0)\nupscale=\(upscale ? 1 : 0)\nhud=\(hud ? 1 : 0)\n"
        if let metal { t += "metal=\(metal)\n" }
        for l in extraLines { t += l + "\n" }
        return t
    }

    /// Writes atomically: a temp file in the same directory, then a rename.
    public func save(titleID: String, settingsDir: URL) throws {
        guard TitleID.isValid(titleID) else { throw GameSettingsError.invalidTitleID(titleID) }
        let fm = FileManager.default
        try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let dest = Self.fileURL(titleID: titleID, settingsDir: settingsDir)
        let tmp = settingsDir.appendingPathComponent(".\(titleID).cfg.\(UUID().uuidString).tmp")
        try Data(fileText.utf8).write(to: tmp)
        do {
            _ = try fm.replaceItemAt(dest, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }

    /// Environment for the engine's launch: no dialogs, and the backend when chosen.
    public var launchEnvironment: [String: String] {
        var env = ["PS4_NO_DIALOGS": "1"]
        if let metal { env["PS4_GNM_METAL"] = String(metal) }
        return env
    }

    /// The settings with the compat verdict's recommended values (`pro`, `upscale`, `hud`, `lang`, `metal`) applied.
    public func applying(recommended: [String: Int]) -> GameSettings {
        var s = self
        if let v = recommended["pro"] { s.pro = v != 0 }
        if let v = recommended["upscale"] { s.upscale = v != 0 }
        if let v = recommended["hud"] { s.hud = v != 0 }
        if let v = recommended["lang"] { s.lang = v < 0 ? nil : v }
        if let v = recommended["metal"] { s.metal = (v == 3 || v == 4) ? v : nil }
        return s
    }
}
