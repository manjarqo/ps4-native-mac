// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The first-run sheet: the toolchain, the free space, and an existing game folder to import.
public struct FirstRunView: View {
    private static let folderHint = "Choose the game's own folder, named like CUSA00557, that contains eboot.bin and sce_sys/param.sfo — not the folder above it."

    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to PS4 Native").font(.largeTitle.bold())
            Text("PS4 Native recompiles your own PS4 games into Mac apps. A build needs Apple's Command Line Tools and disk space.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox("This Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    ToolchainSection(model: model)
                    LabeledContent("Free space", value: model.toolchain.map { Format.bytes($0.freeBytes) } ?? "Checking…")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            GroupBox("Games") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Have a dumped game folder from the earlier PS4Recomp setup?")
                        Spacer()
                        Button("Import existing game folder…") {
                            if let url = Panels.chooseFolder(title: "Import existing game folder", message: Self.folderHint) {
                                Task { await model.importExistingFolder(url) }
                            }
                        }
                    }
                    Text(Self.folderHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }
            HStack {
                Spacer()
                Button("Done") { model.finishFirstRun() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 600)
        .preferredColorScheme(.dark)
        // Only Done ends the first run.
        .interactiveDismissDisabled()
        .sheet(isPresented: RootView.shown { !model.pendingCandidates.isEmpty }) {
            AddGameSheet(model: model)
        }
    }
}

/// The toolchain report, with Check again and, when the tools are missing, their installer.
struct ToolchainSection: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = model.toolchain {
                if report.problems.isEmpty {
                    Label("clang \(report.clangVersion ?? 0) with the macOS \(report.sdkVersion ?? 0) SDK: ready to build",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(report.problems, id: \.self) { problem in
                        Label(Format.sentence(problem), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
                HStack {
                    Button("Check again") { Task { await model.checkToolchain() } }
                    if report.commandLineToolsMissing {
                        Button("Install Command Line Tools") {
                            Task.detached { Toolchain.installCommandLineTools() }
                        }
                    }
                }
            } else {
                ProgressView("Checking the toolchain…").controlSize(.small)
            }
        }
    }
}
