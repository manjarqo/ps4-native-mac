// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The app-wide pages under "Manager" in the sidebar.
public enum ManagerSection: Hashable, Sendable {
    case queue, saves, settings
}

/// A row of the sidebar: a game by TITLE_ID, or a manager page.
public enum SidebarItem: Hashable, Sendable {
    case game(String)
    case manager(ManagerSection)
}

/// The games with their icon and status, then the manager pages.
public struct SidebarView: View {
    @Bindable var model: AppModel
    @Binding var selection: SidebarItem?

    public init(model: AppModel, selection: Binding<SidebarItem?>) {
        self.model = model
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            Section("Games") {
                ForEach(model.games) { game in
                    GameRow(model: model, game: game).tag(SidebarItem.game(game.titleID))
                }
                if model.games.isEmpty {
                    Text("No games yet").foregroundStyle(.secondary)
                }
            }
            Section("Manager") {
                Label("Builds & imports", systemImage: "hammer").tag(SidebarItem.manager(.queue))
                Label("Saves", systemImage: "externaldrive").tag(SidebarItem.manager(.saves))
                Label("Settings", systemImage: "gearshape").tag(SidebarItem.manager(.settings))
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
    }
}

/// A game in the sidebar: its icon, its title and its status badge.
struct GameRow: View {
    let model: AppModel
    let game: GameRecord

    var body: some View {
        HStack(spacing: 8) {
            GameIcon(urls: [GameArt.sceSys(model, game.titleID, "icon0.png")].compactMap { $0 })
            Text(game.title.isEmpty ? game.titleID : game.title).lineLimit(1)
            Spacer(minLength: 4)
            StatusBadge(status: game.status)
        }
    }
}
