// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// A game language: the Orbis code, the locale code, the native name and the speech pack name.
public struct Language: Sendable, Equatable, Identifiable {
    public let orbis: Int
    public let code: String
    public let title: String
    public let pack: String
    public var id: Int { orbis }
}

/// The runtime's language table (pkg/runtime/modules/libSceSystemService/ps4_settings.m, kLangs).
public enum Languages {
    public static let all: [Language] = [
        Language(orbis: 0, code: "ja", title: "日本語", pack: "japanese"),
        Language(orbis: 1, code: "en", title: "English", pack: "english"),
        Language(orbis: 2, code: "fr", title: "Français", pack: "french"),
        Language(orbis: 3, code: "es", title: "Español", pack: "spanish"),
        Language(orbis: 4, code: "de", title: "Deutsch", pack: "german"),
        Language(orbis: 5, code: "it", title: "Italiano", pack: "italian"),
        Language(orbis: 6, code: "nl", title: "Nederlands", pack: "dutch"),
        Language(orbis: 7, code: "pt", title: "Português", pack: "portuguese"),
        Language(orbis: 8, code: "ru", title: "Русский", pack: "russian"),
        Language(orbis: 9, code: "ko", title: "한국어", pack: "korean"),
        Language(orbis: 11, code: "zh", title: "中文", pack: "chinese"),
        Language(orbis: 12, code: "fi", title: "Suomi", pack: "finnish"),
        Language(orbis: 13, code: "sv", title: "Svenska", pack: "swedish"),
        Language(orbis: 14, code: "da", title: "Dansk", pack: "danish"),
        Language(orbis: 15, code: "no", title: "Norsk", pack: "norwegian"),
        Language(orbis: 16, code: "pl", title: "Polski", pack: "polish"),
        Language(orbis: 17, code: "pt-br", title: "Português (Brasil)", pack: "brazilian"),
        Language(orbis: 19, code: "tr", title: "Türkçe", pack: "turkish"),
        Language(orbis: 20, code: "es-la", title: "Español (Latinoamérica)", pack: "latam"),
        Language(orbis: 21, code: "ar", title: "العربية", pack: "arabic"),
    ]

    /// Languages with a speech pack (`<pack>-sp.psarc` or a `<pack>` directory) under the content
    /// directory, in table order; English alone when there are none (the runtime's rule).
    public static func available(content: URL) -> [Language] {
        let speech = content.appendingPathComponent("build/ps4/main/sound1/streams/speech", isDirectory: true)
        let fm = FileManager.default
        let found = all.filter { l in
            fm.fileExists(atPath: speech.appendingPathComponent("\(l.pack)-sp.psarc").path)
                || fm.fileExists(atPath: speech.appendingPathComponent(l.pack).path)
        }
        return found.isEmpty ? all.filter { $0.orbis == 1 } : found
    }
}
