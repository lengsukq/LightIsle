import Foundation

struct FRPProxyDraft: Identifiable, Equatable {
    var id = UUID()
    var sourceSection: Int?
    var name = ""
    var type = "tcp"
    var localIP = "127.0.0.1"
    var localPort = "16666"
    var remotePort = ""
    var domains = ""

    var isWeb: Bool { type == "http" || type == "https" }
}

struct FRPConfigDraft: Equatable {
    var serverAddress = ""
    var serverPort = "7000"
    var token = ""
    var proxies: [FRPProxyDraft] = []
    var advancedProxyCount = 0
}

enum FRPConfigIssue: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        if case let .invalid(message) = self { return message }
        return nil
    }
}

/// A conservative TOML editor for the common frpc fields. Unrecognized keys,
/// comments, additional sections and unsupported proxy types are left intact.
/// The original file is never replaced merely because the editor was opened.
struct FRPConfigDocument {
    struct Section {
        var heading: String?
        var lines: [String]

        func value(_ key: String) throws -> String? {
            let matches = lines.compactMap { line -> String? in
                guard let index = line.firstIndex(of: "="),
                      line[..<index].trimmingCharacters(in: .whitespaces) == key else { return nil }
                return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
            }
            guard matches.count <= 1 else { throw FRPConfigIssue.invalid("配置文件存在重复的 \(key)，请先检查原文件。") }
            return matches.first
        }

        mutating func set(_ key: String, value: String) {
            if let index = lines.firstIndex(where: { line in
                guard let equals = line.firstIndex(of: "=") else { return false }
                return line[..<equals].trimmingCharacters(in: .whitespaces) == key
            }) {
                lines[index] = "\(key) = \(value)"
            } else {
                lines.append("\(key) = \(value)")
            }
        }
    }

    let original: String
    private let sections: [Section]
    let draft: FRPConfigDraft

    init(text: String) throws {
        original = text
        var parsed: [Section] = [Section(heading: nil, lines: [])]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && !trimmed.hasPrefix("#") {
                // TOML nested proxy sections are scoped to the preceding
                // proxy. Removing/reordering a proxy in a simple form could
                // silently re-parent those nested options to another proxy.
                guard !trimmed.hasPrefix("[proxies.") else {
                    throw FRPConfigIssue.invalid("包含代理插件或嵌套配置，请使用外部编辑器修改，避免误改高级规则。")
                }
                parsed.append(Section(heading: trimmed, lines: []))
            } else {
                parsed[parsed.count - 1].lines.append(line)
            }
        }
        sections = parsed
        var form = FRPConfigDraft()
        let global = parsed[0]
        form.serverAddress = try Self.string(global.value("serverAddr")) ?? ""
        form.serverPort = try Self.integer(global.value("serverPort")) ?? "7000"
        let authSection = parsed.first(where: { $0.heading == "[auth]" })
        let method = try Self.string(authSection?.value("method") ?? global.value("auth.method"))
        guard method == nil || method == "token" else {
            throw FRPConfigIssue.invalid("当前 FRP 使用非 Token 鉴权，请在外部编辑器中维护这份高级配置。")
        }
        form.token = try Self.string(authSection?.value("token") ?? global.value("auth.token")) ?? ""

        for (index, section) in parsed.enumerated() where section.heading == "[[proxies]]" {
            let type = try Self.string(section.value("type")) ?? ""
            guard ["tcp", "udp", "http", "https"].contains(type) else {
                form.advancedProxyCount += 1
                continue
            }
            let domains: String
            if let raw = try section.value("customDomains") {
                guard let decoded = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else {
                    form.advancedProxyCount += 1
                    continue
                }
                domains = decoded.joined(separator: ", ")
            } else {
                domains = ""
            }
            form.proxies.append(FRPProxyDraft(
                sourceSection: index,
                name: try Self.string(section.value("name")) ?? "",
                type: type,
                localIP: try Self.string(section.value("localIP")) ?? "127.0.0.1",
                localPort: try Self.integer(section.value("localPort")) ?? "",
                remotePort: try Self.integer(section.value("remotePort")) ?? "",
                domains: domains
            ))
        }
        draft = form
    }

    private static func string(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let candidate = raw.trimmingCharacters(in: .whitespaces)
        guard candidate.hasPrefix("\""), let end = closingQuote(in: candidate) else {
            throw FRPConfigIssue.invalid("配置中使用了尚不支持的字符串格式，请通过外部编辑器修改。")
        }
        let suffix = candidate[candidate.index(after: end)...].trimmingCharacters(in: .whitespaces)
        guard suffix.isEmpty || suffix.hasPrefix("#"),
              let decoded = try? JSONDecoder().decode(String.self, from: Data(candidate[...end].utf8)) else {
            throw FRPConfigIssue.invalid("配置文件中的字符串格式无效，请检查 TOML 文件。")
        }
        return decoded
    }

    private static func closingQuote(in value: String) -> String.Index? {
        var escaped = false
        for index in value.indices.dropFirst() {
            let char = value[index]
            if escaped { escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "\"" { return index }
        }
        return nil
    }

    private static func integer(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        let value = String(raw.split(separator: "#", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard Int(value) != nil else {
            throw FRPConfigIssue.invalid("端口必须为整数，原文件含有无法识别的配置。")
        }
        return value
    }

    static func quoted(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func validate(_ form: FRPConfigDraft) throws {
        let server = form.serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty, server.count <= 253, !server.contains("://"),
              !server.contains("REPLACE_WITH_"),
              !server.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "#" }) else {
            throw FRPConfigIssue.invalid("请输入 FRP 服务端域名或 IP（不需要 http://）。")
        }
        try port(form.serverPort, label: "服务端端口")
        guard !form.token.isEmpty, !form.token.contains("REPLACE_WITH_"),
              form.token.utf8.count <= 4096,
              !form.token.contains(where: { $0.isNewline }) else {
            throw FRPConfigIssue.invalid("请填写有效的 FRP 鉴权 Token。")
        }
        var names = Set<String>()
        for proxy in form.proxies {
            let name = proxy.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 64,
                  !name.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "#" }),
                  names.insert(name).inserted else {
                throw FRPConfigIssue.invalid("代理名称不能为空、不能重复或包含空格和特殊字符。")
            }
            guard ["tcp", "udp", "http", "https"].contains(proxy.type),
                  !proxy.localIP.isEmpty, proxy.localIP.count <= 253,
                  !proxy.localIP.contains(where: { $0.isWhitespace || $0 == "\"" }) else {
                throw FRPConfigIssue.invalid("代理 \(name) 的本地地址或类型无效。")
            }
            try port(proxy.localPort, label: "\(name) 的本地端口")
            if proxy.isWeb {
                let hosts = domainList(proxy.domains)
                guard !hosts.isEmpty, hosts.allSatisfy({
                    !$0.contains("://") &&
                    !$0.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "#" })
                }) else {
                    throw FRPConfigIssue.invalid("HTTP/HTTPS 代理 \(name) 需要至少一个访问域名。")
                }
            } else {
                try port(proxy.remotePort, label: "\(name) 的远程端口")
            }
        }
    }

    private static func port(_ value: String, label: String) throws {
        guard let number = Int(value), (1...65535).contains(number) else {
            throw FRPConfigIssue.invalid("\(label) 必须在 1–65535 之间。")
        }
    }

    private static func domainList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func render(_ form: FRPConfigDraft) throws -> String {
        try Self.validate(form)
        let newNames = Set(form.proxies.map(\.name))
        for (index, section) in sections.enumerated() where section.heading == "[[proxies]]" {
            if !draft.proxies.contains(where: { $0.sourceSection == index }),
               let advancedName = try Self.string(section.value("name")),
               newNames.contains(advancedName) {
                throw FRPConfigIssue.invalid("代理名称与现有高级规则重复，请更换名称。")
            }
        }
        var output = sections
        output[0].set("serverAddr", value: Self.quoted(form.serverAddress.trimmingCharacters(in: .whitespaces)))
        output[0].set("serverPort", value: form.serverPort)
        if let authIndex = output.firstIndex(where: { $0.heading == "[auth]" }) {
            output[authIndex].set("method", value: Self.quoted("token"))
            output[authIndex].set("token", value: Self.quoted(form.token))
        } else {
            output[0].set("auth.method", value: Self.quoted("token"))
            output[0].set("auth.token", value: Self.quoted(form.token))
        }
        let selected = Dictionary(uniqueKeysWithValues: form.proxies.compactMap { proxy -> (Int, FRPProxyDraft)? in
            guard let index = proxy.sourceSection else { return nil }
            return (index, proxy)
        })
        var merged: [Section] = []
        for (index, var section) in output.enumerated() {
            if section.heading == "[[proxies]]" {
                guard let proxy = selected[index] else {
                    // A proxy not represented by the simple editor is an
                    // advanced proxy. Preserve it verbatim.
                    if !draft.proxies.contains(where: { $0.sourceSection == index }) {
                        merged.append(section)
                    }
                    continue
                }
                section.set("name", value: Self.quoted(proxy.name))
                section.set("type", value: Self.quoted(proxy.type))
                section.set("localIP", value: Self.quoted(proxy.localIP))
                section.set("localPort", value: proxy.localPort)
                if proxy.isWeb {
                    section.lines.removeAll(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("remotePort =") })
                    let domains = Self.domainList(proxy.domains)
                    section.set("customDomains", value: "[" + domains.map(Self.quoted).joined(separator: ", ") + "]")
                } else {
                    section.lines.removeAll(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("customDomains =") })
                    section.set("remotePort", value: proxy.remotePort)
                }
            }
            merged.append(section)
        }
        for proxy in form.proxies where proxy.sourceSection == nil {
            var section = Section(heading: "[[proxies]]", lines: [])
            section.set("name", value: Self.quoted(proxy.name))
            section.set("type", value: Self.quoted(proxy.type))
            section.set("localIP", value: Self.quoted(proxy.localIP))
            section.set("localPort", value: proxy.localPort)
            if proxy.isWeb {
                section.set("customDomains", value: "[" + Self.domainList(proxy.domains).map(Self.quoted).joined(separator: ", ") + "]")
            } else {
                section.set("remotePort", value: proxy.remotePort)
            }
            merged.append(section)
        }
        return merged.map { section in
            ([section.heading].compactMap { $0 } + section.lines).joined(separator: "\n")
        }.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }
}

enum FRPConfigFile {
    private static func checkedURL(_ path: String) throws -> URL {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw FRPConfigIssue.invalid("无法找到 Mac 的应用配置目录。")
        }
        let expected = support.appendingPathComponent("LightIsle/frp/frpc.toml").standardizedFileURL
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url == expected, url.resolvingSymlinksInPath() == expected.resolvingSymlinksInPath(),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FRPConfigIssue.invalid("配置文件路径不安全或文件不存在，请从 FRP 管理页刷新状态。")
        }
        return url
    }

    static func load(path: String) throws -> FRPConfigDocument {
        let url = try checkedURL(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576,
              let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw FRPConfigIssue.invalid("FRP 配置文件过大或不是 UTF-8 文本，无法安全打开。")
        }
        return try FRPConfigDocument(text: text)
    }

    static func save(path: String, document: FRPConfigDocument, draft: FRPConfigDraft) throws {
        let url = try checkedURL(path)
        guard let previous = String(data: try Data(contentsOf: url), encoding: .utf8),
              previous == document.original else {
            throw FRPConfigIssue.invalid("配置文件已被其他程序修改，请重新打开页面，避免覆盖外部改动。")
        }
        let updated = try document.render(draft)
        guard updated.utf8.count <= 1_048_576 else {
            throw FRPConfigIssue.invalid("配置文件超过 1 MiB，未保存。")
        }
        try Data(updated.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
