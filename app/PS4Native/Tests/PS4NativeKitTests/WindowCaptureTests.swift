// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import PS4NativeKit
@testable import PS4NativeUI

/// Shows the real views in on-screen windows of the test process, drives them in-process
/// (no Accessibility permission needed) and captures them with `screencapture -l` into
/// `$PS4NATIVE_RENDER_DIR`. ImageRenderer cannot draw AppKit-backed controls; a window does.
/// Opt-in, since it opens windows: PS4NATIVE_RENDER_WINDOWS=1.
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["PS4NATIVE_RENDER_WINDOWS"] == "1"))
struct WindowCaptureTests {
    /// Hosts `view` in a dark window on screen.
    func show(_ view: some View, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: width, height: height),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: view.preferredColorScheme(.dark))
        window.orderFrontRegardless()
        return window
    }

    /// Lets SwiftUI run its tasks and layout.
    func settle(_ seconds: Double = 0.8) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// `screencapture -l` of a window into the render directory.
    func capture(_ window: NSWindow, _ name: String) throws {
        let out = RenderTests.outputDir.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-o", "-x", "-l", String(window.windowNumber), out.path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0 && FileManager.default.fileExists(atPath: out.path))
    }

    func find<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool = { _ in true }) -> T? {
        if let v = view as? T, match(v) { return v }
        for sub in view.subviews { if let v = find(type, in: sub, where: match) { return v } }
        return nil
    }

    @Test func gamePageTabsSheetsAndRestoreConfirmation() async throws {
        let scene = try RenderTests.Scene()
        defer { scene.cleanUp() }
        try await scene.seedLibrary()
        let model = scene.model, id = RenderTests.playable
        // A save slot, a backup of it and a build log.
        let slot = model.saves.savesDir.appendingPathComponent("The Last of Us Remastered [\(id)]/user_00000001/SAVEDATA00")
        try FileManager.default.createDirectory(at: slot.appendingPathComponent("sce_sys"), withIntermediateDirectories: true)
        var param = [UInt8](repeating: 0, count: 1328)
        for (offset, text) in [(0, "The Last of Us Remastered"), (128, "Chapter 3: Bill's Town")] {
            Array(text.utf8).enumerated().forEach { param[offset + $0.offset] = $0.element }
        }
        withUnsafeBytes(of: Int64(Date().timeIntervalSince1970 - 3600).littleEndian) { param.replaceSubrange(1288..<1296, with: $0) }
        try Data(param).write(to: slot.appendingPathComponent("sce_sys/param.bin"))
        try Data(count: 250_000).write(to: slot.appendingPathComponent("SAVEDATA.DAT"))
        try model.saves.backup(titleID: id)
        let logs = try model.library.logsDir(titleID: id)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data(((0..<60).map { "[\($0)] compile module_\($0).c -> module_\($0).o\n" }.joined() + "build: signed eboot.app\n").utf8)
            .write(to: logs.appendingPathComponent("2026-10-27_08-00-00-build.log"))
        await model.start()
        await model.measureBuilds()
        await model.scanLogs()
        model.selection = id

        let window = show(RootView(model: model), width: 1200, height: 760)
        defer { window.close() }
        try await settle(1.5)
        let content = try #require(window.contentView)
        let tabs = try #require(find(NSSegmentedControl.self, in: content) { $0.segmentCount == 5 })
        for (i, name) in ["overview", "settings", "saves", "dlc", "buildlog"].enumerated() {
            tabs.selectedSegment = i
            _ = tabs.sendAction(tabs.action, to: tabs.target)
            try await settle()
            try capture(window, "window-tab-\(name).png")
        }

        // The restore confirmation, as choosing the backup in Restore… leaves it (SwiftUI's menu
        // cannot be driven in-process without an accessibility client).
        let backup = try #require(model.saves.backups(titleID: id).first)
        window.contentView = NSHostingView(rootView: SavesTab(model: model, titleID: id, confirming: backup)
            .padding(20).frame(width: 1200, height: 760, alignment: .topLeading).preferredColorScheme(.dark))
        try await settle()
        try capture(window, "window-restore-tab.png")
        let dialog = try #require(window.attachedSheet)
        try capture(dialog, "window-restore-confirm.png")
        window.endSheet(dialog)

        let uninstall = show(UninstallSheet(model: model, game: model.games[0]), width: 440, height: 220)
        defer { uninstall.close() }
        try await settle()
        try capture(uninstall, "window-uninstall.png")

        // The add sheet with a folder, a retail PKG and an fpkg.
        let src = scene.root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("dump"), withIntermediateDirectories: true)
        try Data().write(to: src.appendingPathComponent("dump/eboot.bin"))
        for (fixture, name) in [("inspect-folder", "dump"), ("inspect-retail", "retail.pkg"), ("inspect", "game.pkg")] {
            let lines = try String(contentsOf: RenderTests.fixtures.appending(path: "\(fixture).jsonl"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            scene.engine.setScript("inspect", lines: lines, exitOK: true)
            await model.add([src.appendingPathComponent(name)])
        }
        #expect(model.pendingCandidates.count == 3)
        let add = show(AddGameSheet(model: model), width: 640, height: 520)
        defer { add.close() }
        try await settle()
        try capture(add, "window-add-sheet.png")
    }

    /// The README screenshot: the main window with three games in the sidebar and the Overview tab.
    /// Only the synthetic gradient art of the scratch library is shown. The test process is put on
    /// an English locale first, so dates and sizes read in English whatever the machine's language.
    /// The capture is `readme-ps4native-app.png` in `$PS4NATIVE_RENDER_DIR`.
    @Test func readmeScreenshot() async throws {
        // Process-local: UserDefaults.standard of the test process is its argument domain.
        UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        UserDefaults.standard.set("en_US", forKey: "AppleLocale")
        let scene = try RenderTests.Scene()
        defer { scene.cleanUp() }
        try await scene.seedLibrary()
        let library = scene.model.library
        let uncharted = RenderTests.experimental
        try await library.update { file in
            file.games = file.games.map { game in
                var g = game
                if g.titleID == uncharted { g.status = "in_progress" }
                return g
            }
            file.games.append(GameRecord(titleID: "CUSA02429", title: "inFAMOUS Second Son", appVer: "01.07", version: "01.00",
                                         contentBytes: 25_400_000_000, status: "experimental"))
        }
        let palette: [(String, CGColor, CGColor)] = [
            (RenderTests.experimental, CGColor(red: 0.78, green: 0.55, blue: 0.2, alpha: 1), CGColor(red: 0.2, green: 0.12, blue: 0.08, alpha: 1)),
            ("CUSA02429", CGColor(red: 0.2, green: 0.55, blue: 0.85, alpha: 1), CGColor(red: 0.08, green: 0.1, blue: 0.2, alpha: 1)),
        ]
        for (id, top, bottom) in palette {
            let sceSys = try library.contentDir(titleID: id).appendingPathComponent("sce_sys")
            try RenderTests.writePNG(sceSys.appendingPathComponent("icon0.png"), width: 64, height: 64, top: top, bottom: bottom)
        }
        await scene.model.start()
        await scene.model.measureBuilds()
        await scene.model.scanLogs()
        scene.model.selection = RenderTests.playable
        _ = await GameArt.shared.first(GameArt.heroURLs(scene.model, RenderTests.playable))

        let window = show(RootView(model: scene.model), width: 1400, height: 900)
        defer { window.close() }
        try await settle(2)
        try capture(window, "readme-ps4native-app.png")
    }
}
