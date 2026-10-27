// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import PS4NativeKit

@Suite struct ToolchainTests {
    struct Failed: Error {}

    static let library = URL(filePath: "/tmp/ps4n-toolchain-library")
    static let plenty: Int64 = 500_000_000_000

    /// A `run` that answers the toolchain's commands with `clang` and `sdk`.
    static func run(clang: String, sdk: String) -> (String, [String]) throws -> String {
        { exe, args in
            switch (exe, args) {
            case ("/usr/bin/xcode-select", ["-p"]): return "/Library/Developer/CommandLineTools\n"
            case ("/usr/bin/xcrun", ["--find", "clang"]): return "/Library/Developer/CommandLineTools/usr/bin/clang\n"
            case ("/Library/Developer/CommandLineTools/usr/bin/clang", ["--version"]): return clang
            case ("/usr/bin/xcrun", ["--show-sdk-version"]): return sdk
            default: throw Failed()
            }
        }
    }

    @Test func currentToolchainHasNoProblems() {
        let clang = "Apple clang version 21.0.0 (clang-2100.0.123.102)\nTarget: arm64-apple-darwin27.0.0\n"
        let report = Toolchain.check(library: Self.library, run: Self.run(clang: clang, sdk: "27.1\n"),
                                     freeSpace: { _ in Self.plenty })
        #expect(report == ToolchainReport(clangVersion: 21, sdkVersion: 27, freeBytes: Self.plenty, problems: []))
    }

    @Test func oldClangAndSDKAreTwoProblems() {
        let report = Toolchain.check(library: Self.library, run: Self.run(clang: "Apple clang version 16.0.0\n", sdk: "15.4\n"),
                                     freeSpace: { _ in Self.plenty })
        #expect(report.clangVersion == 16 && report.sdkVersion == 15)
        #expect(report.problems == ["clang 16 is too old (17 or later needed)",
                                    "the macOS SDK 15 is too old (26 or later needed)"])
    }

    @Test func missingCommandLineTools() {
        let report = Toolchain.check(library: Self.library, run: { _, _ in throw Failed() }, freeSpace: { _ in Self.plenty })
        #expect(report.clangVersion == nil && report.sdkVersion == nil)
        #expect(report.problems == ["Command Line Tools are not installed"])
        #expect(report.commandLineToolsMissing)
        let current = Toolchain.check(library: Self.library, run: Self.run(clang: "Apple clang version 16.0.0\n", sdk: "27.1\n"),
                                      freeSpace: { _ in Self.plenty })
        #expect(!current.commandLineToolsMissing)
    }

    @Test func lowDiskSpace() {
        let report = Toolchain.check(library: Self.library, run: Self.run(clang: "Apple clang version 21.0.0\n", sdk: "27.1\n"),
                                     freeSpace: { _ in 29_000_000_000 })
        #expect(report.problems == ["less than 30 GB free on the library volume"])
    }

    @Test func freeBytesOfAMissingLibraryIsItsVolume() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ps4n-missing-\(UUID().uuidString)/library")
        #expect(Toolchain.freeBytes(at: missing) > 0)
    }

    @Test func shellReturnsStdoutAndThrowsOnFailure() throws {
        #expect(try Toolchain.shell("/bin/echo", ["hello"]) == "hello\n")
        #expect(throws: ToolchainError.failed("/usr/bin/false", 1)) { try Toolchain.shell("/usr/bin/false", []) }
    }
}
