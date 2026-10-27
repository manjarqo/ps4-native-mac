// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import UniformTypeIdentifiers

/// The open and save panels, and Finder, for the views' buttons.
@MainActor
enum Panels {
    /// PKGs and folders, several at once, for the add flow.
    static func chooseAddItems(
        message: String = "Choose a fake-signed .pkg, or a game folder named like CUSA00557 that contains eboot.bin and sce_sys/param.sfo."
    ) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add game"
        panel.message = message
        panel.prompt = "Add"
        panel.allowedContentTypes = [UTType(filenameExtension: "pkg") ?? .data, .folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func chooseFolder(title: String, message: String = "") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseZip(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.zip]
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveZip(name: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = name
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
