// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The library window: the sidebar of games and manager sections, and the selected page.
public struct RootView: View {
    @Bindable var model: AppModel
    @State private var manager: ManagerSection?

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: selection)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let urls = Panels.chooseAddItems()
                    if !urls.isEmpty { Task { await model.add(urls) } }
                } label: {
                    Label("Add game", systemImage: "plus")
                }
                .labelStyle(.titleAndIcon)
                .help("Add PKGs or game folders")
            }
            ToolbarItem(placement: .status) { queueIndicator }
        }
        .navigationTitle("PS4 Native — Library")
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            Task { await model.add(urls) }
            return true
        }
        .sheet(isPresented: Self.shown { !model.pendingCandidates.isEmpty && !model.firstRunNeeded }) {
            AddGameSheet(model: model)
        }
        .sheet(isPresented: Self.shown { model.firstRunNeeded }) {
            FirstRunView(model: model)
        }
        .alert("Something went wrong", isPresented: Self.shown { model.lastError != nil }, presenting: model.lastError) { _ in
            Button("OK") { model.dismissError() }
        } message: { message in
            Text(message)
        }
        .onChange(of: model.games.map(\.titleID), initial: true) { _, ids in
            if manager == nil, model.selection.map(ids.contains) != true { model.selection = ids.first }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .preferredColorScheme(.dark)
    }

    /// The model decides whether a sheet or alert shows; closing it goes through its own buttons.
    static func shown(_ condition: @escaping @MainActor @Sendable () -> Bool) -> Binding<Bool> {
        Binding(get: condition, set: { _ in })
    }

    private var selection: Binding<SidebarItem?> {
        Binding {
            manager.map(SidebarItem.manager) ?? model.selection.map(SidebarItem.game)
        } set: { item in
            switch item {
            case .game(let id)?:
                manager = nil
                model.selection = id
            case .manager(let section)?:
                manager = section
            case nil:
                manager = nil
                model.selection = nil
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch manager {
        case .queue?: QueueView(model: model)
        case .saves?: AllSavesView(model: model)
        case .settings?: AppSettingsView(model: model)
        case nil:
            if let game = model.games.first(where: { $0.titleID == model.selection }) {
                GamePageView(model: model, game: game).id(game.titleID)
            } else if model.games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Add a PKG or a dumped game folder with Add game, or drop it onto this window.")
                }
            } else {
                ContentUnavailableView("Select a game", systemImage: "sidebar.left")
            }
        }
    }

    /// A spinner and the number of operations queued or running, which opens the queue.
    @ViewBuilder private var queueIndicator: some View {
        let active = model.queue.items.filter { !$0.isFinished }.count
        if active > 0 {
            Button {
                manager = .queue
            } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(active)").monospacedDigit()
                }
            }
            .help("\(active) operation\(active == 1 ? "" : "s") queued or running")
        }
    }
}
