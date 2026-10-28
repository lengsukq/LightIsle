import Foundation

@main
struct CoreLineFramerCheck {
    static func main() {
        var framer = CoreLineFramer()
        let data = Data("LIGHTISLE_SHARE_ERROR 磁盘已断开\nLIGHTISLE_READY http://127.0.0.1:16666\n".utf8)
        var lines: [String] = []
        for byte in data {
            lines += framer.append(Data([byte]))
        }
        precondition(lines == [
            "LIGHTISLE_SHARE_ERROR 磁盘已断开",
            "LIGHTISLE_READY http://127.0.0.1:16666"
        ], "split UTF-8 bytes corrupted the message")

        let big = Data(repeating: 0x61, count: CoreLineFramer.maxLineBytes + 1024)
        precondition(framer.append(big).isEmpty, "oversized partial line delivered")
        precondition(framer.discardedLines == 1, "oversized line was not rejected")
        precondition(framer.append(Data("\nLIGHTISLE_CONFIGURED 1\n".utf8)) == [
            "LIGHTISLE_CONFIGURED 1"
        ], "oversized line corrupted the following valid message")
        framer.reset()
        precondition(framer.append(Data("old-fragment".utf8)).isEmpty)
        framer.reset()
        precondition(framer.append(Data("LIGHTISLE_READY ok\r\n".utf8)) == [
            "LIGHTISLE_READY ok"
        ], "old process fragment crossed the reset boundary")

        // Boundary length, empty lines, CRLF split between reads, and Data
        // slices with nonzero indices must behave identically to a pipe read.
        framer.reset()
        let boundary = Data(repeating: 0x61, count: CoreLineFramer.maxLineBytes)
        precondition(framer.append(boundary).isEmpty)
        precondition(framer.append(Data("\n\n\r".utf8)) == [String(decoding: boundary, as: UTF8.self), ""])
        precondition(framer.append(Data("\n".utf8)) == [""])
        let sliced = Data("skip状态正常\nsecond\n".utf8).dropFirst(4)
        precondition(framer.append(sliced) == ["状态正常", "second"])
        framer.reset()
        precondition(framer.append(boundary).isEmpty)
        precondition(framer.append(Data("b\nvalid\n".utf8)) == ["valid"])
        precondition(framer.discardedLines == 1)

        // Check every split position, including splits inside a UTF-8 scalar.
        let messages = Data("状态正常\r\n\nnext\n".utf8)
        for split in 0...messages.count {
            framer.reset()
            let first = framer.append(messages.prefix(split))
            let second = framer.append(messages.dropFirst(split))
            precondition(first + second == ["状态正常", "", "next"])
        }
        print("PASS: Core UTF-8 framing, oversized line recovery, and restart isolation")

        if CommandLine.arguments.contains("--benchmark") {
            // Synthetic stats-sized IPC lines; excludes payload construction
            // and runs with the same optimized compiler settings before/after.
            let payload = Data(("LIGHTISLE_STATS " + String(repeating: "a", count: 32 * 1024) + "\n").utf8)
            let iterations = 2_000
            var delivered = 0
            var decodedBytes = 0
            let start = ContinuousClock.now
            for _ in 0..<iterations {
                let result = framer.append(payload)
                delivered += result.count
                for line in result { decodedBytes += line.utf8.count }
            }
            precondition(delivered == iterations)
            precondition(decodedBytes == (payload.count - 1) * iterations)
            print("IPC benchmark: \(iterations) x \(payload.count) bytes, \(start.duration(to: .now))")
        }
    }
}
