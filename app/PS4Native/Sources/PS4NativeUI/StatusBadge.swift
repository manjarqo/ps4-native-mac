// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// A game's support status as a small coloured capsule: OK, WIP, VER, EXP or ? (not analysed).
public struct StatusBadge: View {
    public let status: String

    public init(status: String) {
        self.status = status
    }

    public var body: some View {
        Text(Self.label(status))
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(Self.color(status))
            .background(Self.color(status).opacity(0.22), in: Capsule())
            .help(Self.name(status))
    }

    static func label(_ status: String) -> String {
        switch status {
        case "playable": "OK"
        case "in_progress": "WIP"
        case "other_version": "VER"
        case "experimental": "EXP"
        default: "?"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "playable": .green
        case "in_progress": .yellow
        case "other_version": .orange
        case "experimental": .purple
        default: .gray
        }
    }

    /// The status written out, as the hero shows it.
    static func name(_ status: String) -> String {
        switch status {
        case "playable": "Playable"
        case "in_progress": "In progress"
        case "other_version": "Other version"
        case "experimental": "Experimental"
        case "": "Not analysed"
        default: Format.sentence(status.replacingOccurrences(of: "_", with: " "))
        }
    }
}
