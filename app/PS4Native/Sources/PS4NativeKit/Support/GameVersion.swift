// SPDX-License-Identifier: GPL-2.0-or-later

/// How a content version (APP_VER or VERSION of param.sfo) is shown.
public enum GameVersion {
    /// "01.05" as "v1.05": the SFO's zero-padded major without its padding; "v?" when empty.
    public static func display(_ v: String) -> String {
        guard !v.isEmpty else { return "v?" }
        var s = Substring(v)
        while s.count > 1, s.first == "0", s.dropFirst().first?.isNumber == true { s = s.dropFirst() }
        return "v" + s
    }
}
