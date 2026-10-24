import Darwin
import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testBonjourPolicyAcceptsOnlyTheLocalLightIsleService() {
    XCTAssertEqual(
      IOSBonjourDiscoveryPolicy.serviceKey(name: "Living Room", type: "_lightisle._tcp.", domain: "local."),
      "living room|_lightisle._tcp|local"
    )
    XCTAssertNil(IOSBonjourDiscoveryPolicy.serviceKey(name: "Other", type: "_http._tcp.", domain: "local."))
    XCTAssertNil(IOSBonjourDiscoveryPolicy.serviceKey(name: "Remote", type: "_lightisle._tcp.", domain: "example.com."))
  }

  func testBonjourCandidatesRequirePrivateNumericAddressesAndHTTPSPorts() {
    let ipv4 = IOSBonjourDiscoveryPolicy.candidate(name: "NAS\nOne", host: "192.168.1.24", port: 8443)
    XCTAssertEqual(ipv4?.name, "NASOne")
    XCTAssertEqual(ipv4?.url, "https://192.168.1.24:8443")
    XCTAssertNil(IOSBonjourDiscoveryPolicy.candidate(name: "Public", host: "203.0.113.9", port: 8443))
    XCTAssertNil(IOSBonjourDiscoveryPolicy.candidate(name: "Loopback", host: "127.0.0.1", port: 8443))
    XCTAssertNil(IOSBonjourDiscoveryPolicy.candidate(name: "DNS", host: "nas.example.com", port: 8443))
    XCTAssertNil(IOSBonjourDiscoveryPolicy.candidate(name: "Bad port", host: "192.168.1.24", port: 0))

    let ipv6 = IOSBonjourDiscoveryPolicy.candidate(name: "Link local", host: "fe80::24%en0", port: 8443)
    XCTAssertEqual(ipv6?.url, "https://[fe80::24%25en0]:8443")
    XCTAssertNil(IOSBonjourDiscoveryPolicy.candidate(name: "Global IPv6", host: "2606:4700:4700::1111", port: 8443))
  }

  func testBonjourPolicyBoundsTimeoutCandidatesAndRequestIDs() {
    XCTAssertEqual(IOSBonjourDiscoveryPolicy.timeoutMilliseconds(nil), 10_000)
    XCTAssertEqual(IOSBonjourDiscoveryPolicy.timeoutMilliseconds(100), 1_000)
    XCTAssertEqual(IOSBonjourDiscoveryPolicy.timeoutMilliseconds(20_000), 10_000)
    XCTAssertEqual(IOSBonjourDiscoveryPolicy.maximumCandidates, 16)
    XCTAssertTrue(IOSBonjourDiscoveryPolicy.isValidRequestID("0123456789abcdef"))
    XCTAssertFalse(IOSBonjourDiscoveryPolicy.isValidRequestID("short"))
    XCTAssertFalse(IOSBonjourDiscoveryPolicy.isValidRequestID("invalid request id"))
  }

  func testBonjourAddressResolutionUsesNumericSocketAddressOnly() {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    let parsed = "10.2.3.4".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    XCTAssertEqual(parsed, 1)
    let data = withUnsafeBytes(of: &address) { Data($0) }
    XCTAssertEqual(IOSBonjourDiscoveryPolicy.numericLocalHost(from: data), "10.2.3.4")
  }

}
