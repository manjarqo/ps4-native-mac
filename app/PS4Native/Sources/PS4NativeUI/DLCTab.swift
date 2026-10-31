// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The installed version, the applied patches and the DLC, and the add flow for more.
struct DLCTab: View {
    @Bindable var model: AppModel
    let game: GameRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    GridRow {
                        Text("Installed version").foregroundStyle(.secondary)
                        Text(Format.version(game.appVer))
                    }
                }
                section("Updates", game.patches.map(Format.version), symbol: "arrow.down.circle", empty: "No updates applied")
                section("DLC", game.dlc, symbol: "shippingbox", empty: "No DLC installed")
                if model.usedInPlace.contains(game.titleID) {
                    Label("This game is used in place, so its folder is never changed: DLC is installed into the library next to it, but an update can be applied only to a copy. To update the game, add its folder again with \u{201C}Copy into the library\u{201D}.",
                          systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    let urls = Panels.chooseAddItems(message: "Choose a fake-signed update or DLC .pkg, or its folder.")
                    if !urls.isEmpty { Task { await model.add(urls) } }
                } label: {
                    Label("Add update or DLC…", systemImage: "plus")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, _ items: [String], symbol: String, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(items, id: \.self) { Label($0, systemImage: symbol).textSelection(.enabled) }
            }
        }
    }
}
