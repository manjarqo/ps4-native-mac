// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One line of an engine `--json` stream. See docs/game-manager-engine.md, "Events".
/// The `result` of a `done` event is not decoded here: `EngineRun` keeps the raw line and
/// decodes it into the command's result type.
public struct EngineEvent: Decodable, Sendable, Equatable {
    public enum Kind: String, Decodable, Sendable { case progress, warning, error, done }

    public let event: Kind
    public let op: String
    /// Stage name, on progress events.
    public let stage: String?
    /// Counters, on progress events; `unit` is `bytes`, `files` or `stages`.
    public let done: Int64?
    public let total: Int64?
    public let unit: String?
    /// Machine-readable reason, on error events (see "Error codes").
    public let code: String?
    public let message: String?

    public init(event: Kind, op: String, stage: String? = nil, done: Int64? = nil, total: Int64? = nil,
                unit: String? = nil, code: String? = nil, message: String? = nil) {
        self.event = event
        self.op = op
        self.stage = stage
        self.done = done
        self.total = total
        self.unit = unit
        self.code = code
        self.message = message
    }
}
