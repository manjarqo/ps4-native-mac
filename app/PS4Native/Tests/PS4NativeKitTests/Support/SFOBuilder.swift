// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
@testable import PS4NativeKit

/// Mirrors pkg/sfo Build: entries sorted by key, strings 0x0204 with length+1 and max length aligned to 4, ints 0x0404.
enum SFOBuilder {
    static func build(_ entries: [(String, SFO.Value)]) -> Data {
        let es = entries.sorted { $0.0 < $1.0 }
        var keys = [UInt8](), data = [UInt8](), idx = [UInt8]()
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        for (key, value) in es {
            idx += le(keys.count, 2)
            keys += Array(key.utf8) + [0]
            switch value {
            case .int(let v):
                idx += le(0x0404, 2) + le(4, 4) + le(4, 4) + le(data.count, 4)
                data += le(Int(v), 4)
            case .string(let s):
                let bytes = Array(s.utf8)
                let n = bytes.count + 1, maxLen = (n + 3) & ~3
                idx += le(0x0204, 2) + le(n, 4) + le(maxLen, 4) + le(data.count, 4)
                data += bytes + [UInt8](repeating: 0, count: maxLen - bytes.count)
            }
        }
        while keys.count % 4 != 0 { keys.append(0) }
        let header = 20
        var out: [UInt8] = [0, 0x50, 0x53, 0x46]
        out += le(0x0101, 4) + le(header + idx.count, 4) + le(header + idx.count + keys.count, 4) + le(es.count, 4)
        return Data(out + idx + keys + data)
    }
}
