// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PS4NativeKit
import SwiftUI

/// The kinds of log a game has (logs/<stamp>-<kind>.log).
enum LogKind: String, CaseIterable, Identifiable {
    case build, run, analysis = "analyze"

    var id: Self { self }

    var label: String {
        switch self {
        case .build: "Build"
        case .run: "Run"
        case .analysis: "Analysis"
        }
    }
}

/// The game's newest log of the chosen kind (build, run or analysis), read again when one of
/// its operations or sessions starts or ends.
struct BuildLogTab: View {
    @Bindable var model: AppModel
    let titleID: String
    @State private var kind: LogKind = .build
    @State private var log: URL?
    @State private var text = ""

    /// How much of the end of a log is shown.
    nonisolated static let shownBytes = 256 << 10

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Log", selection: $kind) {
                    ForEach(LogKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(log?.lastPathComponent ?? "No \(kind.label.lowercased()) log yet").foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { if let log { Panels.reveal(log) } }
                    .disabled(log == nil)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
            }
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(20)
        .task(id: reloadKey) {
            log = model.latestLog(titleID, kind: kind.rawValue)
            guard let log else { text = ""; return }
            text = await Task.detached { Self.tail(of: log, maxBytes: Self.shownBytes) }.value
        }
    }

    /// Changes with the kind, and when an operation or a session of this game starts or ends.
    private var reloadKey: [String] {
        [titleID, kind.rawValue, model.launcher.running[titleID] == nil ? "stopped" : "running",
         model.latestLog(titleID, kind: kind.rawValue)?.lastPathComponent ?? ""]
            + model.queue.items.filter { $0.titleID == titleID }.map { "\($0.id)-\($0.isFinished)" }
    }

    /// The last `maxBytes` of the file, from the start of a line, marked when cut.
    nonisolated static func tail(of url: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return "" }
        var body = Substring(String(decoding: data, as: UTF8.self))
        guard start > 0 else { return String(body) }
        if let newline = body.firstIndex(of: "\n") { body = body[body.index(after: newline)...] }
        return "… (the start of the log is not shown)\n" + body
    }
}
