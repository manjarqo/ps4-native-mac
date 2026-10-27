// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import PS4NativeKit
import PS4NativeUI
import SwiftUI

/// `PS4Native --smoke <fixtures dir> --out <dir>`: the packaged app's self-test. The model runs on
/// `FakeEngine` replaying the recorded fixtures and on a launcher that runs `/bin/sleep 1`
/// instead of the game, so neither the bundled engine nor any game runs. `SmokeRunner` drives
/// the main path; the game page it ends on is drawn to `<out>/window.png`, the report is written
/// to `<out>/smoke.json`, and the exit status is 0 when every step passed and 1 otherwise.
///
/// The library and data dir must be overridden (`PS4NATIVE_LIBRARY`, `PS4RECOMP_DATA_DIR`) with
/// directories other than the user's real ones (`SmokeRunner.scratchProblem`), so a smoke run
/// never writes into the user's library or saves.
@MainActor
enum SmokeMode {
    nonisolated static let flag = "--smoke"

    struct Options {
        let fixtures: URL
        let out: URL

        /// Parses `--smoke <fixtures dir> --out <dir>`; nil when either value is missing.
        init?(arguments: [String]) {
            func value(after flag: String) -> String? {
                guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count,
                      !arguments[i + 1].hasPrefix("--") else { return nil }
                return arguments[i + 1]
            }
            guard let fixtures = value(after: SmokeMode.flag), let out = value(after: "--out") else { return nil }
            self.fixtures = URL(fileURLWithPath: fixtures, isDirectory: true).standardizedFileURL
            self.out = URL(fileURLWithPath: out, isDirectory: true).standardizedFileURL
        }
    }

    static func run(_ options: Options) async -> Int32 {
        if let problem = SmokeRunner.scratchProblem(environment: ProcessInfo.processInfo.environment) {
            log("smoke: \(problem)")
            return 2
        }
        // Offscreen drawing needs the shared application, but the smoke run shows no window or Dock icon.
        NSApplication.shared.setActivationPolicy(.prohibited)

        let fm = FileManager.default
        let source = options.out.appendingPathComponent("src", isDirectory: true)
        do {
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
        } catch {
            log("smoke: cannot create \(source.path): \(error.localizedDescription)")
            return 2
        }
        let suite = "org.ps4native.manager.smoke-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            log("smoke: cannot open the defaults suite \(suite)")
            return 2
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let paths = Paths()
        let library = LibraryStore(root: paths.libraryRoot)
        let model = AppModel(
            paths: paths,
            engine: SmokeRunner.engine(fixtures: options.fixtures, source: source, temp: options.out, library: library),
            launcher: SmokeRunner.launcher(),
            queue: EngineOperationQueue(),
            library: library,
            saves: SaveStore(savesDir: paths.savesDir,
                             backupsDir: paths.libraryRoot.appendingPathComponent("backups", isDirectory: true)),
            defaults: defaults,
            applicationsDir: options.out.appendingPathComponent("Applications", isDirectory: true))
        await model.start()
        let report = await SmokeRunner().run(model: model, fixturesSource: source)
        for step in report.steps {
            let name = step.name.padding(toLength: 20, withPad: " ", startingAt: 0)
            log("smoke: \(step.passed ? "PASS" : "FAIL") \(name) \(String(format: "%6.2f", step.seconds))s  \(step.detail)")
        }

        var rendered = false
        if let game = model.games.first(where: { $0.titleID == report.titleID }) {
            await model.measureBuilds()
            let window = options.out.appendingPathComponent("window.png")
            model.selection = game.titleID
            rendered = await render(GamePageView(model: model, game: game), to: window)
            log(rendered ? "smoke: wrote \(window.path)" : "smoke: could not draw \(window.path)")
        } else {
            log("smoke: no game in the library to draw")
        }

        let json = options.out.appendingPathComponent("smoke.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: json, options: .atomic)
        } catch {
            log("smoke: cannot write \(json.path): \(error.localizedDescription)")
            return 1
        }
        let passed = report.passed && rendered
        log("smoke: \(passed ? "passed" : "FAILED")")
        return passed ? 0 : 1
    }

    /// Draws `view` in a dark 960×760 borderless window that is never put on screen, into a PNG.
    /// AppKit-backed views such as the segmented tab picker and scroll views are drawn this way,
    /// which ImageRenderer cannot do. The sidebar's vibrancy is not drawn offscreen (it comes out
    /// blank), so the smoke run draws the selected game's page, the window's detail column.
    private static func render(_ view: some View, to url: URL) async -> Bool {
        let size = NSSize(width: 960, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark))
        window.contentView = host
        defer { window.close() }
        // Lets SwiftUI run the views' tasks and lay them out.
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
