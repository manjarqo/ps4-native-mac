// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// Builds & imports: every operation with its stage and progress, Cancel and Show log.
public struct QueueView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Builds & imports").font(.title2.bold())
                Spacer()
                Button("Clear finished") { model.queue.clearFinished() }
                    .disabled(!model.queue.items.contains { $0.isFinished })
            }
            if model.queue.items.isEmpty {
                ContentUnavailableView("Nothing queued", systemImage: "tray",
                                       description: Text("Imports, analyses and builds show up here."))
            } else {
                List(model.queue.items) { QueueRow(queue: model.queue, item: $0) }
                    .listStyle(.inset)
            }
        }
        .padding(20)
    }
}

struct QueueRow: View {
    let queue: EngineOperationQueue
    let item: OperationItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(Format.kind(item.kind)) · \(item.title)").font(.headline)
                    Spacer()
                    Text(state).foregroundStyle(stateColor)
                }
                if item.state == .running {
                    if let fraction = item.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if case .failed(let failure) = item.state {
                    Text(failure.message).foregroundStyle(.red).lineLimit(3)
                } else if !item.detail.isEmpty {
                    Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Button("Cancel") { queue.cancel(item.id) }
                .disabled(item.isFinished)
            Button("Show log") { Panels.open(item.log) }
                .disabled(item.state == .queued)
        }
        .padding(.vertical, 6)
    }

    private var symbol: String {
        switch item.kind {
        case .importGame: "square.and.arrow.down"
        case .analyze: "magnifyingglass"
        case .build: "hammer"
        }
    }

    private var state: String {
        switch item.state {
        case .queued: "Queued"
        case .running:
            [item.stage.isEmpty ? "Running" : Format.sentence(item.stage),
             item.fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) }]
                .compactMap { $0 }.joined(separator: " · ")
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var stateColor: Color {
        switch item.state {
        case .failed: .red
        case .done: .green
        default: .secondary
        }
    }
}
