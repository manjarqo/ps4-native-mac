// SPDX-License-Identifier: GPL-2.0-or-later
import PS4NativeKit
import SwiftUI

/// The game's runtime settings, saved as soon as they change, with the analysis's
/// recommended values marked.
struct SettingsTab: View {
    @Bindable var model: AppModel
    let titleID: String
    @State private var settings: GameSettings?
    @State private var languages: [Language] = []
    @State private var stored: GameAnalysis?

    var body: some View {
        Form {
            if let settings {
                Section {
                    Picker(selection: bind(\.lang)) {
                        Text("System default").tag(Int?.none)
                        ForEach(languageOptions(settings)) { Text($0.title).tag(Int?.some($0.orbis)) }
                    } label: {
                        labelled("Language", "lang") { v in v < 0 ? "System default" : Languages.all.first { $0.orbis == v }?.title ?? "\(v)" }
                    }
                    Toggle(isOn: bind(\.pro)) { labelled("PS4 Pro mode", "pro", onOff) }
                    Toggle(isOn: bind(\.upscale)) { labelled("MetalFX upscaling", "upscale", onOff) }
                    Toggle(isOn: bind(\.hud)) { labelled("FPS counter (Metal HUD)", "hud", onOff) }
                    Picker(selection: bind(\.metal)) {
                        Text("Automatic").tag(Int?.none)
                        Text("Metal 3").tag(Int?.some(3))
                        Text("Metal 4").tag(Int?.some(4))
                    } label: {
                        labelled("Renderer", "metal") { Format.renderer($0 == 3 || $0 == 4 ? $0 : nil) }
                    }
                } footer: {
                    HStack {
                        Text("Changes apply the next time the game starts.").foregroundStyle(.secondary)
                        Spacer()
                        Button("Use recommended") { save(settings.applying(recommended: recommended)) }
                            .disabled(recommended.isEmpty || settings.applying(recommended: recommended) == settings)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: titleID) {
            // The settings file, the speech packs and analysis.json are all read off the main actor.
            let id = titleID, dir = model.paths.settingsDir, content = try? model.library.contentDir(titleID: titleID)
            async let analysis = model.loadAnalysis(id)
            let (loaded, available) = await Task.detached {
                (GameSettings.load(titleID: id, settingsDir: dir), content.map { Languages.available(content: $0) } ?? [])
            }.value
            stored = await analysis
            languages = available
            settings = loaded
        }
    }

    /// The available languages, plus the saved one when its speech pack is not there, so the
    /// picker always has its selection.
    private func languageOptions(_ s: GameSettings) -> [Language] {
        guard let lang = s.lang, !languages.contains(where: { $0.orbis == lang }),
              let saved = Languages.all.first(where: { $0.orbis == lang }) else { return languages }
        return languages + [saved]
    }

    private var recommended: [String: Int] {
        (model.analyses[titleID] ?? stored)?.verdict.recommended ?? [:]
    }

    private func onOff(_ v: Int) -> String { v != 0 ? "On" : "Off" }

    /// The setting's name, with "Recommended: <value>" under it when the analysis recommends one.
    private func labelled(_ name: String, _ key: String, _ value: (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
            if let v = recommended[key] {
                Text("Recommended: \(value(v))").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private func bind<T>(_ key: WritableKeyPath<GameSettings, T>) -> Binding<T> {
        Binding {
            (settings ?? GameSettings())[keyPath: key]
        } set: { value in
            guard var s = settings else { return }
            s[keyPath: key] = value
            save(s)
        }
    }

    private func save(_ s: GameSettings) {
        settings = s
        model.saveSettings(s, for: titleID)
    }
}
