import Foundation

// Docker CLI operations stay inside the native Mac app. There are no Web
// endpoints, generic command shells, daemon sockets, or container exec here.
// Deliberately omit prune, volume deletion and unattended image updates.
struct DockerComposeProject: Identifiable {
    let name: String
    let status: String
    let configFiles: [String]
    var id: String { name }
}

struct DockerContainerMetrics {
    let name: String
    let cpuPercent: String
    let memoryUsage: String
    let memoryPercent: String
    let networkIO: String
    let diskIO: String
    let health: String
}

struct DockerVolume: Identifiable {
    let name: String
    let driver: String
    let mountpoint: String
    var id: String { name }
}

struct DockerNetwork: Identifiable {
    let id: String
    let name: String
    let driver: String
    let scope: String
}

struct DockerExtras {
    let projects: [DockerComposeProject]
    let volumes: [DockerVolume]
    let networks: [DockerNetwork]
    let composeAvailable: Bool
}

enum DockerOperationValidation {
    static func imageReference(_ raw: String) throws -> String {
        // No flag, scheme, shell metacharacter, or whitespace. A tag may be
        // refreshed in place, while an @sha256 reference always stays pinned.
        guard !raw.isEmpty, raw.count <= 240,
              !raw.hasPrefix("-"), !raw.hasSuffix("/"),
              !raw.contains("//"), !raw.contains(".."),
              !raw.contains("://"), !raw.contains("@-"),
              !raw.contains("::"), !raw.contains("/-") else {
            throw DockerConfigurationError.command("镜像名称不合法，请输入如 nginx:stable 的镜像引用。")
        }
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:@")
        guard raw.unicodeScalars.allSatisfy({ permitted.contains($0) }),
              raw.unicodeScalars.first.map({ CharacterSet.alphanumerics.contains($0) }) == true else {
            throw DockerConfigurationError.command("镜像名称包含不允许的字符。")
        }
        if raw.contains("@") {
            let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1].hasPrefix("sha256:"),
                  parts[1].count == 71,
                  parts[1].dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
                throw DockerConfigurationError.command("镜像摘要必须为 sha256: 后接 64 位十六进制字符。")
            }
        }
        return raw
    }

    static func projectName(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.count <= 100,
              let first = raw.first, first.isASCII && (first.isLowercase || first.isNumber),
              raw.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == "-") }) else {
            throw DockerConfigurationError.command("无效的 Compose 项目名称。")
        }
        return raw
    }

    // Existing Compose files from a different system path remain visible,
    // but cannot be executed by this UI. This is not a Compose installer.
    static func projectFilePaths(_ paths: [String], home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> [String] {
        guard !paths.isEmpty, paths.count <= 8 else {
            throw DockerConfigurationError.command("项目缺少受支持的 Compose 配置路径。")
        }
        let root = home.standardizedFileURL.path
        var result: [String] = []
        for path in paths {
            guard path.hasPrefix(root + "/"), !path.contains("\n"),
                  !path.contains("\r"), !path.contains("\0"),
                  path.count <= 1024 else {
                throw DockerConfigurationError.command("Compose 配置文件不在当前 Mac 用户目录下。")
            }
            let url = URL(fileURLWithPath: path)
            let canonical = url.standardizedFileURL
            guard canonical.path.hasPrefix(root + "/"),
                  ["yaml", "yml"].contains(canonical.pathExtension.lowercased()) else {
                throw DockerConfigurationError.command("Compose 路径或格式不受支持。")
            }
            // Reject every symlink segment: a YAML file may mount or execute
            // arbitrary host paths, so the owner must review it explicitly.
            var cursor = canonical
            while cursor.path != root {
                let attrs = try FileManager.default.attributesOfItem(atPath: cursor.path)
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                    throw DockerConfigurationError.unsafePath
                }
                cursor.deleteLastPathComponent()
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: canonical.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 262_144 else {
                throw DockerConfigurationError.unsafePath
            }
            result.append(canonical.path)
        }
        return result
    }

    static func composeArguments(project: DockerComposeProject, action: String,
                                 home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> [String] {
        guard ["start", "stop", "restart"].contains(action) else {
            throw DockerConfigurationError.command("不支持此 Compose 操作。")
        }
        let projectName = try projectName(project.name)
        let paths = try projectFilePaths(project.configFiles, home: home)
        var args: [String] = ["compose", "--project-name", projectName]
        for file in paths { args += ["--file", file] }
        return args + [action]
    }

    static func deployArguments(project: DockerComposeProject,
                                home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> [String] {
        let name = try projectName(project.name)
        let paths = try projectFilePaths(project.configFiles, home: home)
        var args = ["compose", "--project-name", name]
        for file in paths { args += ["--file", file] }
        return args
    }

    static func parseComposeProjects(_ json: String) throws -> [DockerComposeProject] {
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let data = json.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            throw DockerConfigurationError.command("Compose 返回了无法解析的项目数据。")
        }
        guard parsed.count <= 500 else { throw DockerConfigurationError.tooLarge }
        return try parsed.map { entry in
            guard let name = entry["Name"] as? String else {
                throw DockerConfigurationError.command("Compose 项目缺少名称。")
            }
            let config = entry["ConfigFiles"] as? String ?? ""
            let files = config.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return DockerComposeProject(name: name, status: entry["Status"] as? String ?? "未知",
                                        configFiles: files)
        }
    }

    static func parseVolumeList(_ output: String) throws -> [DockerVolume] {
        try output.split(separator: "\n").map { line in
            guard let data = String(line).data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = entry["Name"] as? String else {
                throw DockerConfigurationError.command("Docker 数据卷列表无效")
            }
            return DockerVolume(name: name, driver: entry["Driver"] as? String ?? "",
                                mountpoint: entry["Mountpoint"] as? String ?? "")
        }
    }

    static func parseNetworkList(_ output: String) throws -> [DockerNetwork] {
        try output.split(separator: "\n").map { line in
            guard let data = String(line).data(using: .utf8),
                  let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = entry["ID"] as? String, let name = entry["Name"] as? String else {
                throw DockerConfigurationError.command("Docker 网络列表无效")
            }
            return DockerNetwork(id: id, name: name, driver: entry["Driver"] as? String ?? "",
                                 scope: entry["Scope"] as? String ?? "")
        }
    }

    static func containerID(_ id: String) throws -> String {
        guard (12...64).contains(id.count), id.allSatisfy({ $0.isHexDigit }) else {
            throw DockerConfigurationError.command("容器标识符无效。")
        }
        return id
    }

    static func resourceName(_ input: String, kind: String) throws -> String {
        guard kind == "volume" || kind == "network",
              (1...100).contains(input.count),
              let first = input.first, first.isASCII && (first.isLetter || first.isNumber),
              input.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".")
              }), !input.contains(".."), !input.hasSuffix("."),
              !(kind == "network" && ["bridge", "host", "none"].contains(input.lowercased())) else {
            throw DockerConfigurationError.command("无效的 Docker 资源名称，或名称属于系统保留网络。")
        }
        return input
    }

}

enum DockerOperations {
    /// Read-only snapshot. Never opens a long-running stream or a remote
    /// Docker context. A caller must explicitly select one existing container.
    static func metrics(containerID: String, context selected: String) throws -> DockerContainerMetrics {
        let id = try DockerOperationValidation.containerID(containerID)
        let context = try DockerLocalRuntime.verifiedContext(selected)
        let output = try DockerLocalRuntime.run([
            "--context", context, "container", "stats", "--no-stream",
            "--format", "{{json .}}", id
        ], deadline: 15)
        guard output.utf8.count < 32_768,
              let data = output.data(using: .utf8),
              let stats = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DockerConfigurationError.command("无法解析容器资源统计结果。")
        }
        let inspect = try DockerLocalRuntime.run([
            "--context", context, "container", "inspect",
            "--format", "{{json .State.Health.Status}}", id
        ], deadline: 10)
        let health = (try? JSONDecoder().decode(String.self, from: Data(inspect.utf8))) ?? "未配置 HEALTHCHECK"
        let read: (String) -> String = { field in
            String((stats[field] as? String ?? "—").prefix(96))
        }
        return DockerContainerMetrics(
            name: read("Name"), cpuPercent: read("CPUPerc"),
            memoryUsage: read("MemUsage"), memoryPercent: read("MemPerc"),
            networkIO: read("NetIO"), diskIO: read("BlockIO"),
            health: String(health.prefix(48))
        )
    }
    static func inspectExtras(_ selected: String) throws -> DockerExtras {
        let context = try DockerLocalRuntime.verifiedContext(selected)
        let volumes = try DockerOperationValidation.parseVolumeList(
            DockerLocalRuntime.run(["--context", context, "volume", "ls", "--format", "{{json .}}"]))
        let networks = try DockerOperationValidation.parseNetworkList(
            DockerLocalRuntime.run(["--context", context, "network", "ls", "--no-trunc", "--format", "{{json .}}"]))
        var projects: [DockerComposeProject] = []
        var composeAvailable = false
        // A missing Compose plugin must not hide containers/volumes/networks.
        if (try? DockerLocalRuntime.run(["--context", context, "compose", "version", "--short"])) != nil {
            composeAvailable = true
            let projectText = try DockerLocalRuntime.run([
                "--context", context, "compose", "ls", "--all", "--format", "json"
            ])
            projects = try DockerOperationValidation.parseComposeProjects(projectText)
        }
        return DockerExtras(projects: projects, volumes: volumes, networks: networks,
                            composeAvailable: composeAvailable)
    }

    static func logs(containerID: String, context selected: String, tail: Int = 200) throws -> String {
        guard (1...500).contains(tail) else { throw DockerConfigurationError.command("日志行数超限。") }
        let id = try DockerOperationValidation.containerID(containerID)
        let context = try DockerLocalRuntime.verifiedContext(selected)
        return try DockerLocalRuntime.run([
            "--context", context, "container", "logs", "--tail", String(tail), "--timestamps", id
        ], deadline: 15)
    }

    static func pullImage(_ reference: String, context selected: String) throws -> String {
        let image = try DockerOperationValidation.imageReference(reference)
        let context = try DockerLocalRuntime.verifiedContext(selected)
        // Pulling a new tag does NOT update existing running containers.
        // No --all-tags, --platform changes or implicit restarts.
        return try DockerLocalRuntime.run([
            "--context", context, "image", "pull", "--quiet", image
        ], deadline: 240)
    }

    static func operateCompose(_ project: DockerComposeProject,
                               action: String, context selected: String) throws {
        let context = try DockerLocalRuntime.verifiedContext(selected)
        let commands = try DockerOperationValidation.composeArguments(project: project, action: action)
        // Re-discover before acting: config files may be replaced or a
        // different engine selected since the list was last displayed.
        let listed = try DockerOperationValidation.parseComposeProjects(
            DockerLocalRuntime.run(["--context", context, "compose", "ls", "--all", "--format", "json"]))
        guard let current = listed.first(where: { $0.name == project.name }),
              current.configFiles == project.configFiles else {
            throw DockerConfigurationError.command("Compose 项目清单已变化，请刷新后再操作。")
        }
        _ = try DockerLocalRuntime.run(["--context", context] + commands, deadline: 90)
    }

    static func deployCompose(_ project: DockerComposeProject, context selected: String) throws {
        let context = try DockerLocalRuntime.verifiedContext(selected)
        let args = try DockerOperationValidation.deployArguments(project: project)
        let listed = try DockerOperationValidation.parseComposeProjects(
            DockerLocalRuntime.run(["--context", context, "compose", "ls", "--all", "--format", "json"]))
        guard !listed.contains(where: { $0.name == project.name }) else {
            throw DockerConfigurationError.command("已有同名 Compose 项目。请在现有项目列表操作，避免误修改。")
        }
        // Do not print canonical config: it may interpolate credentials.
        _ = try DockerLocalRuntime.run(["--context", context] + args + ["config", "--quiet"], deadline: 20)
        // The user has explicitly selected these files. Do not build arbitrary
        // Dockerfiles, replace running containers, or delete orphaned volumes.
        _ = try DockerLocalRuntime.run(["--context", context] + args +
            ["up", "--detach", "--no-build", "--no-recreate", "--pull", "missing"],
            deadline: 240)
    }

    static func createVolume(name: String, context selected: String) throws {
        let name = try DockerOperationValidation.resourceName(name, kind: "volume")
        let context = try DockerLocalRuntime.verifiedContext(selected)
        _ = try DockerLocalRuntime.run(["--context", context, "volume", "create", "--name", name])
    }

    static func createNetwork(name: String, context selected: String) throws {
        let name = try DockerOperationValidation.resourceName(name, kind: "network")
        let context = try DockerLocalRuntime.verifiedContext(selected)
        _ = try DockerLocalRuntime.run(["--context", context, "network", "create", "--driver", "bridge", name])
    }
}
