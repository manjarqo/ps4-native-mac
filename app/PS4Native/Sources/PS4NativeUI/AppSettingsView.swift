// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The manager's Settings page: the library location, the engine and the toolchain.
struct AppSettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Location") {
                    Text(model.paths.libraryRoot.path).textSelection(.enabled)
                }
                Button("Show in Finder") { Panels.reveal(model.paths.libraryRoot) }
            }
            Section("Engine") {
                LabeledContent("Version", value: model.engineVersion ?? "unknown")
                LabeledContent("Location") {
                    Text(model.paths.engineExecutable.path).textSelection(.enabled)
                }
            }
            Section("Toolchain") {
                ToolchainSection(model: model)
            }
        }
        .formStyle(.grouped)
    }
}
