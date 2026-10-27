// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Where the app keeps its library, the engine's data, and the bundled engine kit.
/// Built from an injected environment so tests can supply their own.
public struct Paths: Sendable, Equatable {
    public let libraryRoot: URL
    public let dataDir: URL
    public let savesDir: URL
    public let settingsDir: URL
    public let engineKit: URL
    public let engineExecutable: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, bundle: Bundle = .main) {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let support = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        func override(_ key: String) -> URL? {
            guard let v = environment[key], !v.isEmpty else { return nil }
            return URL(fileURLWithPath: v, isDirectory: true)
        }
        libraryRoot = override("PS4NATIVE_LIBRARY") ?? support.appendingPathComponent("PS4Native", isDirectory: true)
        dataDir = override("PS4RECOMP_DATA_DIR") ?? support.appendingPathComponent("PS4Recomp", isDirectory: true)
        savesDir = override("PS4_SAVEDATA_DIR") ?? dataDir.appendingPathComponent("saves", isDirectory: true)
        settingsDir = dataDir.appendingPathComponent("settings", isDirectory: true)
        engineKit = override("PS4NATIVE_ENGINE")
            ?? (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent("engine", isDirectory: true)
        engineExecutable = engineKit.appendingPathComponent("ps4-recomp")
    }
}
