// SPDX-License-Identifier: GPL-2.0-or-later
import ImageIO
import PS4NativeKit
import SwiftUI

/// The games' own images (content/sce_sys/*.png and inspected icons), read off the main actor
/// and kept in memory by path. A missing or unreadable file is remembered as nil.
@MainActor
final class GameArt {
    static let shared = GameArt()

    private var images: [String: CGImage?] = [:]

    /// The first of `urls` that has been read and is an image, with its index; nil while none is
    /// known to be.
    func firstCached(_ urls: [URL]) -> (image: CGImage, index: Int)? {
        for (i, url) in urls.enumerated() {
            switch images[url.path] {
            case .some(.some(let image)): return (image, i)
            case .some(.none): continue
            case .none: return nil
            }
        }
        return nil
    }

    /// The first of `urls` that is an image, reading the ones not read yet.
    func first(_ urls: [URL]) async -> (image: CGImage, index: Int)? {
        for (i, url) in urls.enumerated() {
            if let image = await image(at: url) { return (image, i) }
        }
        return nil
    }

    func image(at url: URL) async -> CGImage? {
        if let known = images[url.path] { return known }
        let image = await Task.detached { Self.read(url) }.value
        images[url.path] = image
        return image
    }

    private nonisolated static func read(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // Decode the pixels here, not lazily on the main thread at the first draw.
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    /// content/sce_sys/<name> of a game.
    static func sceSys(_ model: AppModel, _ titleID: String, _ name: String) -> URL? {
        (try? model.library.contentDir(titleID: titleID))?.appendingPathComponent("sce_sys/\(name)")
    }

    /// pic1, pic0, then icon0: the hero's candidates, in order.
    static func heroURLs(_ model: AppModel, _ titleID: String) -> [URL] {
        ["pic1.png", "pic0.png", "icon0.png"].compactMap { sceSys(model, titleID, $0) }
    }
}

/// Shows the first image of `urls` that exists, through `content`, which gets nil until then.
struct ArtView<Content: View>: View {
    let urls: [URL]
    @ViewBuilder let content: (_ image: CGImage?, _ index: Int) -> Content
    @State private var found: (image: CGImage, index: Int)?

    init(urls: [URL], @ViewBuilder content: @escaping (_ image: CGImage?, _ index: Int) -> Content) {
        self.urls = urls
        self.content = content
        _found = State(initialValue: GameArt.shared.firstCached(urls))
    }

    var body: some View {
        content(found?.image, found?.index ?? -1)
            .task(id: urls) { found = await GameArt.shared.first(urls) }
    }
}

/// A game's icon0.png in a rounded square, a controller symbol without one.
struct GameIcon: View {
    let urls: [URL]
    var size: CGFloat = 22

    var body: some View {
        ArtView(urls: urls) { image, _ in
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            } else {
                Image(systemName: "gamecontroller").font(.system(size: size * 0.55)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}
