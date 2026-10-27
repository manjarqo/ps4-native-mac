// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PS4NativeKit
@testable import PS4NativeUI

/// Renders the real views on a model with FakeEngine and a temp library, and writes the images
/// to `$PS4NATIVE_RENDER_DIR` (the temp directory by default) for a look.
private let renderFixtures = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
private let playableID = "CUSA00557"
private let experimentalID = "CUSA07737"

@MainActor @Suite struct RenderTests {
    static var fixtures: URL { renderFixtures }
    static var playable: String { playableID }
    static var experimental: String { experimentalID }

    /// A model on a temp library, data dir and defaults suite, with the first run done.
    @MainActor final class Scene {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ps4n-render-\(UUID().uuidString)")
        let suite = "ps4native-render-\(UUID().uuidString)"
        let engine: FakeEngine
        let defaults: UserDefaults
        let model: AppModel

        init() throws {
            let paths = Paths(environment: [
                "HOME": root.path,
                "PS4NATIVE_LIBRARY": root.appendingPathComponent("library").path,
                "PS4RECOMP_DATA_DIR": root.appendingPathComponent("data").path,
                "PS4NATIVE_ENGINE": root.appendingPathComponent("engine").path,
            ])
            engine = FakeEngine(fixtures: renderFixtures, substitutions: [
                "$LIB": paths.libraryRoot.path, "$SRC": root.appendingPathComponent("src").path, "$TMP": root.path,
            ])
            defaults = try #require(UserDefaults(suiteName: suite))
            defaults.set(true, forKey: AppModel.firstRunDoneKey)
            model = AppModel(paths: paths, engine: engine, launcher: GameLauncher(), queue: EngineOperationQueue(),
                             library: LibraryStore(root: paths.libraryRoot),
                             saves: SaveStore(savesDir: paths.savesDir, backupsDir: paths.libraryRoot.appendingPathComponent("backups")),
                             defaults: defaults, applicationsDir: root.appendingPathComponent("Applications"),
                             freeSpace: { _ in 412_000_000_000 },
                             toolchainCheck: { _ in ToolchainReport(clangVersion: 21, sdkVersion: 27, freeBytes: 412_000_000_000, problems: []) })
        }

        /// One built playable game with art and an analysis, and one experimental game.
        func seedLibrary() async throws {
            let library = model.library
            try await library.update { file in
                file.games = [
                    GameRecord(titleID: playableID, title: "The Last of Us Remastered", appVer: "01.00", version: "01.00",
                               contentBytes: 48_300_000_000, status: "playable", builtWith: "0.3.0",
                               lastPlayed: ISO8601DateFormatter().string(from: Date()), playSeconds: 11_520),
                    GameRecord(titleID: experimentalID, title: "Uncharted 4", appVer: "01.32", version: "01.00",
                               patches: ["01.32"], contentBytes: 61_000_000_000, status: "experimental"),
                ]
            }
            let sceSys = try library.contentDir(titleID: playableID).appendingPathComponent("sce_sys")
            let olive = CGColor(red: 0.36, green: 0.43, blue: 0.27, alpha: 1), dark = CGColor(red: 0.12, green: 0.14, blue: 0.1, alpha: 1)
            try RenderTests.writePNG(sceSys.appendingPathComponent("pic1.png"), width: 960, height: 540, top: olive, bottom: dark)
            try RenderTests.writePNG(sceSys.appendingPathComponent("icon0.png"), width: 64, height: 64, top: olive, bottom: dark)
            let app = try library.buildDir(titleID: playableID).appendingPathComponent("eboot.app/Contents")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "01.00"], format: .xml, options: 0)
                .write(to: app.appendingPathComponent("Info.plist"))
            try Data(count: 682_000).write(to: app.appendingPathComponent("eboot"))
            let analysis = #"{"title_id":"CUSA00557","title":"The Last of Us Remastered","app_ver":"01.00","category":"gd","verdict":{"status":"playable","name":"The Last of Us Remastered","tested_versions":["01.00"],"recommended":{"pro":1,"metal":3},"known_issues":["Daylight surfaces are slightly darker than on a PS4."]},"coverage":99.96,"unresolved":0,"missing_ops":15,"modules":null}"#
            try Data(analysis.utf8).write(to: try library.gameDir(titleID: playableID).appendingPathComponent("analysis.json"))
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// A PNG of a vertical gradient from `top` to `bottom`, standing in for a game's art.
    static func writePNG(_ url: URL, width: Int, height: Int, top: CGColor, bottom: CGColor) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let gradient = try #require(CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: nil))
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        try write(try #require(ctx.makeImage()), to: url)
    }

    static func write(_ image: CGImage, to url: URL) throws {
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    static var outputDir: URL {
        ProcessInfo.processInfo.environment["PS4NATIVE_RENDER_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }

    /// The number of distinct colours among a sample of the image's pixels.
    static func distinctColours(_ image: CGImage) throws -> Int {
        let width = image.width, height = image.height
        var pixels = [UInt32](repeating: 0, count: width * height)
        let ctx = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Set(stride(from: 0, to: pixels.count, by: 37).map { pixels[$0] }).count
    }

    func render(_ view: some View, width: CGFloat, height: CGFloat, to name: String) throws -> CGImage {
        // The window gives a sheet its background; offscreen it is drawn here.
        let content = view.frame(width: width, height: height)
            .background(Color(red: 0.11, green: 0.12, blue: 0.14))
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        try Self.write(image, to: Self.outputDir.appendingPathComponent(name))
        return image
    }

    @Test func rootViewWithAPlayableAndAnExperimentalGame() async throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        let model = scene.model
        try await scene.seedLibrary()
        await model.start()
        await model.measureBuilds()
        model.selection = Self.playable
        #expect(model.games.count == 2 && model.primaryAction(model.games[0]) == .play)
        _ = await GameArt.shared.first(GameArt.heroURLs(model, Self.playable))
        for id in [Self.playable, Self.experimental] {
            _ = await GameArt.shared.first([try #require(GameArt.sceSys(model, id, "icon0.png"))])
        }

        let root = try render(RootView(model: model), width: 1200, height: 760, to: "ps4native-render.png")
        #expect(root.width == 1200 && root.height == 760)
        #expect(try Self.distinctColours(root) > 20)

        let page = try render(GamePageView(model: model, game: model.games[0]), width: 960, height: 760,
                              to: "ps4native-render-page.png")
        #expect(try Self.distinctColours(page) > 20)
        // NavigationSplitView and List are AppKit-backed and ImageRenderer draws them as a
        // placeholder, so the sidebar's rows are rendered on their own as well.
        let rows = VStack(spacing: 10) { ForEach(model.games) { GameRow(model: model, game: $0) } }.padding(12)
        let sidebar = try render(rows, width: 260, height: 90, to: "ps4native-render-sidebar.png")
        #expect(try Self.distinctColours(sidebar) > 10)
    }

    @Test func addSheetWithARetailCandidate() async throws {
        let scene = try Scene()
        defer { scene.cleanUp() }
        scene.engine.setScript("inspect", lines: try String(contentsOf: Self.fixtures.appending(path: "inspect-retail.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init), exitOK: true)
        try Self.writePNG(scene.root.appendingPathComponent("ps4native-icon-UP9000-CUSA00557_00-TESTGAME00000000.png"), width: 64, height: 64,
                          top: CGColor(red: 0.2, green: 0.3, blue: 0.6, alpha: 1), bottom: CGColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1))
        await scene.model.add([scene.root.appendingPathComponent("src/retail.pkg")])
        let candidate = try #require(scene.model.pendingCandidates.first)
        #expect(!candidate.canConfirm && candidate.message == AddCandidate.retailMessage)
        _ = await GameArt.shared.first([URL(fileURLWithPath: try #require(candidate.inspect?.iconPath))])

        let sheet = try render(AddGameSheet(model: scene.model), width: 640, height: 320, to: "ps4native-render-add.png")
        #expect(sheet.width == 640 && sheet.height == 320)
        #expect(try Self.distinctColours(sheet) > 5)
        // The sheet's ScrollView is AppKit-backed; the card is rendered on its own.
        let card = try render(CandidateCard(model: scene.model, candidate: candidate).padding(12), width: 640, height: 130,
                              to: "ps4native-render-add-card.png")
        #expect(try Self.distinctColours(card) > 10)
    }
}
