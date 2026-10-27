// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The game's art (pic1, pic0, else its icon blurred) under a dark gradient, with the title
/// and "TITLE_ID · version · status".
public struct GameHeroView: View {
    @Bindable var model: AppModel
    let game: GameRecord

    public init(model: AppModel, game: GameRecord) {
        self.model = model
        self.game = game
    }

    public var body: some View {
        ArtView(urls: GameArt.heroURLs(model, game.titleID)) { image, index in
            ZStack(alignment: .bottomLeading) {
                // The art fills the hero's frame and never sizes it.
                Color.clear.overlay {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: index == 2 ? 30 : 0)
                    } else {
                        LinearGradient(colors: [Color(red: 0.24, green: 0.29, blue: 0.2), Color(red: 0.13, green: 0.16, blue: 0.11)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .clipped()
                LinearGradient(colors: [.clear, Color(red: 0.08, green: 0.09, blue: 0.11)], startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.title.isEmpty ? game.titleID : game.title)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text("\(game.titleID) · \(Format.version(game.appVer)) · \(StatusBadge.name(game.status))")
                        .foregroundStyle(.white.opacity(0.75))
                }
                .shadow(radius: 6)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

/// PLAY / Build (or the running session and Stop), Settings, Saves, the ⋯ menu and the build's
/// size. A rebuild offer is the page's banner, beside PLAY.
struct GameActionBar: View {
    @Bindable var model: AppModel
    let game: GameRecord
    @Binding var tab: GameTab
    /// Build, through the page's status gate.
    let build: () -> Void
    let uninstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            primary
            Button { tab = .settings } label: { Label("Settings", systemImage: "gearshape") }
            Button { tab = .saves } label: { Label("Saves", systemImage: "externaldrive") }
            menu
            Spacer()
            Text(builtText).foregroundStyle(.secondary)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var id: String { game.titleID }

    private var builtText: String {
        guard model.isBuilt(id) else { return "Not built" }
        return model.buildBytes[id].map { "Built · \(Format.bytes($0))" } ?? "Built"
    }

    @ViewBuilder private var primary: some View {
        switch model.primaryAction(game) {
        case .play:
            Button { attempt { try model.play(id) } } label: { Label("PLAY", systemImage: "play.fill") }
                .buttonStyle(PrimaryButtonStyle(color: Color(red: 0.3, green: 0.6, blue: 0.16)))
        case .build:
            let refused = model.buildGate(game) == .refused
            Button(action: build) { Label(model.buildGate(game) == .analysisReport ? "Build anyway…" : "Build", systemImage: "hammer.fill") }
                .buttonStyle(PrimaryButtonStyle(color: refused ? .gray : .accentColor))
                .disabled(refused)
                .help(refused ? "This content is not supported and cannot be built" : "Build the game")
        case .busy:
            Button {} label: { Label("Working…", systemImage: "hourglass") }
                .buttonStyle(PrimaryButtonStyle(color: .gray))
                .disabled(true)
        case .running:
            if let started = model.launcher.running[id]?.started {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("Running \(Format.session(context.date.timeIntervalSince(started)))")
                        .font(.headline.monospacedDigit())
                }
            }
            Button { model.launcher.stop(titleID: id) } label: { Label("Stop", systemImage: "stop.fill") }
                .buttonStyle(PrimaryButtonStyle(color: .red))
        }
    }

    private var menu: some View {
        Menu {
            Button("Show in Finder") {
                if let dir = try? model.library.gameDir(titleID: id) { Panels.reveal(dir) }
            }
            Button("Open build log") {
                if let log = model.latestLog(id, kind: "build") { Panels.open(log) }
            }
            .disabled(model.latestLog(id, kind: "build") == nil)
            Button("Add to Applications") { attempt { try model.addToApplications(id) } }
                .disabled(!model.isBuilt(id))
            Button("Analyze again") { attempt { try model.analyze(id) } }
            Divider()
            Button("Uninstall…", role: .destructive, action: uninstall)
                .disabled(model.isBusy(id))
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func attempt(_ call: () throws -> Void) {
        do { try call() } catch { model.report(error) }
    }
}

/// The large coloured button of the action bar.
struct PrimaryButtonStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .background(color.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}
