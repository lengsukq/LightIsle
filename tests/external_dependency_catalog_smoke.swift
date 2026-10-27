import Foundation

// Run together with ExternalDependencySupport.swift. No packages are changed.
@main
struct ExternalDependencyCatalogSmoke {
    static func main() {
        let expected: [ExternalDependency: (package: String, executable: String)] = [
            .ffmpeg: ("ffmpeg", "ffmpeg"),
            .aria2: ("aria2", "aria2c"),
            .smartmontools: ("smartmontools", "smartctl"),
            .cloudflared: ("cloudflared", "cloudflared")
        ]
        precondition(Set(ExternalDependency.allCases) == Set(expected.keys))
        for dependency in ExternalDependency.allCases {
            guard let entry = expected[dependency] else { fatalError("Unknown dependency") }
            precondition(dependency.rawValue == entry.package)
            precondition(dependency.executable == entry.executable)
            let command = ExternalDependencyInstaller.command(
                for: dependency, brewPath: "/opt/homebrew/bin/brew"
            )
            precondition(command == ["/opt/homebrew/bin/brew", "install", entry.package])
            precondition(!command.contains("-c"))
            precondition(!command.contains("sudo"))
        }
        precondition(ExternalDependencyInstaller.trustedBrewPaths == [
            "/opt/homebrew/bin/brew", "/usr/local/bin/brew"
        ])
        precondition(
            ExternalDependencyInstaller.officialBrewInstallCommand ==
            #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        )
        precondition(
            ExternalDependencyInstaller.appleSiliconShellenvCommand ==
            #"eval "$(/opt/homebrew/bin/brew shellenv)""#
        )
        print("PASS: fixed Homebrew package catalog and direct install arguments")
    }
}
