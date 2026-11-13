import Foundation
import Darwin

struct NativeTailscaleSnapshot: Equatable {
    let installed: Bool
    let connected: Bool
    let interfaceName: String
    let ipv4: String

    func directURL(remoteAddress: String?, fallbackPort: Int) -> String? {
        guard connected, !ipv4.isEmpty else { return nil }
        if let remote = remoteAddress, let parsed = URL(string: remote), let scheme = parsed.scheme {
            let port = parsed.port ?? fallbackPort
            return "\(scheme)://\(ipv4):\(port)"
        }
        return nil
    }
}

struct NativePowerSnapshot: Equatable, Sendable {
    let available: Bool
    let source: String
    let onBattery: Bool
    let upsPresent: Bool
    let deviceName: String
    let percent: Int
    let lowBattery: Bool

    var statusLabel: String {
        guard available else { return "等待采样" }
        if onBattery {
            return percent > 0 ? "备用供电 \(percent)%" : "备用电源供电"
        }
        return upsPresent ? "市电 + UPS 就绪" : "市电直供"
    }

    var detailLabel: String {
        guard available else { return "免驱动监控 pmset 电源状态" }
        if onBattery {
            return lowBattery ? "低电量保护已启动 · 转码停止并刷盘" : "已自动暂停后台 AI 索引"
        }
        if !deviceName.isEmpty {
            return "\(deviceName) · 断电守护就绪"
        }
        return "断电自动暂停高功耗任务并刷写 WAL"
    }
}

enum TailscaleAndUPSDetector {
    static func isCGNATIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        guard parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func parsePmsetBattOutput(_ raw: String) -> NativePowerSnapshot {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return NativePowerSnapshot(
                available: false,
                source: "unknown",
                onBattery: false,
                upsPresent: false,
                deviceName: "",
                percent: -1,
                lowBattery: false
            )
        }
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        let header = lines.first ?? ""
        let lowerHeader = header.lowercased()
        let source: String
        var onBattery = false
        var upsPresent = false
        if lowerHeader.contains("ups power") {
            source = "ups"
            onBattery = true
            upsPresent = true
        } else if lowerHeader.contains("battery power") {
            source = "battery"
            onBattery = true
        } else if lowerHeader.contains("ac power") {
            source = "ac"
        } else {
            source = "unknown"
        }

        var deviceName = ""
        var percent = -1
        for line in lines.dropFirst() {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry.hasPrefix("-") else { continue }
            if entry.lowercased().contains("ups") {
                upsPresent = true
            }
            let withoutDash = String(entry.dropFirst()).trimmingCharacters(in: .whitespaces)
            let namePart: String
            if let tabIdx = withoutDash.firstIndex(of: "\t") {
                namePart = String(withoutDash[..<tabIdx]).trimmingCharacters(in: .whitespaces)
            } else {
                namePart = withoutDash
            }
            if let parenIdx = namePart.firstIndex(of: "(") {
                deviceName = String(namePart[..<parenIdx]).trimmingCharacters(in: .whitespaces)
            } else if deviceName.isEmpty {
                deviceName = namePart
            }
            if let pctIdx = withoutDash.firstIndex(of: "%") {
                var start = pctIdx
                while start > withoutDash.startIndex {
                    let prev = withoutDash.index(before: start)
                    if withoutDash[prev].isNumber {
                        start = prev
                    } else {
                        break
                    }
                }
                if let val = Int(withoutDash[start..<pctIdx]), (0...100).contains(val) {
                    percent = val
                }
            }
            break
        }
        let lowBattery = onBattery && percent >= 0 && percent <= 25
        return NativePowerSnapshot(
            available: source != "unknown" || percent >= 0,
            source: source,
            onBattery: onBattery,
            upsPresent: upsPresent,
            deviceName: deviceName,
            percent: percent,
            lowBattery: lowBattery
        )
    }

    static func detectTailscale(
        appPaths: [String] = [
            "/Applications/Tailscale.app",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale"
        ]
    ) -> NativeTailscaleSnapshot {
        let fm = FileManager.default
        let appInstalled = appPaths.contains { fm.fileExists(atPath: $0) }
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        var foundIface = ""
        var foundIP = ""

        if getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr {
            defer { freeifaddrs(first) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            while let entry = cursor {
                let name = String(cString: entry.pointee.ifa_name)
                let flags = Int32(entry.pointee.ifa_flags)
                if (flags & IFF_UP) != 0,
                   (name.hasPrefix("utun") || name.lowercased().contains("tailscale")),
                   let addr = entry.pointee.ifa_addr,
                   addr.pointee.sa_family == sa_family_t(AF_INET) {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let ip = String(cString: hostname)
                        if isCGNATIPv4(ip) {
                            foundIface = name
                            foundIP = ip
                            break
                        }
                    }
                }
                cursor = entry.pointee.ifa_next
            }
        }

        let connected = !foundIP.isEmpty
        return NativeTailscaleSnapshot(
            installed: appInstalled || connected,
            connected: connected,
            interfaceName: foundIface,
            ipv4: foundIP
        )
    }

    static func currentPowerSnapshot() -> NativePowerSnapshot {
        let pmsetPath = "/usr/bin/pmset"
        guard FileManager.default.isExecutableFile(atPath: pmsetPath) else {
            return parsePmsetBattOutput("")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pmsetPath)
        proc.arguments = ["-g", "batt"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return parsePmsetBattOutput(text)
        } catch {
            return parsePmsetBattOutput("")
        }
    }
}
