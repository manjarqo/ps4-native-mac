// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// "Remove <title>? This frees <size>." with Keep saves (on by default).
public struct UninstallSheet: View {
    @Bindable var model: AppModel
    let game: GameRecord
    @Environment(\.dismiss) private var dismiss
    @State private var keepSaves = true
    @State private var bytes: Int64?
    @State private var removing = false

    public init(model: AppModel, game: GameRecord) {
        self.model = model
        self.game = game
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove \(game.title.isEmpty ? game.titleID : game.title)?").font(.title2.bold())
            Text(bytes.map { "This frees \(Format.bytes($0))." } ?? "Measuring…")
            Toggle("Keep saves", isOn: $keepSaves)
            Text(keepSaves ? "The saves stay, for a later import of the game."
                           : "The saves go to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
            if model.isBusy(game.titleID) && !removing {
                Label("Stop the game, or wait for its operations to finish.", systemImage: "hourglass")
                    .foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) { remove() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(removing || model.isBusy(game.titleID))
            }
        }
        .padding(24)
        .frame(width: 440)
        .preferredColorScheme(.dark)
        .task { bytes = await model.measureGameDir(game.titleID) }
    }

    private func remove() {
        removing = true
        let id = game.titleID, keep = keepSaves
        Task {
            do {
                _ = try await model.uninstall(id, keepSaves: keep)
            } catch {
                model.report(error)
            }
            dismiss()
        }
    }
}
