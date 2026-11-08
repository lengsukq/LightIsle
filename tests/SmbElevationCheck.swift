import Foundation

@main
struct SmbElevationCheck {
    static func main() throws {
        // 1. Validate username and sudoers rule generation
        assert(SmbElevation.isValidUsername("leo_admin-01.mac"))
        assert(!SmbElevation.isValidUsername(""))
        assert(!SmbElevation.isValidUsername("bad user"))
        assert(!SmbElevation.isValidUsername("root;rm -rf /"))

        let rule = try SmbElevation.sudoersRule(for: "leo")
        assert(rule.contains("leo ALL=(root) NOPASSWD: /usr/sbin/sharing *"))
        assert(rule.contains("/bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.smbd.plist"))
        assert(rule.contains("/bin/launchctl unload -w /System/Library/LaunchDaemons/com.apple.smbd.plist"))

        do {
            _ = try SmbElevation.sudoersRule(for: "bad user")
            fatalError("Expected invalidUsername error")
        } catch let err as SmbElevation.ElevationError {
            assert(err == .invalidUsername)
        }

        // 2. Shell quoting and Base64URL decoding
        assert(SmbElevation.shellSingleQuoted("/tmp/a'b") == "'/tmp/a'\\''b'")

        let sampleJSON = """
        {
          "serviceEnabled": true,
          "listening": true,
          "remoteManageReady": true,
          "computerName": "Mac mini",
          "localHostName": "Mac-mini",
          "bonjourUrl": "smb://Mac-mini.local",
          "lanUrl": "smb://192.168.1.10",
          "shares": [
            {
              "recordName": "Movies",
              "smbName": "Movies",
              "path": "/Volumes/NAS/Movies",
              "shared": true,
              "guestAccess": true,
              "readOnly": true,
              "sealed": false,
              "rootId": "r1",
              "rootName": "Main",
              "exposesPersonalDirs": false,
              "pathExists": true
            }
          ],
          "candidateRoots": [
            {
              "rootId": "r1",
              "name": "Main",
              "path": "/Volumes/NAS",
              "online": true,
              "subdirectories": ["Movies", "Users"]
            }
          ]
        }
        """
        let b64url = Data(sampleJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let decoded = SmbElevation.decodeStatus(base64URL: b64url) else {
            fatalError("Failed to decode NativeSMBStatus")
        }
        assert(decoded.serviceEnabled && decoded.remoteManageReady)
        assert(decoded.shares.count == 1 && decoded.shares[0].smbName == "Movies")
        assert(decoded.candidateRoots.count == 1 && decoded.candidateRoots[0].subdirectories == ["Movies", "Users"])

        print("PASS: SmbElevationCheck")
    }
}
