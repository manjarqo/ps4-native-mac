// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// A game's save slots, with backup, restore, export, import and delete. The save store's
/// work (ditto, the Trash) runs off the main actor.
public struct SavesTab: View {
    @Bindable var model: AppModel
    let titleID: String
    @State private var slots: [SaveSlot]?
    @State private var backups: [URL] = []
    @State private var deleting: SaveSlot?
    /// The zip a restore or import is waiting to be confirmed with.
    @State private var replacing: URL?
    @State private var working = false

    public init(model: AppModel, titleID: String) {
        self.init(model: model, titleID: titleID, confirming: nil)
    }

    /// Opens with the replace confirmation for `zip` showing, as choosing it in Restore… does;
    /// for previews and the window captures.
    init(model: AppModel, titleID: String, confirming zip: URL?) {
        self.model = model
        self.titleID = titleID
        _replacing = State(initialValue: zip)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbar
            if let slots, slots.isEmpty {
                Text("No saves yet").foregroundStyle(.secondary).padding(.vertical, 8)
            } else if let slots {
                VStack(spacing: 0) {
                    ForEach(slots) { slot in
                        row(slot)
                        if slot != slots.last { Divider() }
                    }
                }
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .confirmationDialog("Move this save slot to the Trash?", isPresented: Self.presenting($deleting), presenting: deleting) { slot in
            Button("Move to Trash", role: .destructive) {
                let store = model.saves
                run { try store.deleteSlot(slot) }
            }
        } message: { slot in
            Text("\(slot.param?.title ?? slot.name) (\(slot.name)) goes to the Trash.")
        }
        .confirmationDialog(replaceTitle, isPresented: Self.presenting($replacing), presenting: replacing) { zip in
            Button("Replace saves", role: .destructive) {
                let store = model.saves, id = titleID
                // The game may have started, or another save action begun, while the dialog was open.
                guard !locked else { model.report(AppError.busy(id)); return }
                run { try store.restore(titleID: id, from: zip) }
            }
        } message: { _ in
            Text("The current saves are backed up first and moved to the Trash.")
        }
        .task(id: titleID) { await reload() }
    }

    private var replaceTitle: String {
        let title = model.games.first { $0.titleID == titleID }?.title ?? titleID
        return "Replace the current saves of \(title) with \(replacing?.deletingPathExtension().lastPathComponent ?? "this archive")?"
    }

    /// The live save cannot change under a running game.
    private var locked: Bool { working || model.launcher.running[titleID] != nil }

    private var toolbar: some View {
        let store = model.saves, id = titleID
        return HStack(spacing: 8) {
            Button("Backup") { run { _ = try store.backup(titleID: id) } }
                .disabled(slots?.isEmpty != false)
            Menu("Restore…") {
                ForEach(backups, id: \.self) { zip in
                    Button(zip.deletingPathExtension().lastPathComponent) { replacing = zip }
                }
                if !backups.isEmpty { Divider() }
                Button("From a file…") {
                    if let zip = Panels.chooseZip(title: "Restore saves") { replacing = zip }
                }
            }
            .fixedSize()
            Button("Export…") {
                if let to = Panels.saveZip(name: "\(id)-saves.zip") { run { try store.export(titleID: id, to: to) } }
            }
            .disabled(slots?.isEmpty != false)
            Button("Import…") {
                if let zip = Panels.chooseZip(title: "Import saves") { replacing = zip }
            }
            if working { ProgressView().controlSize(.small) }
        }
        .disabled(locked)
    }

    private func row(_ slot: SaveSlot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(slot.param?.title ?? slot.name)
                Text(slot.param?.subtitle ?? slot.user).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(Format.date(slot.param?.modified)).foregroundStyle(.secondary)
            Text(Format.bytes(slot.bytes)).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .trailing)
            Button("Delete slot", role: .destructive) { deleting = slot }
                .disabled(locked)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func run(_ work: @escaping @Sendable () throws -> Void) {
        working = true
        Task {
            do {
                try await Task.detached(operation: work).value
            } catch {
                model.report(error)
            }
            await reload()
            working = false
        }
    }

    private func reload() async {
        let store = model.saves, id = titleID
        (slots, backups) = await Task.detached { (store.slots(titleID: id), store.backups(titleID: id)) }.value
    }

    static func presenting<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// Every game's saves, grouped by game: the manager's Saves page.
struct AllSavesView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Saves").font(.title2.bold())
                if model.games.isEmpty { Text("No games yet").foregroundStyle(.secondary) }
                ForEach(model.games) { game in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(game.title.isEmpty ? game.titleID : game.title).font(.headline)
                        SavesTab(model: model, titleID: game.titleID)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
