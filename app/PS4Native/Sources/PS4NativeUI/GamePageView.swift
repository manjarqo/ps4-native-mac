// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The tabs of a game page.
enum GameTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case settings = "Settings"
    case saves = "Saves"
    case dlc = "DLC & updates"
    case buildLog = "Build log"

    var id: Self { self }
}

/// A game's page: the hero, the action bar, its banners and the tabs.
public struct GamePageView: View {
    @Bindable var model: AppModel
    let game: GameRecord
    @State private var tab: GameTab = .overview
    @State private var confirmUninstall = false
    /// The confirmation of an `other_version` build, naming the tested versions.
    @State private var versionWarning: String?
    /// The analysis report an `experimental` build opens first; its analysis is nil when none is stored.
    @State private var report: ReportRequest?

    public init(model: AppModel, game: GameRecord) {
        self.model = model
        self.game = game
    }

    public var body: some View {
        VStack(spacing: 0) {
            GameHeroView(model: model, game: game)
            GameActionBar(model: model, game: game, tab: $tab, build: requestBuild) { confirmUninstall = true }
            banners
            Picker("Tab", selection: $tab) {
                ForEach(GameTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.08, green: 0.09, blue: 0.11))
        .sheet(isPresented: $confirmUninstall) {
            UninstallSheet(model: model, game: game)
        }
        .sheet(item: $report) { request in
            AnalysisReportSheet(game: game, analysis: request.analysis) { buildConfirmed() }
        }
        .alert("Build an untested version?", isPresented: Binding(get: { versionWarning != nil }, set: { if !$0 { versionWarning = nil } })) {
            Button("Build") { buildConfirmed() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(versionWarning ?? "")
        }
    }

    /// Build or Rebuild: starts the build, or first asks what the game's status requires.
    private func requestBuild() {
        let id = game.titleID
        switch model.buildGate(game) {
        case .none:
            do { try model.build(id) } catch { model.report(error) }
        case .refused:
            model.report(AppError.cannotBuild(id))
        case .confirmVersion:
            Task {
                let tested = await model.loadAnalysis(id)?.verdict.testedVersions ?? []
                versionWarning = AppModel.otherVersionWarning(game, tested: tested)
            }
        case .analysisReport:
            Task { report = ReportRequest(analysis: await model.loadAnalysis(id)) }
        }
    }

    private func buildConfirmed() {
        do { try model.build(game.titleID, confirmed: true) } catch { model.report(error) }
    }

    @ViewBuilder private var banners: some View {
        if let offer = model.rebuildOffer(game) {
            Banner(symbol: "arrow.triangle.2.circlepath", text: offer, tint: .blue, action: "Rebuild", perform: requestBuild)
                .disabled(model.isBusy(game.titleID) || model.buildGate(game) == .refused)
        }
        if let log = model.lastCrashLog[game.titleID] {
            Banner(symbol: "exclamationmark.triangle.fill", text: "The game quit unexpectedly", tint: .orange,
                   action: "Open log", dismiss: { model.dismissCrash(game.titleID) }) { Panels.open(log) }
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview: OverviewTab(model: model, game: game)
        case .settings: SettingsTab(model: model, titleID: game.titleID)
        case .saves:
            ScrollView { SavesTab(model: model, titleID: game.titleID).padding(20) }
        case .dlc: DLCTab(model: model, game: game)
        case .buildLog: BuildLogTab(model: model, titleID: game.titleID)
        }
    }
}

/// A one-line notice under the action bar, with a button.
struct Banner: View {
    let symbol: String
    let text: String
    let tint: Color
    let action: String
    /// Shows a close button when set.
    var dismiss: (() -> Void)? = nil
    let perform: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
            Spacer()
            Button(action, action: perform)
            if let dismiss {
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }
}

/// The analysis an `experimental` build shows first.
struct ReportRequest: Identifiable {
    let id = UUID()
    let analysis: GameAnalysis?
}
