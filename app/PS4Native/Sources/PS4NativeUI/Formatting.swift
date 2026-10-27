// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PS4NativeKit

/// How the views write sizes, versions, times and the names of the engine's values.
enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    /// "01.05" as "v1.05" (`GameVersion.display`).
    static func version(_ v: String) -> String { GameVersion.display(v) }

    /// Play time such as "3 hr, 12 min".
    static func playTime(_ seconds: Int64) -> String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// The session clock: "12:34", or "1:02:03" after an hour.
    static func session(_ seconds: TimeInterval) -> String {
        let d = Duration.seconds(max(0, Int64(seconds)))
        return d.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// library.json's ISO-8601 `last_played`, relative to now; "Never" when it is unset.
    static func lastPlayed(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }

    static func date(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    /// The renderer setting: nil is automatic.
    static func renderer(_ metal: Int?) -> String {
        metal.map { "Metal \($0)" } ?? "Automatic"
    }

    /// An inspected item's kind as the add sheet names it.
    static func kind(_ kind: String?) -> String {
        switch kind {
        case "game": "Game"
        case "patch": "Update"
        case "dlc": "DLC"
        case "folder": "Folder"
        default: "Unknown"
        }
    }

    static func kind(_ kind: OperationItem.Kind) -> String {
        switch kind {
        case .importGame: "Import"
        case .analyze: "Analysis"
        case .build: "Build"
        }
    }

    /// A model message as a sentence: its first letter capitalised.
    static func sentence(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
