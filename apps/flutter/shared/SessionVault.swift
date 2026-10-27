import Foundation
import Security
import LocalAuthentication

/// A single device-local credential; no account password or cloud sync.
final class KeychainSessionVault {
    private let service: String
    init(service: String) { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "active-session",
         kSecAttrSynchronizable as String: false]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: "LightIsleSessionVault", code: Int(status))
        }
    }
    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, data.count <= 8192,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LightIsleSessionVault", code: -1)
        }
        return value
    }
    func write(_ value: String) throws {
        let data = Data(value.utf8)
        guard data.count <= 8192 else { throw NSError(domain: "LightIsleSessionVault", code: -1) }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary))
        } else { try check(status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

#if canImport(FlutterMacOS)
import FlutterMacOS
#elseif canImport(Flutter)
import Flutter
#endif

#if canImport(FlutterMacOS) || canImport(Flutter)
final class SessionVault {
    private let channel: FlutterMethodChannel
    private let storage: KeychainSessionVault
    private let queue = DispatchQueue(label: "lightisle.session-vault")
    init(messenger: FlutterBinaryMessenger) {
        storage = KeychainSessionVault(service: (Bundle.main.bundleIdentifier ?? "top.lengsu.lightisle.client") + ".login-session")
        channel = FlutterMethodChannel(name: "lightisle/session-vault", binaryMessenger: messenger)
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self else { return }
            guard ["read", "write", "clear"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
            self.queue.async {
                do {
                    var value: String?
                    switch call.method {
                    case "read": value = try self.storage.read()
                    case "write":
                        guard let arguments = call.arguments as? [String: Any], let input = arguments["value"] as? String else {
                            throw NSError(domain: "LightIsleSessionVault", code: -1)
                        }
                        try self.storage.write(input)
                    default: try self.storage.clear()
                    }
                    DispatchQueue.main.async { result(value) }
                } catch {
                    DispatchQueue.main.async {
                        result(FlutterError(code: "session_vault_unavailable", message: "无法访问系统保存的登录状态，请解锁设备并重试。", details: nil))
                    }
                }
            }
        }
    }
}
#endif
