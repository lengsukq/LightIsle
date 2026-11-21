import Foundation
import LocalAuthentication

/// Unified macOS device owner authentication (Touch ID or Mac login password)
/// for sensitive administrative operations.
enum DeviceOwnerAuth {
    enum AuthError: LocalizedError, Equatable {
        case unavailable
        case cancelledOrFailed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "当前 Mac 无法执行本机所有者验证，数据未被修改。请在「系统设置 → 触控 ID 与密码」确认已启用登录密码或 Touch ID 后重试。"
            case .cancelledOrFailed:
                return "本机所有者验证已取消或未通过，数据未被修改。如需继续请重试并完成身份验证。"
            }
        }
    }

    static func authenticate(reason: String) async throws {
        let context = LAContext()
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            throw AuthError.unavailable
        }
        do {
            let approved = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            guard approved else {
                throw AuthError.cancelledOrFailed
            }
        } catch {
            throw AuthError.cancelledOrFailed
        }
    }
}
