// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

// library.json, docs/game-manager-engine.md, "Library" and "Schema". Fields this app does not
// know, at the top level or in a game, are kept in `extra` and written back unchanged.

public enum LibraryError: Error, Equatable, Sendable {
    /// library.json has a schema version newer than this app reads; it is never overwritten.
    case newerVersion(Int)
    /// Not a PS4 TITLE_ID (four capital letters and five digits); refused before any path is built.
    case badTitleID(String)
}

/// A JSON object key, for reading and writing every key of an object.
struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// The value at `key`, or `fallback` when the key is missing or null.
    func value<T: Decodable>(_ key: String, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: AnyKey(key)) ?? fallback
    }

    /// Every key not in `known`, as JSON values.
    func extra(excluding known: Set<String>) throws -> [String: JSONValue] {
        var extra: [String: JSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) {
            extra[key.stringValue] = try decode(JSONValue.self, forKey: key)
        }
        return extra
    }
}

extension KeyedEncodingContainer where Key == AnyKey {
    /// Writes the entries of `extra` whose keys are not in `known`, so that a known field always wins.
    mutating func encode(extra: [String: JSONValue], excluding known: Set<String>) throws {
        for (key, value) in extra where !known.contains(key) {
            try encode(value, forKey: AnyKey(key))
        }
    }
}

/// One game of library.json.
public struct GameRecord: Codable, Sendable, Equatable, Identifiable {
    public var titleID: String
    public var contentID: String
    public var title: String
    public var appVer: String
    public var version: String
    /// APP_VER of each applied patch; null in the file reads as empty.
    public var patches: [String]
    /// Entitlement labels under content/addcont; null in the file reads as empty.
    public var dlc: [String]
    public var contentBytes: Int64
    /// The support status written by the app from the analyze-game verdict; "" until then.
    public var status: String
    public var builtWith: String
    /// ISO-8601 when set, "" otherwise.
    public var lastPlayed: String
    public var playSeconds: Int64
    /// The fields of this game that this app does not know.
    public var extra: [String: JSONValue]

    public var id: String { titleID }

    public init(titleID: String, contentID: String = "", title: String = "", appVer: String = "", version: String = "",
                patches: [String] = [], dlc: [String] = [], contentBytes: Int64 = 0, status: String = "",
                builtWith: String = "", lastPlayed: String = "", playSeconds: Int64 = 0,
                extra: [String: JSONValue] = [:]) {
        self.titleID = titleID
        self.contentID = contentID
        self.title = title
        self.appVer = appVer
        self.version = version
        self.patches = patches
        self.dlc = dlc
        self.contentBytes = contentBytes
        self.status = status
        self.builtWith = builtWith
        self.lastPlayed = lastPlayed
        self.playSeconds = playSeconds
        self.extra = extra
    }

    static let knownKeys: Set<String> = [
        "title_id", "content_id", "title", "app_ver", "version", "patches", "dlc",
        "content_bytes", "status", "built_with", "last_played", "play_seconds",
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        titleID = try c.value("title_id", or: "")
        contentID = try c.value("content_id", or: "")
        title = try c.value("title", or: "")
        appVer = try c.value("app_ver", or: "")
        version = try c.value("version", or: "")
        patches = try c.value("patches", or: [])
        dlc = try c.value("dlc", or: [])
        contentBytes = try c.value("content_bytes", or: 0)
        status = try c.value("status", or: "")
        builtWith = try c.value("built_with", or: "")
        lastPlayed = try c.value("last_played", or: "")
        playSeconds = try c.value("play_seconds", or: 0)
        extra = try c.extra(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(extra: extra, excluding: Self.knownKeys)
        try c.encode(titleID, forKey: AnyKey("title_id"))
        try c.encode(contentID, forKey: AnyKey("content_id"))
        try c.encode(title, forKey: AnyKey("title"))
        try c.encode(appVer, forKey: AnyKey("app_ver"))
        try c.encode(version, forKey: AnyKey("version"))
        try c.encode(patches, forKey: AnyKey("patches"))
        try c.encode(dlc, forKey: AnyKey("dlc"))
        try c.encode(contentBytes, forKey: AnyKey("content_bytes"))
        try c.encode(status, forKey: AnyKey("status"))
        try c.encode(builtWith, forKey: AnyKey("built_with"))
        try c.encode(lastPlayed, forKey: AnyKey("last_played"))
        try c.encode(playSeconds, forKey: AnyKey("play_seconds"))
    }
}

/// The whole of library.json.
public struct LibraryFile: Codable, Sendable, Equatable {
    /// The schema version this app reads and writes.
    public static let currentVersion = 1

    /// The schema version; a missing `version` reads as 1.
    public var version: Int
    public var games: [GameRecord]
    /// The top-level fields that this app does not know.
    public var extra: [String: JSONValue]

    public init(version: Int = LibraryFile.currentVersion, games: [GameRecord] = [], extra: [String: JSONValue] = [:]) {
        self.version = version
        self.games = games
        self.extra = extra
    }

    static let knownKeys: Set<String> = ["version", "games"]

    /// Throws `LibraryError.newerVersion` for a file written for a newer schema.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        version = try c.value("version", or: 1)
        if version > Self.currentVersion { throw LibraryError.newerVersion(version) }
        games = try c.value("games", or: [])
        extra = try c.extra(excluding: Self.knownKeys)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(extra: extra, excluding: Self.knownKeys)
        try c.encode(version, forKey: AnyKey("version"))
        try c.encode(games, forKey: AnyKey("games"))
    }
}
