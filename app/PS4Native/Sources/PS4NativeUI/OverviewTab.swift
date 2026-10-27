// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// Play history, the renderer, the analysis's verdict and numbers, and the content size.
struct OverviewTab: View {
    @Bindable var model: AppModel
    let game: GameRecord
    @State private var settings: GameSettings?
    @State private var stored: GameAnalysis?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Last played", Format.lastPlayed(game.lastPlayed))
                    row("Play time", Format.playTime(game.playSeconds))
                    row("Renderer", settings.map(renderer) ?? "—")
                    row("Content size", Format.bytes(game.contentBytes))
                    if let analysis {
                        row("Code coverage", analysis.coverage.formatted(.number.precision(.fractionLength(2))) + " %")
                        row("Unresolved imports", "\(analysis.unresolved)")
                        row("Tested versions", list(analysis.verdict.testedVersions?.map(Format.version)))
                    }
                }
                if let analysis {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Known issues").font(.headline)
                        let issues = analysis.verdict.knownIssues ?? []
                        if issues.isEmpty {
                            Text("None known").foregroundStyle(.secondary)
                        } else {
                            ForEach(issues, id: \.self) { Label($0, systemImage: "exclamationmark.circle") }
                        }
                    }
                } else {
                    HStack {
                        Text("This game has not been analysed yet.").foregroundStyle(.secondary)
                        Button("Analyze") {
                            do { try model.analyze(game.titleID) } catch { model.report(error) }
                        }
                        .disabled(model.isBusy(game.titleID))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: game.titleID) {
            async let analysis = model.loadAnalysis(game.titleID)
            settings = await model.settings(for: game.titleID)
            stored = await analysis
        }
    }

    /// This session's analysis, else the stored one, read off the main actor.
    private var analysis: GameAnalysis? { model.analyses[game.titleID] ?? stored }

    private func renderer(_ s: GameSettings) -> String {
        Format.renderer(s.metal) + " · MetalFX " + (s.upscale ? "on" : "off")
    }

    private func list(_ items: [String]?) -> String {
        guard let items, !items.isEmpty else { return "—" }
        return items.joined(separator: ", ")
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
