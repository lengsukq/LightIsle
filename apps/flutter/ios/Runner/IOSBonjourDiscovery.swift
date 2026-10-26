import dnssd
import Flutter
import Foundation
import Network

final class IOSBonjourDiscovery {
  private var activeRequest: IOSBonjourDiscoveryRequest?

  deinit {
    activeRequest?.cancel()
  }

  func cancelActive() {
    activeRequest?.cancel()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let arguments = call.arguments as? [String: Any],
          let requestID = arguments["requestId"] as? String,
          IOSBonjourDiscoveryPolicy.isValidRequestID(requestID) else {
      result(FlutterError(code: "invalid_discovery_request", message: "局域网发现请求编号无效。", details: nil))
      return
    }

    switch call.method {
    case "discover":
      activeRequest?.cancel()
      let timeout = IOSBonjourDiscoveryPolicy.timeoutMilliseconds(arguments["timeoutMs"] as? Int)
      let request = IOSBonjourDiscoveryRequest(requestID: requestID, timeoutMilliseconds: timeout) { [weak self] request in
        guard let self, self.activeRequest === request else { return }
        self.activeRequest = nil
      }
      activeRequest = request
      request.start(result: result)

    case "cancel":
      guard let request = activeRequest, request.requestID == requestID else {
        result(false)
        return
      }
      result(true)
      request.cancel()

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

private struct IOSBonjourServiceDescriptor {
  let name: String
  let type: String
  let domain: String
  let key: String
}

private final class IOSBonjourDiscoveryRequest: NSObject, NetServiceDelegate {
  private struct ActiveResolution {
    let key: String
    let service: NetService
  }

  fileprivate let requestID: String
  private let timeoutMilliseconds: Int
  private let onFinish: (IOSBonjourDiscoveryRequest) -> Void
  private var completion: FlutterResult?
  private var browser: NWBrowser?
  private var timeoutWork: DispatchWorkItem?
  private var finished = false
  private var currentServices: [String: IOSBonjourServiceDescriptor] = [:]
  private var pendingServices: [IOSBonjourServiceDescriptor] = []
  private var resolutions: [ObjectIdentifier: ActiveResolution] = [:]
  private var candidates: [String: (IOSBonjourCandidate, String)] = [:]
  private let maximumConcurrentResolutions = 4

  init(
    requestID: String,
    timeoutMilliseconds: Int,
    onFinish: @escaping (IOSBonjourDiscoveryRequest) -> Void
  ) {
    self.requestID = requestID
    self.timeoutMilliseconds = timeoutMilliseconds
    self.onFinish = onFinish
  }

  func start(result: @escaping FlutterResult) {
    guard !finished else { return }
    completion = result

    let browser = NWBrowser(
      for: .bonjour(type: IOSBonjourDiscoveryPolicy.serviceType, domain: "local."),
      using: .tcp
    )
    self.browser = browser
    browser.stateUpdateHandler = { [weak self] state in
      guard let self, !self.finished else { return }
      switch state {
      case .failed(let error):
        self.finish(error: Self.browserError(error))
      case .waiting(let error) where Self.isPermissionDenied(error):
        self.finish(error: Self.permissionError)
      default:
        break
      }
    }
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self, !self.finished else { return }
      self.updateServices(from: results)
    }
    browser.start(queue: .main)

    let timeoutWork = DispatchWorkItem { [weak self] in
      guard let self, !self.finished else { return }
      if self.candidates.isEmpty {
        self.finish(error: FlutterError(
          code: "discovery_timeout",
          message: "约10秒内没有发现 LightIsle NAS。可手动输入服务器地址。",
          details: nil
        ))
      } else {
        self.finishWithCandidates()
      }
    }
    self.timeoutWork = timeoutWork
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMilliseconds), execute: timeoutWork)
  }

  func cancel() {
    finish(error: FlutterError(code: "discovery_cancelled", message: "局域网搜索已取消。", details: nil))
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    finishResolution(sender, resolved: true)
  }

  func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
    finishResolution(sender, resolved: false)
  }

  private func updateServices(from results: Set<NWBrowser.Result>) {
    var discovered: [String: IOSBonjourServiceDescriptor] = [:]
    for result in results {
      guard case let .service(name, type, domain, _) = result.endpoint,
            let key = IOSBonjourDiscoveryPolicy.serviceKey(name: name, type: type, domain: domain) else { continue }
      guard discovered[key] != nil || discovered.count < IOSBonjourDiscoveryPolicy.maximumTrackedServices else { continue }
      discovered[key] = IOSBonjourServiceDescriptor(
        name: name,
        type: IOSBonjourDiscoveryPolicy.serviceType,
        domain: "local.",
        key: key
      )
    }

    let removedKeys = currentServices.keys.filter { discovered[$0] == nil }
    for key in removedKeys {
      currentServices.removeValue(forKey: key)
      pendingServices.removeAll { $0.key == key }
      let removedResolutions = resolutions.filter { $0.value.key == key }
      for (identifier, resolution) in removedResolutions {
        resolutions.removeValue(forKey: identifier)
        resolution.service.delegate = nil
        resolution.service.stop()
      }
      candidates = candidates.filter { $0.value.1 != key }
    }

    for (key, descriptor) in discovered where currentServices[key] == nil {
      guard currentServices.count < IOSBonjourDiscoveryPolicy.maximumTrackedServices else { break }
      currentServices[key] = descriptor
      pendingServices.append(descriptor)
    }
    pumpResolutions()
  }

  private func pumpResolutions() {
    guard !finished else { return }
    while resolutions.count < maximumConcurrentResolutions, !pendingServices.isEmpty {
      let descriptor = pendingServices.removeFirst()
      guard currentServices[descriptor.key] != nil else { continue }
      let service = NetService(domain: descriptor.domain, type: descriptor.type, name: descriptor.name)
      service.delegate = self
      resolutions[ObjectIdentifier(service)] = ActiveResolution(key: descriptor.key, service: service)
      service.resolve(withTimeout: 5)
    }
  }

  private func finishResolution(_ service: NetService, resolved: Bool) {
    let identifier = ObjectIdentifier(service)
    guard let resolution = resolutions.removeValue(forKey: identifier) else { return }
    let addresses = resolved ? service.addresses ?? [] : []
    let port = service.port
    let name = service.name
    let advertisedScheme: String? = service.txtRecordData().flatMap { data in
      NetService.dictionary(fromTXTRecord: data)["scheme"].flatMap { String(data: $0, encoding: .utf8) }
    }
    service.delegate = nil
    service.stop()

    if resolved, currentServices[resolution.key] != nil {
      for address in addresses {
        guard let host = IOSBonjourDiscoveryPolicy.numericLocalHost(from: address),
              let candidate = IOSBonjourDiscoveryPolicy.candidate(
                name: name,
                host: host,
                port: port,
                rawScheme: advertisedScheme
              ) else { continue }
        candidates[candidate.endpointKey] = (candidate, resolution.key)
        if candidates.count >= IOSBonjourDiscoveryPolicy.maximumCandidates {
          finishWithCandidates()
          return
        }
      }
    }
    pumpResolutions()
  }

  private func finishWithCandidates() {
    let servers = candidates.values
      .map { $0.0 }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
      .map(\.asMap)
    finish(value: ["servers": servers])
  }

  private func finish(error: FlutterError) {
    finish(value: error)
  }

  private func finish(value: Any) {
    guard !finished else { return }
    finished = true
    timeoutWork?.cancel()
    timeoutWork = nil
    browser?.stateUpdateHandler = nil
    browser?.browseResultsChangedHandler = nil
    browser?.cancel()
    browser = nil
    pendingServices.removeAll()
    currentServices.removeAll()
    candidates.removeAll()
    for resolution in resolutions.values {
      resolution.service.delegate = nil
      resolution.service.stop()
    }
    resolutions.removeAll()

    let callback = completion
    completion = nil
    onFinish(self)
    callback?(value)
  }

  private static let permissionError = FlutterError(
    code: "discovery_permission_denied",
    message: "iOS 未允许本地网络访问。请在系统设置中允许 LightIsle 访问本地网络，然后重试。",
    details: nil
  )

  private static func browserError(_ error: NWError) -> FlutterError {
    if isPermissionDenied(error) { return permissionError }
    return FlutterError(
      code: "discovery_failed",
      message: "无法启动局域网发现，请检查当前网络后重试。",
      details: nil
    )
  }

  private static func isPermissionDenied(_ error: NWError) -> Bool {
    switch error {
    case .dns(let code):
      return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
    case .posix(let code):
      return code == .EACCES || code == .EPERM
    default:
      return false
    }
  }
}
