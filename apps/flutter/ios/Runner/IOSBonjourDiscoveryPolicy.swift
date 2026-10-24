import Darwin
import Foundation

struct IOSBonjourCandidate: Equatable {
  let name: String
  let host: String
  let port: Int

  var url: String {
    let urlHost = host.contains(":") ? "[\(host.replacingOccurrences(of: "%", with: "%25"))]" : host
    return "https://\(urlHost):\(port)"
  }

  var asMap: [String: Any] {
    ["name": name, "host": host, "port": port, "url": url]
  }

  var endpointKey: String { "\(host.lowercased())|\(port)" }
}

enum IOSBonjourDiscoveryPolicy {
  static let serviceType = "_lightisle._tcp."
  static let defaultTimeoutMilliseconds = 10_000
  static let minimumTimeoutMilliseconds = 1_000
  static let maximumTimeoutMilliseconds = 10_000
  static let maximumCandidates = 16
  static let maximumTrackedServices = 64

  static func timeoutMilliseconds(_ requested: Int?) -> Int {
    min(max(requested ?? defaultTimeoutMilliseconds, minimumTimeoutMilliseconds), maximumTimeoutMilliseconds)
  }

  static func isValidRequestID(_ requestID: String) -> Bool {
    requestID.range(of: "^[A-Za-z0-9_-]{16,128}$", options: .regularExpression) != nil
  }

  static func serviceKey(name: String, type: String, domain: String) -> String? {
    let trimmedType = type.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedType = trimmedType.hasSuffix(".") ? String(trimmedType.dropLast()).lowercased() : trimmedType.lowercased()
    let normalizedDomain = trimmedDomain.hasSuffix(".") ? String(trimmedDomain.dropLast()).lowercased() : trimmedDomain.lowercased()
    let serviceName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedType == "_lightisle._tcp",
          normalizedDomain == "local",
          !serviceName.isEmpty,
          serviceName.utf8.count <= 255 else { return nil }
    return "\(serviceName.lowercased())|_lightisle._tcp|local"
  }

  static func candidate(name: String, host rawHost: String, port: Int) -> IOSBonjourCandidate? {
    guard (1...65_535).contains(port),
          let host = normalizeLocalNumericHost(rawHost) else { return nil }
    let safeScalars = name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    let cleanedName = String(String.UnicodeScalarView(safeScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    let limitedName = String(cleanedName.prefix(128))
    return IOSBonjourCandidate(name: limitedName.isEmpty ? "LightIsle NAS" : limitedName, host: host, port: port)
  }

  static func numericLocalHost(from address: Data) -> String? {
    guard address.count >= MemoryLayout<sockaddr>.size else { return nil }
    let host = address.withUnsafeBytes { buffer -> String? in
      guard let socketAddress = buffer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return nil }
      let family = socketAddress.pointee.sa_family
      guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { return nil }
      let minimumSize = family == sa_family_t(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size
      guard buffer.count >= minimumSize else { return nil }
      var numericHost = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        socketAddress,
        socklen_t(buffer.count),
        &numericHost,
        socklen_t(numericHost.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      guard result == 0 else { return nil }
      return String(cString: numericHost)
    }
    guard let host else { return nil }
    return normalizeLocalNumericHost(host)
  }

  private static func normalizeLocalNumericHost(_ rawHost: String) -> String? {
    guard !rawHost.isEmpty, rawHost.utf8.count <= 128, rawHost == rawHost.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    return rawHost.contains(":") ? normalizeIPv6(rawHost) : normalizeIPv4(rawHost)
  }

  private static func normalizeIPv4(_ rawHost: String) -> String? {
    let pieces = rawHost.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 4 else { return nil }
    var octets: [Int] = []
    for piece in pieces {
      guard !piece.isEmpty,
            piece.count <= 3,
            piece.allSatisfy({ $0.isASCII && $0.isNumber }),
            let value = Int(piece),
            (0...255).contains(value),
            String(value) == String(piece) else { return nil }
      octets.append(value)
    }
    let isPrivate = octets[0] == 10 ||
      (octets[0] == 172 && (16...31).contains(octets[1])) ||
      (octets[0] == 192 && octets[1] == 168)
    let isLinkLocal = octets[0] == 169 && octets[1] == 254
    guard isPrivate || isLinkLocal else { return nil }
    return octets.map(String.init).joined(separator: ".")
  }

  private static func normalizeIPv6(_ rawHost: String) -> String? {
    let zoneIndex = rawHost.lastIndex(of: "%")
    let addressText = zoneIndex.map { String(rawHost[..<$0]) } ?? rawHost
    let zone = zoneIndex.map { String(rawHost[rawHost.index(after: $0)...]) }
    if let zone {
      guard zone.range(of: "^[A-Za-z0-9_.-]{1,32}$", options: .regularExpression) != nil else { return nil }
    }
    guard addressText.range(of: "^[0-9A-Fa-f:.]+$", options: .regularExpression) != nil else { return nil }
    var address = in6_addr()
    guard addressText.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
    let bytes = withUnsafeBytes(of: &address) { Array($0) }
    guard bytes.count == 16 else { return nil }
    let uniqueLocal = (bytes[0] & 0xfe) == 0xfc
    let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
    let siteLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0
    guard uniqueLocal || linkLocal || siteLocal,
          zone == nil || linkLocal || siteLocal else { return nil }
    var canonical = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(AF_INET6, &address, &canonical, socklen_t(canonical.count)) != nil else { return nil }
    let host = String(cString: canonical)
    return zone.map { "\(host)%\($0)" } ?? host
  }
}
