// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

// The result objects of the engine's `done` events. Field names follow
// docs/game-manager-engine.md, "Results".

/// `inspect`: identity, kind, signing and sizes of a PKG or folder.
public struct InspectResult: Decodable, Sendable, Equatable {
    /// `game`, `patch`, `dlc` or `folder`.
    public let kind: String
    /// `fake`, `retail` or `none` (folders).
    public let signing: String
    public let titleID: String
    public let contentID: String
    public let title: String
    /// APP_VER, falling back to VERSION.
    public let appVer: String
    public let version: String
    public let category: String
    /// icon0.png extracted to the temp directory, "" when there is none.
    public let iconPath: String
    public let packedSize: Int64
    /// 0 for a retail PKG.
    public let unpackedSize: Int64

    enum CodingKeys: String, CodingKey {
        case kind, signing, title, version, category
        case titleID = "title_id", contentID = "content_id", appVer = "app_ver", iconPath = "icon_path"
        case packedSize = "packed_size", unpackedSize = "unpacked_size"
    }
}

/// `import`: what was added to the library.
public struct ImportResult: Decodable, Sendable, Equatable {
    public let titleID: String
    /// `game`, `patch` or `dlc`.
    public let kind: String
    /// The library entry after the import; absent for a pending patch.
    public let game: JSONValue?
    /// True for a patch stored until its base game arrives.
    public let pending: Bool

    /// `game` as a library record; nil when it is absent or null.
    public var gameRecord: GameRecord? {
        get throws {
            guard let game, game != .null else { return nil }
            return try JSONDecoder().decode(GameRecord.self, from: JSONEncoder().encode(game))
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, game, pending
        case titleID = "title_id"
    }
}

/// `analyze-game`: the support verdict and the analysis counters.
public struct GameAnalysis: Codable, Sendable, Equatable {
    public struct Verdict: Codable, Sendable, Equatable {
        /// `playable`, `in_progress`, `other_version` or `experimental`.
        public let status: String
        public let name: String
        // The engine sends null for an empty list or map; nil means empty.
        public let testedVersions: [String]?
        public let recommended: [String: Int]?
        public let knownIssues: [String]?

        enum CodingKeys: String, CodingKey {
            case status, name, recommended
            case testedVersions = "tested_versions", knownIssues = "known_issues"
        }
    }

    public let titleID: String
    public let title: String
    public let appVer: String
    public let category: String
    public let verdict: Verdict
    /// Percent of reachable code the analysis could lift.
    public let coverage: Double
    /// Unresolved HLE imports.
    public let unresolved: Int
    /// Unique x86 operations the lifter does not handle.
    public let missingOps: Int
    /// *.prx / *.sprx in sce_module/; nil means none.
    public let modules: [String]?

    enum CodingKeys: String, CodingKey {
        case title, category, verdict, coverage, unresolved, modules
        case titleID = "title_id", appVer = "app_ver", missingOps = "missing_ops"
    }
}

/// `build`: the signed bundle. With `--compile=false` only `builtWith` is present.
public struct BuildResult: Decodable, Sendable, Equatable {
    public let app: String?
    public let titleID: String?
    public let builtWith: String

    enum CodingKeys: String, CodingKey {
        case app
        case titleID = "title_id", builtWith = "built_with"
    }
}

/// `version`: the engine version and the Go toolchain it was built with.
public struct VersionResult: Decodable, Sendable, Equatable {
    public let version: String
    public let go: String
}
