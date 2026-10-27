// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What a build needs from this Mac: the Command Line Tools with a recent clang and macOS SDK,
/// and room on the library volume.
public struct ToolchainReport: Sendable, Equatable {
    /// The clang major version; nil when clang was not found or its version could not be read.
    public let clangVersion: Int?
    /// The macOS SDK major version; nil when it could not be read.
    public let sdkVersion: Int?
    /// Free space for important use on the library volume.
    public let freeBytes: Int64
    /// What stands in the way of a build, for display; empty when nothing does.
    public let problems: [String]

    /// True when the Command Line Tools are not installed: "Install Command Line Tools" helps.
    public var commandLineToolsMissing: Bool { problems.contains(Toolchain.missingToolsProblem) }

    public init(clangVersion: Int?, sdkVersion: Int?, freeBytes: Int64, problems: [String]) {
        self.clangVersion = clangVersion
        self.sdkVersion = sdkVersion
        self.freeBytes = freeBytes
        self.problems = problems
    }
}

public enum ToolchainError: Error, Equatable, Sendable {
    /// The command exited with a non-zero status, or was killed.
    case failed(String, Int32)
}

public enum Toolchain {
    static let minimumClang = 17
    static let minimumSDK = 26
    static let minimumFreeBytes: Int64 = 30_000_000_000

    static let missingToolsProblem = "Command Line Tools are not installed"

    static let xcodeSelect = "/usr/bin/xcode-select"
    static let xcrun = "/usr/bin/xcrun"

    /// Checks the toolchain with `run` (an executable path and its arguments, giving stdout) and
    /// the free space of the volume that holds `library`.
    ///
    /// `xcode-select -p` comes first: it fails quietly without the Command Line Tools, where
    /// `xcrun` may pop up Apple's installer instead.
    public static func check(library: URL, run: (String, [String]) throws -> String = Toolchain.shell,
                             freeSpace: (URL) -> Int64 = Toolchain.freeBytes(at:)) -> ToolchainReport {
        var problems: [String] = []
        var clang: Int?
        var sdk: Int?
        if let clangPath = locateClang(run: run) {
            clang = (try? run(clangPath, ["--version"])).flatMap(clangMajor)
            if let clang {
                if clang < minimumClang { problems.append("clang \(clang) is too old (\(minimumClang) or later needed)") }
            } else {
                problems.append("the clang version could not be read")
            }
            sdk = (try? run(xcrun, ["--show-sdk-version"])).flatMap(leadingMajor)
            if let sdk {
                if sdk < minimumSDK { problems.append("the macOS SDK \(sdk) is too old (\(minimumSDK) or later needed)") }
            } else {
                problems.append("the macOS SDK version could not be read")
            }
        } else {
            problems.append(missingToolsProblem)
        }
        let free = freeSpace(library)
        if free < minimumFreeBytes { problems.append("less than 30 GB free on the library volume") }
        return ToolchainReport(clangVersion: clang, sdkVersion: sdk, freeBytes: free, problems: problems)
    }

    /// The path of clang from `xcrun --find clang`, nil without the Command Line Tools.
    static func locateClang(run: (String, [String]) throws -> String) -> String? {
        guard (try? run(xcodeSelect, ["-p"])) != nil,
              let path = try? run(xcrun, ["--find", "clang"]).trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return path
    }

    /// Opens Apple's Command Line Tools installer; the user goes on in its window.
    public static func installCommandLineTools() {
        _ = try? shell(xcodeSelect, ["--install"])
    }

    /// Runs `executable` with `arguments` and returns its stdout. Throws when it cannot be
    /// started or does not exit with 0.
    public static func shell(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting so a full pipe cannot stall the command.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ToolchainError.failed(executable, process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The free space for important use on the volume of `url`, asked of its nearest existing
    /// ancestor (the library root may not exist yet); 0 when it cannot be read.
    public static func freeBytes(at url: URL) -> Int64 {
        var dir = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: dir.path), dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// The major of "Apple clang version N…" (or "clang version N…").
    static func clangMajor(_ text: String) -> Int? {
        guard let match = text.firstMatch(of: /clang version (\d+)/) else { return nil }
        return Int(match.1)
    }

    /// The major of a version such as "27.1".
    static func leadingMajor(_ text: String) -> Int? {
        guard let match = text.firstMatch(of: /^\s*(\d+)/) else { return nil }
        return Int(match.1)
    }
}
