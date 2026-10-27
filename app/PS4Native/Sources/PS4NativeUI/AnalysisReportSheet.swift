// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The analysis report an `experimental` game shows before its build: coverage, unresolved
/// imports, missing operations and modules, with "Build anyway".
struct AnalysisReportSheet: View {
    let game: GameRecord
    let analysis: GameAnalysis?
    let buildAnyway: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(game.title.isEmpty ? game.titleID : game.title) is not in the compatibility list")
                .font(.headline)
            Text("Nobody has tested this game yet. The analysis of its eboot.bin is below; the build may fail, or the game may not run.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let analysis {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                    row("Code coverage", analysis.coverage.formatted(.number.precision(.fractionLength(2))) + " %")
                    row("Unresolved imports", "\(analysis.unresolved)")
                    row("Missing operations", "\(analysis.missingOps)")
                    row("Modules", (analysis.modules ?? []).isEmpty ? "None" : (analysis.modules ?? []).joined(separator: ", "))
                }
            } else {
                Text("No analysis report is stored for this game; use Analyze again in the ⋯ menu to make one.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Build anyway") {
                    dismiss()
                    buildAnyway()
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
