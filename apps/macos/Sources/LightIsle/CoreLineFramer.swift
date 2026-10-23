import Foundation

/// Frames Core stdout as UTF-8 *bytes*. read(2) can split a Chinese status
/// message in the middle of a Unicode scalar; decoding each chunk would
/// corrupt the message. A bounded line also prevents a malformed child from
/// growing the menu-bar application's memory without limit.
struct CoreLineFramer {
    static let maxLineBytes = 256 * 1024
    private var pending = Data()
    private var discardingOversizedLine = false
    private(set) var discardedLines = 0

    mutating func append(_ chunk: Data) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == 10 {  // LF
                if !discardingOversizedLine {
                    if pending.last == 13 { pending.removeLast() } // CRLF
                    lines.append(String(decoding: pending, as: UTF8.self))
                }
                pending.removeAll(keepingCapacity: true)
                discardingOversizedLine = false
            } else if !discardingOversizedLine {
                if pending.count >= Self.maxLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    discardingOversizedLine = true
                    discardedLines += 1
                } else {
                    pending.append(byte)
                }
            }
        }
        return lines
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        discardingOversizedLine = false
        discardedLines = 0
    }
}
