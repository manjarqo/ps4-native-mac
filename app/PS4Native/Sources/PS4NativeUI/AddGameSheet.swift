// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The inspected PKGs and folders, each with what it is, why it cannot be imported, the space
/// it needs and, for a folder, copy or use in place.
public struct AddGameSheet: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to the library").font(.title2.bold())
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.pendingCandidates) { CandidateCard(model: model, candidate: $0) }
                }
            }
            .frame(minHeight: 140, maxHeight: 460)
            HStack {
                Text("\(Format.bytes(model.libraryFreeBytes)) free on the library volume").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    for c in model.pendingCandidates { model.dismiss(c.id) }
                }
                .keyboardShortcut(.cancelAction)
                Button("Import all") {
                    for c in model.pendingCandidates where c.canConfirm { confirm(c) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.pendingCandidates.contains { $0.canConfirm })
            }
        }
        .padding(20)
        .frame(width: 640)
        .preferredColorScheme(.dark)
        // Cancel and the imports empty the list, which closes the sheet.
        .interactiveDismissDisabled()
    }

    private func confirm(_ c: AddCandidate) {
        do { try model.confirm(c, mode: c.mode) } catch { model.report(error) }
    }
}

/// One candidate of the add sheet.
struct CandidateCard: View {
    @Bindable var model: AppModel
    let candidate: AddCandidate

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            GameIcon(urls: iconURLs, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(inspect?.title.isEmpty == false ? inspect!.title : candidate.url.lastPathComponent)
                    .font(.headline)
                Text(subtitle).foregroundStyle(.secondary)
                if let message = candidate.message {
                    Label(Format.sentence(message), systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    space
                }
                if candidate.isFolder, candidate.canConfirm {
                    Picker("Folder", selection: Binding { candidate.mode } set: { model.setMode($0, for: candidate.id) }) {
                        Text("Copy into the library (APFS clone)").tag(ImportMode.copy)
                        Text("Use in place").tag(ImportMode.reference)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button("Import") {
                    do { try model.confirm(candidate, mode: candidate.mode) } catch { model.report(error) }
                }
                .disabled(!candidate.canConfirm)
                Button("Remove") { model.dismiss(candidate.id) }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
    }

    private var inspect: InspectResult? { candidate.inspect }

    private var iconURLs: [URL] {
        guard let path = inspect?.iconPath, !path.isEmpty else { return [] }
        return [URL(fileURLWithPath: path)]
    }

    private var subtitle: String {
        guard let inspect else { return candidate.url.path }
        return "\(Format.kind(inspect.kind)) · \(inspect.titleID) · \(Format.version(inspect.appVer))"
    }

    @ViewBuilder private var space: some View {
        let needed = "Needs \(Format.bytes(candidate.neededBytes)) of \(Format.bytes(model.libraryFreeBytes)) free"
        if model.spaceShort(candidate) {
            Label(needed + ": not enough space", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Text(needed).foregroundStyle(.secondary)
        }
    }
}
