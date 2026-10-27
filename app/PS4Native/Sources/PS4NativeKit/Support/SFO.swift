// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

public enum SFOError: Error, Equatable, Sendable {
    case badMagic, truncated, unknownFormat(String)
}

/// A PS4 param.sfo (the PSF key/value format in sce_sys/). See docs/game-manager-engine.md.
public struct SFO: Sendable, Equatable {
    public enum Value: Sendable, Equatable { case string(String), int(UInt32) }
    public let values: [String: Value]

    public init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

    public init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 20, b[0] == 0, b[1] == 0x50, b[2] == 0x53, b[3] == 0x46 else { throw SFOError.badMagic }
        func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let keyTab = u32(8), dataTab = u32(12), n = u32(16)
        guard 20 + n * 16 <= b.count, keyTab <= b.count, dataTab <= b.count else { throw SFOError.truncated }
        var out: [String: Value] = [:]
        for i in 0..<n {
            let e = 20 + i * 16
            let keyOff = keyTab + u16(e), format = u16(e + 2), len = u32(e + 4), dataOff = dataTab + u32(e + 12)
            guard keyOff < b.count, dataOff + len <= b.count,
                  let end = b[keyOff...].firstIndex(of: 0) else { throw SFOError.truncated }
            let key = String(decoding: b[keyOff..<end], as: UTF8.self)
            switch format {
            case 0x0404:
                guard len >= 4 else { throw SFOError.truncated }
                out[key] = .int(UInt32(u32(dataOff)))
            case 0x0204, 0x0004:
                var s = b[dataOff..<(dataOff + len)]
                while s.last == 0 { s = s.dropLast() }
                out[key] = .string(String(decoding: s, as: UTF8.self))
            default:
                throw SFOError.unknownFormat(key)
            }
        }
        values = out
    }

    public func string(_ key: String) -> String? {
        if case .string(let s)? = values[key] { return s }
        return nil
    }

    public func int(_ key: String) -> UInt32? {
        if case .int(let v)? = values[key] { return v }
        return nil
    }

    public var title: String? { string("TITLE") }
    public var titleID: String? { string("TITLE_ID") }
    public var category: String? { string("CATEGORY") }

    /// APP_VER, falling back to VERSION when APP_VER is absent or empty (the engine's version rule).
    public var appVersion: String? {
        if let v = string("APP_VER"), !v.isEmpty { return v }
        return string("VERSION")
    }
}

/// The metadata of a save slot, sce_sys/param.bin as the runtime writes it (ps4_savedata.c SdParam).
public struct SaveParam: Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let detail: String
    public let modified: Date?

    public init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count >= 1296 else { throw SFOError.truncated }
        func cstr(_ range: Range<Int>) -> String {
            let s = b[range]
            let end = s.firstIndex(of: 0) ?? range.upperBound
            return String(decoding: b[range.lowerBound..<end], as: UTF8.self)
        }
        title = cstr(0..<128)
        subtitle = cstr(128..<256)
        detail = cstr(256..<1280)
        var t: Int64 = 0
        for i in 0..<8 { t |= Int64(b[1288 + i]) << (8 * i) }
        modified = t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
    }
}
