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
        print("PASS: Core UTF-8 framing, oversized line recovery, and restart isolation")
    }
}
