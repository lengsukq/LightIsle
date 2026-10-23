import Foundation
import Darwin
import Dispatch

// Optional, Mac-local integration. Never expose the Docker socket through
// Go HTTP/IPC or start an engine merely because LightIsle was opened.
struct DockerMirrorPreset: Identifiable {
    let id: String
    let title: String
    let url: String
    let note: String

    static let catalog: [DockerMirrorPreset] = [
        .init(id: "one-ms", title: "毫秒镜像 · 公网候选",
              url: "https://docker.1ms.run",
              note: "第三方公共服务，可能限流或更改政策；请勿用于私有镜像凭据。"),
        .init(id: "daocloud", title: "DaoCloud · Docker Hub",
              url: "https://docker.m.daocloud.io",
              note: "透明加速的公共候选，可能有镜像白名单与速率限制。"),
        .init(id: "aliyun", title: "阿里云 ACR · 专属地址",
              url: "", note: "在 ACR 控制台获取个人专属地址；官方已提示停止同步新镜像。"),
        .init(id: "tencent", title: "腾讯云 · 仅云内网",
              url: "https://mirror.ccs.tencentyun.com",
              note: "只适用于腾讯云内网；普通家庭 Mac 不应选择这个地址。")
    ]
}

enum DockerMirrorProbe {
    // No network call is made until the user explicitly clicks "测试连接".
    // HEAD /v2/ indicates reachability only; it cannot prove a tag is fresh
    // or that a full Docker Hub image pull will succeed.
    static func check(_ input: String) async throws -> String {
        let base = try DockerMirrorConfig.validate(input)
        guard let url = URL(string: base + "/v2/") else {
            throw DockerConfigurationError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DockerConfigurationError.command("镜像地址没有返回 HTTP 响应")
        }
        switch http.statusCode {
        case 200, 401:
            return "连接检测成功（HTTP \(http.statusCode)）。仍需实际 docker pull 验证镜像可用性。"
        case 429:
            return "镜像服务可以连接，但返回 HTTP 429 限流；不建议现在应用。"
        case 403:
            return "镜像服务拒绝请求（HTTP 403），可能有限制区域或镜像白名单。"
        default:
            return "已连接，但返回 HTTP \(http.statusCode)；暂时无法确认此服务可作为 Docker Hub 加速器。"
        }
    }
}

enum DockerConfigurationError: LocalizedError {
    case invalidURL, unsafePath, tooLarge, invalidJSON, unsupportedYAML, unavailable, command(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "镜像源必须为无账号、无路径的 HTTPS 地址。"
        case .unsafePath: return "Docker 配置文件或父目录是符号链接/非普通文件，已拒绝修改。"
        case .tooLarge: return "配置文件超出安全读取上限（256 KiB）。"
        case .invalidJSON: return "现有 daemon.json 不是 JSON 对象，已保留原文件。"
        case .unsupportedYAML: return "Colima YAML 结构无法安全自动合并，请改用 colima start --edit。"
        case .unavailable: return "未发现可用的本地 Docker CLI 或 Colima 配置。"
        case .command(let message): return message
        }
    }
}

enum DockerMirrorConfig {
    static func validate(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: trimmed),
              url.scheme == "https", let host = url.host,
              host.count >= 4, host.contains("."),
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.port == nil || url.port == 443,
              !host.contains(".."),
              !["localhost", "127.0.0.1", "::1"].contains(host.lowercased()) else {
            throw DockerConfigurationError.invalidURL
        }
        return "https://" + host.lowercased() + (url.port == 443 ? ":443" : "")
    }

    static func daemonJSON(_ existing: Data?, mirror: String) throws -> Data {
        let source = existing ?? Data("{}".utf8)
        guard source.count <= 262_144 else { throw DockerConfigurationError.tooLarge }
        guard var json = (try? JSONSerialization.jsonObject(with: source)) as? [String: Any] else {
            throw DockerConfigurationError.invalidJSON
        }
        json["registry-mirrors"] = [try validate(mirror)]
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
    }

    // Narrow and defensive YAML edit: only known scalar docker: / docker: {}
    // forms are accepted. Keep unrelated Colima resources and options intact.
    static func colimaYAML(_ current: String, mirror: String) throws -> String {
        guard current.utf8.count <= 262_144, !current.contains("\t"),
              !current.contains("\r") else { throw DockerConfigurationError.unsupportedYAML }
        let endpoint = try validate(mirror)
        var lines = current.components(separatedBy: "\n")
        let roots = lines.indices.filter {
            let line = lines[$0].trimmingCharacters(in: .whitespaces)
            return !line.hasPrefix("#") && (line == "docker:" || line == "docker: {}")
                && lines[$0] == line
        }
        guard roots.count == 1, let root = roots.first else { throw DockerConfigurationError.unsupportedYAML }
        let otherDockerRoots = lines.indices.filter {
            lines[$0].hasPrefix("docker:") && !lines[$0].hasPrefix("docker: #")
        }
        guard otherDockerRoots.count == 1 else { throw DockerConfigurationError.unsupportedYAML }
        if lines[root] == "docker: {}" {
            lines[root] = "docker:"
            lines.insert(contentsOf: ["  registry-mirrors:", "    - " + endpoint], at: root + 1)
            return lines.joined(separator: "\n")
        }
        var end = root + 1
        while end < lines.count {
            let line = lines[end]
            if !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("#") { break }
            end += 1
        }
        let mirrorKeys = (root + 1..<end).filter {
            lines[$0].hasPrefix("  registry-mirrors:")
        }
        guard mirrorKeys.count <= 1 else { throw DockerConfigurationError.unsupportedYAML }
        if let start = mirrorKeys.first {
            guard lines[start].trimmingCharacters(in: .whitespaces) == "registry-mirrors:" else {
                throw DockerConfigurationError.unsupportedYAML
            }
            var stop = start + 1
            while stop < end {
                let line = lines[stop]
                if line.hasPrefix("  ") && !line.hasPrefix("    ") && !line.trimmingCharacters(in: .whitespaces).isEmpty { break }
                stop += 1
            }
            lines.removeSubrange(start..<stop)
        }
        lines.insert(contentsOf: ["  registry-mirrors:", "    - " + endpoint], at: root + 1)
        return lines.joined(separator: "\n")
    }
}

struct DockerContainer: Identifiable {
    let id: String
    let name: String
    let image: String
    let status: String
    let state: String
}

struct DockerImage: Identifiable {
    let id: String
    let repository: String
    let tag: String
    let size: String
}

struct DockerSnapshot {
    let context: String
    let engineVersion: String
    let containers: [DockerContainer]
    let images: [DockerImage]
    let registryMirrors: [String]
}

enum DockerLocalRuntime {
    private enum CommandStopReason {
        case timedOut
        case outputLimit
        case pipeRead(String)
        case inheritedPipe
    }

    private static let commandOutputLimit = 1_000_000
    private static let commandOutputChunkSize = 16 * 1024
    private static let commandOutputReadBudgetPerStream = 64 * 1024
    private static let commandStopGrace: UInt64 = 500_000_000
    private static let inheritedPipeGrace: UInt64 = 1_000_000_000

    static let supportedContexts = ["desktop-linux", "colima"]
    static let binaryPaths = [
        "/opt/homebrew/bin/docker", "/usr/local/bin/docker",
        NSHomeDirectory() + "/.docker/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker"
    ]

    static func executable() -> URL? {
        for location in binaryPaths where FileManager.default.isExecutableFile(atPath: location) {
            return URL(fileURLWithPath: location)
        }
        return nil
    }

    static func run(_ args: [String], deadline: TimeInterval = 10) throws -> String {
        guard let binary = executable() else { throw DockerConfigurationError.unavailable }
        return try run(binary: binary, args: args, deadline: deadline)
    }

    // The explicit executable overload is an internal seam for local regression
    // tests. Production callers continue to use the allow-listed executable().
    static func run(_ args: [String], executable: URL, deadline: TimeInterval = 10) throws -> String {
        try run(binary: executable, args: args, deadline: deadline)
    }

    private static func run(binary: URL, args: [String], deadline: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutReader = stdoutPipe.fileHandleForReading
        let stderrReader = stderrPipe.fileHandleForReading
        let stdoutWriter = stdoutPipe.fileHandleForWriting
        let stderrWriter = stderrPipe.fileHandleForWriting
        defer {
            try? stdoutReader.close()
            try? stderrReader.close()
            try? stdoutWriter.close()
            try? stderrWriter.close()
        }
        guard setNonBlocking(stdoutReader.fileDescriptor),
              setNonBlocking(stderrReader.fileDescriptor) else {
            throw DockerConfigurationError.command("无法为 Docker 命令建立安全的输出管道。")
        }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var env = ProcessInfo.processInfo.environment
        // The native feature must never inherit a remote Docker endpoint.
        env.removeValue(forKey: "DOCKER_HOST")
        env.removeValue(forKey: "DOCKER_CONTEXT")
        env.removeValue(forKey: "DOCKER_TLS_VERIFY")
        env.removeValue(forKey: "DOCKER_CERT_PATH")
        env.removeValue(forKey: "DOCKER_API_VERSION")
        // An inherited COMPOSE_PROFILES can silently start extra services,
        // even when the explicitly selected compose file is unchanged.
        for key in env.keys.filter({ $0.hasPrefix("COMPOSE_") }) {
            env.removeValue(forKey: key)
        }
        process.environment = env
        try process.run()

        // The parent must close its copies of the pipe write ends or EOF will
        // never reach the readers after the child exits.
        try? stdoutWriter.close()
        try? stderrWriter.close()

        let processExited = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            processExited.signal()
        }

        var descriptors = [
            pollfd(fd: stdoutReader.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
            pollfd(fd: stderrReader.fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        ]
        var streamOpen = [true, true]
        let readers = [stdoutReader, stderrReader]
        var captured = Data()
        captured.reserveCapacity(commandOutputLimit)
        var stopReason: CommandStopReason?
        var stopSentAt: UInt64?
        var forceKillSent = false
        var childHasExited = false
        var childExitSeenAt: UInt64?

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let durationNanos: UInt64
        if deadline.isFinite && deadline > 0 {
            durationNanos = UInt64(min(deadline * 1_000_000_000, Double(UInt64.max / 2)))
        } else {
            durationNanos = 0
        }
        let deadlineAt = startedAt &+ durationNanos

        func requestStop(_ reason: CommandStopReason) {
            guard stopReason == nil else { return }
            stopReason = reason
            guard process.isRunning else { return }
            process.terminate()
            stopSentAt = DispatchTime.now().uptimeNanoseconds
        }

        func closeStream(_ index: Int) {
            guard streamOpen[index] else { return }
            streamOpen[index] = false
            descriptors[index].fd = -1
            try? readers[index].close()
        }

        while streamOpen.contains(true) || !childHasExited {
            let now = DispatchTime.now().uptimeNanoseconds
            if !childHasExited && stopReason == nil && now >= deadlineAt {
                requestStop(.timedOut)
            }
            if let sentAt = stopSentAt, !forceKillSent,
               now >= sentAt && now - sentAt >= commandStopGrace {
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
                forceKillSent = true
            }
            if childHasExited, let exitedAt = childExitSeenAt,
               streamOpen.contains(true), now >= exitedAt,
               now - exitedAt >= inheritedPipeGrace {
                if stopReason == nil { stopReason = .inheritedPipe }
                for index in readers.indices { closeStream(index) }
            }

            let pollResult = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), 50)
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                requestStop(.pipeRead("poll: \(String(cString: strerror(errno)))"))
                for index in readers.indices { closeStream(index) }
            } else if pollResult > 0 {
                for index in readers.indices where streamOpen[index] {
                    let ready = descriptors[index].revents
                    guard ready & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 else { continue }
                    var drainedThisPass = 0
                    while streamOpen[index] && drainedThisPass < commandOutputReadBudgetPerStream {
                        var chunk = [UInt8](repeating: 0, count: commandOutputChunkSize)
                        let bytesRead = chunk.withUnsafeMutableBytes { rawBuffer in
                            Darwin.read(descriptors[index].fd, rawBuffer.baseAddress, rawBuffer.count)
                        }
                        if bytesRead > 0 {
                            drainedThisPass += bytesRead
                            if stopReason == nil {
                                let available = commandOutputLimit - captured.count
                                if bytesRead > available {
                                    if available > 0 { captured.append(contentsOf: chunk.prefix(available)) }
                                    requestStop(.outputLimit)
                                } else {
                                    captured.append(contentsOf: chunk.prefix(bytesRead))
                                }
                            }
                            continue
                        }
                        if bytesRead == 0 {
                            closeStream(index)
                            break
                        }
                        if errno == EINTR { continue }
                        if errno == EAGAIN || errno == EWOULDBLOCK { break }
                        requestStop(.pipeRead("read: \(String(cString: strerror(errno)))"))
                        closeStream(index)
                    }
                }
            }

            if !childHasExited, processExited.wait(timeout: .now()) == .success {
                childHasExited = true
                childExitSeenAt = DispatchTime.now().uptimeNanoseconds
            }
        }

        let preview = String(decoding: captured, as: UTF8.self)
        switch stopReason {
        case .timedOut:
            throw DockerConfigurationError.command("Docker 命令超时，已停止进程。")
        case .outputLimit:
            throw DockerConfigurationError.command("Docker 命令输出超过安全上限（1 MiB），已停止进程。")
        case .pipeRead(let details):
            throw DockerConfigurationError.command("读取 Docker 命令输出失败：\(details)")
        case .inheritedPipe:
            throw DockerConfigurationError.command("Docker 命令退出后仍有子进程占用输出管道，已关闭输出并清理。")
        case nil:
            break
        }

        guard process.terminationStatus == 0 else {
            let details = String(preview.prefix(350)).trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = details.isEmpty ? "" : "：\(details)"
            throw DockerConfigurationError.command("Docker 命令失败（退出码 \(process.terminationStatus)）\(suffix)")
        }
        return preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func setNonBlocking(_ fileDescriptor: Int32) -> Bool {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0 else { return false }
        return fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    static func verifiedContext(_ selected: String) throws -> String {
        guard supportedContexts.contains(selected) else { throw DockerConfigurationError.unavailable }
        let result = try run(["context", "inspect", selected, "--format", "{{json .Endpoints.docker.Host}}"])
        guard let data = result.data(using: .utf8),
              let host = try? JSONDecoder().decode(String.self, from: data),
              host.hasPrefix("unix://"), !host.contains("\n"),
              let location = URL(string: host)?.path, !location.isEmpty,
              location.hasPrefix("/"), !location.contains("/../"),
              (location == "/var/run/docker.sock" ||
               location.hasPrefix(NSHomeDirectory() + "/.colima/") ||
               location.hasPrefix(NSHomeDirectory() + "/.docker/")) else {
            throw DockerConfigurationError.command("Docker Context 并非受支持的本机 Unix Socket；拒绝管理远程引擎。")
        }
        return selected
    }

    static func inspect(_ selected: String) throws -> DockerSnapshot {
        let context = try verifiedContext(selected)
        let version = try run(["--context", context, "info", "--format", "{{.ServerVersion}}"])
        let output = try run(["--context", context, "ps", "--all", "--no-trunc", "--format", "{{json .}}"])
        let containers = try output.split(separator: "\n").map { line -> DockerContainer in
            guard let data = String(line).data(using: .utf8),
                  let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = item["ID"] as? String, let name = item["Names"] as? String,
                  let image = item["Image"] as? String else {
                throw DockerConfigurationError.command("Docker 容器列表格式异常")
            }
            return DockerContainer(id: id, name: name, image: image,
                                   status: item["Status"] as? String ?? "未知",
                                   state: item["State"] as? String ?? "")
        }
        let imageOutput = try run(["--context", context, "image", "ls", "--no-trunc", "--format", "{{json .}}"])
        let images = try imageOutput.split(separator: "\n").map { line -> DockerImage in
            guard let data = String(line).data(using: .utf8),
                  let item = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = item["ID"] as? String else {
                throw DockerConfigurationError.command("Docker 镜像列表格式异常")
            }
            let repo = item["Repository"] as? String ?? "<none>"
            let tag = item["Tag"] as? String ?? "<none>"
            return DockerImage(id: id + ":" + repo + ":" + tag,
                               repository: repo, tag: tag,
                               size: item["Size"] as? String ?? "")
        }
        let mirrorResult = try run(["--context", context, "info", "--format", "{{json .RegistryConfig.Mirrors}}"])
        let mirrors = (try? JSONDecoder().decode([String].self, from: Data(mirrorResult.utf8))) ?? []
        return DockerSnapshot(context: context, engineVersion: version,
                              containers: containers, images: images, registryMirrors: mirrors)
    }

    static func operate(_ action: String, container: DockerContainer, context: String) throws {
        guard ["start", "stop", "restart"].contains(action),
              container.id.count >= 12, container.id.count <= 64,
              container.id.allSatisfy({ $0.isHexDigit }) else {
            throw DockerConfigurationError.command("无效的容器操作")
        }
        let context = try verifiedContext(context)
        _ = try run(["--context", context, action, container.id], deadline: 30)
    }
}

enum DockerMirrorWriter {
    // Refuse to edit symlinked configuration paths, preserve unrelated keys
    // and create a local backup before an exclusive temporary-file rename.
    private static func writePrivateNewFile(_ data: Data, at path: URL) throws {
        let descriptor = Darwin.open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var complete = false
        defer {
            _ = Darwin.close(descriptor)
            if !complete { try? FileManager.default.removeItem(at: path) }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                if count <= 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += count
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        complete = true
    }

    static func read(_ url: URL, root: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws -> Data? {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let home = root.standardizedFileURL
        var ancestor = parent.standardizedFileURL
        var chain: [URL] = []
        while ancestor.path != home.path {
            guard ancestor.path.hasPrefix(home.path + "/") else {
                throw DockerConfigurationError.unsafePath
            }
            chain.append(ancestor)
            ancestor = ancestor.deletingLastPathComponent()
        }
        // Do not traverse even a parent-of-parent symlink (e.g. ~/.colima
        // pointing to an unexpected volume). The backup and write must act
        // strictly within the selected user's real home.
        for component in chain.reversed() {
            if (try? fm.destinationOfSymbolicLink(atPath: component.path)) != nil {
                throw DockerConfigurationError.unsafePath
            }
        }
        if fm.fileExists(atPath: parent.path) {
            let kind = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard kind.isDirectory == true && kind.isSymbolicLink != true else {
                throw DockerConfigurationError.unsafePath
            }
        } else {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            throw DockerConfigurationError.unsafePath
        }
        if fm.fileExists(atPath: url.path) {
            let kind = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard kind.isRegularFile == true && kind.isSymbolicLink != true else {
                throw DockerConfigurationError.unsafePath
            }
            guard (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0 <= 262_144 else {
                throw DockerConfigurationError.tooLarge
            }
            return try Data(contentsOf: url)
        }
        return nil
    }

    static func write(_ data: Data, to url: URL,
                      root: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws -> String {
        guard data.count <= 262_144 else { throw DockerConfigurationError.tooLarge }
        let original = try read(url, root: root)
        let directory = url.deletingLastPathComponent()
        var backupName = "无旧配置"
        if let original {
            let backup = directory.appendingPathComponent(
                url.lastPathComponent + ".lightisle-backup-" + UUID().uuidString)
            // Private files must never be briefly created world-readable.
            try writePrivateNewFile(original, at: backup)
            backupName = backup.lastPathComponent
        }
        let stage = directory.appendingPathComponent(".lightisle-" + UUID().uuidString + ".tmp")
        try writePrivateNewFile(data, at: stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        // POSIX rename is atomic within the same parent filesystem.
        if rename(stage.path, url.path) != 0 {
            throw DockerConfigurationError.command("无法替换镜像配置，原配置已保留。")
        }
        let fd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 {
            defer { _ = Darwin.close(fd) }
            if Darwin.fsync(fd) != 0 {
                throw DockerConfigurationError.command("配置已写入，但父目录持久化同步失败，请检查备份：" + backupName)
            }
        }
        return backupName
    }

    static func apply(mirror: String, toColima: Bool) throws -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let host = home.appendingPathComponent(".docker/daemon.json")
        let hostJSON = try DockerMirrorConfig.daemonJSON(read(host), mirror: mirror)
        if toColima {
            let guest = home.appendingPathComponent(".colima/default/colima.yaml")
            guard let old = try read(guest), let yaml = String(data: old, encoding: .utf8) else {
                throw DockerConfigurationError.unavailable
            }
            let updated = try DockerMirrorConfig.colimaYAML(yaml, mirror: mirror)
            let originalBackup = try write(Data(updated.utf8), to: guest)
            do {
                let hostBackup = try write(hostJSON, to: host)
                return "已写入 Colima 与宿主机配置。备份：" + originalBackup + " / " + hostBackup +
                    "。请在合适时间手动重启 Colima，正在运行的容器不会被轻屿自动停止。"
            } catch {
                throw DockerConfigurationError.command("Colima 配置已更新，但宿主机配置写入失败。请检查 Colima 备份 " +
                    originalBackup + "；错误：" + error.localizedDescription)
            }
        }
        let backup = try write(hostJSON, to: host)
        return "镜像源已写入 ~/.docker/daemon.json（旧配置备份：" + backup +
            "）。请在 Docker Desktop 设置 > Docker Engine 核对并点击 Apply & Restart；轻屿不会自动重启容器。"
    }
}
