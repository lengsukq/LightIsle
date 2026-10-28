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
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let newline = chunk[start...].firstIndex(of: 10)
            let end = newline ?? chunk.endIndex
            if !discardingOversizedLine {
                if end - start > Self.maxLineBytes - pending.count {
                    pending.removeAll(keepingCapacity: false)
                    discardingOversizedLine = true
                    discardedLines += 1
                } else if pending.isEmpty, newline != nil {
                    // Most pipe reads contain complete lines. Decode directly
                    // from the input instead of copying every byte to Data.
                    let textEnd = end > start && chunk[end - 1] == 13 ? end - 1 : end
                    lines.append(String(decoding: chunk[start..<textEnd], as: UTF8.self))
                } else {
                    pending.append(contentsOf: chunk[start..<end])
                    if newline != nil {
                        if pending.last == 13 { pending.removeLast() } // CRLF
                        lines.append(String(decoding: pending, as: UTF8.self))
                        pending.removeAll(keepingCapacity: false)
                    }
                }
            }
            guard let newline else { break }
            if discardingOversizedLine {
                discardingOversizedLine = false
            }
            start = chunk.index(after: newline)
        }
        return lines
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: false)
        discardingOversizedLine = false
        discardedLines = 0
    }
}
