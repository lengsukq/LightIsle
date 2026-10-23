import Foundation

@main
struct DockerSupportRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError("FAIL: " + message) }
    }

    static func shouldReject(_ description: String, _ operation: () throws -> Void) {
        do {
            try operation()
            fatalError("FAIL: expected rejection for " + description)
        } catch is DockerConfigurationError {
            return
        } catch {
            fatalError("FAIL: unexpected error for " + description + ": " + String(describing: error))
        }
    }

    @discardableResult
    static func expectCommandFailure(_ description: String, containing expectedText: String,
                                     _ operation: () throws -> String) -> String {
        do {
            _ = try operation()
            fatalError("FAIL: expected command failure for " + description)
        } catch let error as LocalizedError {
            let message = error.errorDescription ?? String(describing: error)
            expect(message.contains(expectedText),
                   description + " returned an unexpected error: " + message)
            return message
        } catch {
            fatalError("FAIL: unexpected error for " + description + ": " + String(describing: error))
        }
    }

    static func main() throws {
        let publicMirror = try DockerMirrorConfig.validate("  https://docker.1ms.run  ")
        expect(publicMirror == "https://docker.1ms.run", "URL normalization")
        let daocloud = try DockerMirrorConfig.validate("https://docker.m.daocloud.io/")
        expect(daocloud == "https://docker.m.daocloud.io", "URL trailing slash")
        for invalid in ["http://unsafe.test", "https://example.org/subpath",
                        "https://user:password@example.org", "https://localhost",
                        "https://example.org?token=abc", "https://example.org#frag",
                        "https://example.org:8080"] {
            shouldReject(invalid) { _ = try DockerMirrorConfig.validate(invalid) }
        }

        let original = Data(#"{"features":{"buildkit":true},"debug":false,"registry-mirrors":["https://legacy.example"]}"#.utf8)
        let merged = try DockerMirrorConfig.daemonJSON(original, mirror: publicMirror)
        let json = try JSONSerialization.jsonObject(with: merged) as! [String: Any]
        expect((json["features"] as? [String: Bool])?["buildkit"] == true, "preserve existing Docker features")
        expect((json["debug"] as? Bool) == false, "preserve unrelated keys")
        expect((json["registry-mirrors"] as? [String]) == [publicMirror], "replace only registry-mirrors")
        shouldReject("invalid JSON") {
            _ = try DockerMirrorConfig.daemonJSON(Data("[5]".utf8), mirror: publicMirror)
        }

        let yml1 = "cpu: 4\n# existing comment\ndocker: {}\nnetwork:\n  mode: shared\n"
        let changed1 = try DockerMirrorConfig.colimaYAML(yml1, mirror: daocloud)
        expect(changed1.contains("docker:\n  registry-mirrors:\n    - https://docker.m.daocloud.io"), "Colima empty docker map")
        expect(changed1.contains("cpu: 4") && changed1.contains("network:\n  mode: shared"), "preserve Colima settings")
        let yml2 = """
        cpu: 2
        docker:
          features:
            buildkit: true
          registry-mirrors:
            - https://old.example
          insecure-registries:
            - my.company:5000
        memory: 4
        """
        let changed2 = try DockerMirrorConfig.colimaYAML(yml2, mirror: publicMirror)
        expect(changed2.contains("  features:\n    buildkit: true"), "preserve daemon options")
        expect(changed2.contains("  insecure-registries:\n    - my.company:5000"), "preserve insecure registries")
        expect(!changed2.contains("old.example"), "remove previous mirrors")
        expect(changed2.components(separatedBy: "registry-mirrors:").count == 2, "only one mirrors stanza")
        shouldReject("no Colima docker section") {
            _ = try DockerMirrorConfig.colimaYAML("cpu: 2\n", mirror: publicMirror)
        }
        shouldReject("duplicate docker YAML roots") {
            _ = try DockerMirrorConfig.colimaYAML("docker: {}\ndocker: {}\n", mirror: publicMirror)
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lightisle-docker-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Exercise the real Process/pipe path with a local shell fixture. No
        // Docker binary, daemon, registry, or network is involved.
        let fakeDocker = temp.appendingPathComponent("fake-docker")
        let commandFixture = #"""
        #!/bin/sh
        case "$1" in
          normal)
            printf 'stdout-marker'
            printf 'stderr-marker' >&2
            ;;
          large-line)
            trap 'printf stopped > "$2"; exit 0' TERM
            i=0
            while [ "$i" -lt 1025 ]; do printf '%1024s' ''; i=$((i + 1)); done
            while :; do :; done
            ;;
          continuous)
            trap 'printf stopped > "$2"; exit 0' TERM
            while :; do printf '%16384s' ''; done
            ;;
          dual-stream)
            trap 'printf stopped > "$2"; exit 0' TERM
            i=0
            while [ "$i" -lt 768 ]; do printf '%1024s' ''; i=$((i + 1)); done
            i=0
            while [ "$i" -lt 768 ]; do printf '%1024s' '' >&2; i=$((i + 1)); done
            while :; do :; done
            ;;
          timeout)
            trap 'printf stopped > "$2"; exit 0' TERM
            while :; do :; done
            ;;
        esac
        """#
        try commandFixture.write(to: fakeDocker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeDocker.path)
        let normalOutput = try DockerLocalRuntime.run(["normal"], executable: fakeDocker, deadline: 2)
        expect(normalOutput.contains("stdout-marker") && normalOutput.contains("stderr-marker"),
               "capture stdout and stderr without deadlock")

        for mode in ["large-line", "continuous", "dual-stream"] {
            let stoppedMarker = temp.appendingPathComponent(mode + ".stopped")
            _ = expectCommandFailure(mode, containing: "超过安全上限") {
                try DockerLocalRuntime.run([mode, stoppedMarker.path], executable: fakeDocker, deadline: 5)
            }
            let marker = try String(contentsOf: stoppedMarker, encoding: .utf8)
            expect(marker == "stopped", mode + " child was terminated after output overflow")
        }

        let timeoutMarker = temp.appendingPathComponent("timeout.stopped")
        let timeoutStarted = DispatchTime.now().uptimeNanoseconds
        _ = expectCommandFailure("deadline", containing: "超时") {
            try DockerLocalRuntime.run(["timeout", timeoutMarker.path], executable: fakeDocker, deadline: 0.15)
        }
        let timeoutElapsed = DispatchTime.now().uptimeNanoseconds - timeoutStarted
        expect(timeoutElapsed < 2_000_000_000, "deadline terminates a quiet child promptly")
        let timeoutResult = try String(contentsOf: timeoutMarker, encoding: .utf8)
        expect(timeoutResult == "stopped",
               "deadline cleanup reaches and stops the child")

        let config = temp.appendingPathComponent("daemon.json")
        try original.write(to: config)
        let backupName = try DockerMirrorWriter.write(merged, to: config, root: temp)
        let saved = try Data(contentsOf: config)
        let backup = try Data(contentsOf: temp.appendingPathComponent(backupName))
        expect(saved == merged && backup == original, "one-click write preserves original backup")
        let attrs = try FileManager.default.attributesOfItem(atPath: config.path)
        expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "private file permissions")
        let symlink = temp.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: config)
        shouldReject("symlinked config") { _ = try DockerMirrorWriter.write(merged, to: symlink, root: temp) }
        let result = try Data(contentsOf: config)
        expect(result == merged, "symlink rejection preserved original")
        let linkedDirectory = temp.appendingPathComponent("linked-dir")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: temp)
        shouldReject("symlinked ancestor") {
            _ = try DockerMirrorWriter.write(merged, to: linkedDirectory.appendingPathComponent("new.json"), root: temp)
        }

        shouldReject("remote context") {
            _ = try DockerLocalRuntime.verifiedContext("my-remote-cloud")
        }
        let projectsJSON = #"[{"Name":"myhome","Status":"running(2)","ConfigFiles":"/Users/test/compose.yaml,/Users/test/compose.override.yml"},{"Name":"media","Status":"exited(3)","ConfigFiles":"/Users/test/media/compose.yaml"}]"#
        let projects = try DockerOperationValidation.parseComposeProjects(projectsJSON)
        expect(projects.count == 2, "parse existing Compose projects")
        expect(projects[0].name == "myhome" && projects[0].configFiles.count == 2,
               "recognize Compose config override files")
        expect(projects[1].status == "exited(3)", "preserve project status")
        let empty = try DockerOperationValidation.parseComposeProjects("[]")
        expect(empty.isEmpty, "empty Compose project inventory")
        shouldReject("malformed Compose projects") {
            _ = try DockerOperationValidation.parseComposeProjects("garbage")
        }
        shouldReject("unsafe project name") {
            _ = try DockerOperationValidation.projectName("../work")
        }
        shouldReject("uppercase Compose project name") {
            _ = try DockerOperationValidation.projectName("MyProject")
        }
        let verifiedProjectName = try DockerOperationValidation.projectName("my-project_2")
        expect(verifiedProjectName == "my-project_2",
               "valid Compose project name")

        let compose = temp.appendingPathComponent("compose.yaml")
        let override = temp.appendingPathComponent("compose.override.yml")
        try Data("services: {}\n".utf8).write(to: compose)
        try Data("services: {}\n".utf8).write(to: override)
        let fixture = DockerComposeProject(name: "my-project_2", status: "running(1)",
                                           configFiles: [compose.path, override.path])
        let args = try DockerOperationValidation.composeArguments(project: fixture, action: "stop", home: temp)
        expect(args == ["compose", "--project-name", "my-project_2",
                        "--file", compose.path, "--file", override.path, "stop"],
               "Compose arguments use explicit files and no shell")
        let deployArgs = try DockerOperationValidation.deployArguments(project: fixture, home: temp)
        expect(deployArgs == ["compose", "--project-name", "my-project_2",
                              "--file", compose.path, "--file", override.path],
               "Compose deploy explicitly binds project and selected config files")
        shouldReject("Compose up -d is not an allowed action") {
            _ = try DockerOperationValidation.composeArguments(project: fixture, action: "up", home: temp)
        }
        shouldReject("Compose outside user directory") {
            _ = try DockerOperationValidation.projectFilePaths(["/etc/compose.yaml"], home: temp)
        }
        let fakeYaml = temp.appendingPathComponent("linked-compose.yml")
        try FileManager.default.createSymbolicLink(at: fakeYaml, withDestinationURL: compose)
        shouldReject("symlinked Compose file") {
            _ = try DockerOperationValidation.projectFilePaths([fakeYaml.path], home: temp)
        }

        for name in ["nginx:stable", "redis:7.4", "ghcr.io/acme/example:v1",
                     "library/hello-world@sha256:" + String(repeating: "a", count: 64)] {
            let validImage = try DockerOperationValidation.imageReference(name)
            expect(validImage == name,
                   "accept valid image name: " + name)
        }
        for name in ["-a", "nginx;rm -rf /", "http://invalid", "nginx:tag\n--all-tags",
                     "nginx@sha256:deadbeef", "a/../b", "myrepo//image", ""] {
            shouldReject("invalid image reference " + name) {
                _ = try DockerOperationValidation.imageReference(name)
            }
        }
        let validID = try DockerOperationValidation.containerID(String(repeating: "a", count: 64))
        expect(validID.count == 64,
               "allow canonical 64 character container ID")
        shouldReject("invalid container ID") {
            _ = try DockerOperationValidation.containerID("hello")
        }
        let volumes = try DockerOperationValidation.parseVolumeList(
            #"{"Name":"photos","Driver":"local","Mountpoint":"/var/lib/docker/volumes/photos"}"#)
        expect(volumes.count == 1 && volumes[0].name == "photos" &&
               volumes[0].driver == "local", "parse local Docker volume")
        let networks = try DockerOperationValidation.parseNetworkList(
            #"{"Name":"bridge","ID":"abc123","Driver":"bridge","Scope":"local"}"#)
        expect(networks.count == 1 && networks[0].name == "bridge" && networks[0].scope == "local",
               "parse Docker network")
        let goodVolume = try DockerOperationValidation.resourceName("photos_2026", kind: "volume")
        let goodNetwork = try DockerOperationValidation.resourceName("private-app-net", kind: "network")
        expect(goodVolume == "photos_2026" && goodNetwork == "private-app-net",
               "valid Docker resource names")
        for input in ["", "-bad", "space name", "../escape", "bad/name", "bad\nnew", "bad;rm"] {
            shouldReject("invalid Docker volume resource name") {
                _ = try DockerOperationValidation.resourceName(input, kind: "volume")
            }
        }
        for name in ["bridge", "host", "none"] {
            shouldReject("system reserved network") {
                _ = try DockerOperationValidation.resourceName(name, kind: "network")
            }
        }
        print("PASS: Docker mirrors, Compose config/project validation, image references, volumes, networks, backups, symlink protection and local context restrictions")
    }
}
