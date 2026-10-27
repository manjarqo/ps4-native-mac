// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import PS4NativeKit
import PS4NativeUI
import SwiftUI

/// Opens the app, or with `--smoke <fixtures dir> --out <dir>` runs the smoke test (`SmokeMode`)
/// and exits with its status.
@main
enum PS4NativeMain {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.contains(SmokeMode.flag) else {
            PS4NativeApp.main()
            return
        }
        guard let options = SmokeMode.Options(arguments: arguments) else {
            FileHandle.standardError.write(Data("usage: PS4Native \(SmokeMode.flag) <fixtures dir> --out <dir>\n".utf8))
            exit(2)
        }
        Task { @MainActor in exit(await SmokeMode.run(options)) }
        // The main run loop, not dispatchMain: offscreen SwiftUI drawing needs it to run.
        RunLoop.main.run()
    }
}

struct PS4NativeApp: App {
    @State private var launch = AppLaunch.make(arguments: CommandLine.arguments)

    init() {
        // Run from `swift run` (no bundle), the process would otherwise get no Dock icon or focus.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("PS4 Native", id: "library") {
            switch launch {
            case .ready(let model):
                RootView(model: model)
                    .task { await model.start() }
            case .engineMissing(let expected):
                EngineMissingView(expected: expected)
            }
        }
        .windowResizability(.contentMinSize)
    }
}

/// What the app opens with: the library on the real engine, or the error that it is missing.
@MainActor
enum AppLaunch {
    case ready(AppModel)
    case engineMissing(URL)

    /// Builds the model on the real paths, `ProcessEngine` and stores. `PS4NATIVE_ENGINE` (a
    /// directory holding `ps4-recomp`, such as a repo checkout for a development run),
    /// `PS4NATIVE_LIBRARY` and `PS4RECOMP_DATA_DIR` override the paths (`Paths`).
    static func make(arguments: [String]) -> AppLaunch {
        let paths = Paths()
        guard FileManager.default.isExecutableFile(atPath: paths.engineExecutable.path) else {
            return .engineMissing(paths.engineExecutable)
        }
        let model = AppModel(
            paths: paths,
            engine: ProcessEngine(executable: paths.engineExecutable),
            launcher: GameLauncher(),
            queue: EngineOperationQueue(),
            library: LibraryStore(root: paths.libraryRoot),
            saves: SaveStore(savesDir: paths.savesDir,
                             backupsDir: paths.libraryRoot.appendingPathComponent("backups", isDirectory: true)))
        return .ready(model)
    }
}

/// Shown instead of the library when the bundled engine is not where the app expects it.
struct EngineMissingView: View {
    let expected: URL

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.yellow)
            Text("The PS4 Native engine is missing").font(.title.bold())
            Text("The app expected the engine at:").foregroundStyle(.secondary)
            Text(expected.path).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Text("Reinstall PS4 Native. For a development run, set PS4NATIVE_ENGINE to a directory that holds a built ps4-recomp.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(40)
        .frame(minWidth: 1000, minHeight: 640)
        .preferredColorScheme(.dark)
    }
}
