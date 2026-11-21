import Foundation

@main
struct TailscaleAndUPSCheck {
    static func main() {
        precondition(TailscaleAndUPSDetector.isCGNATIPv4("100.64.0.1"))
        precondition(TailscaleAndUPSDetector.isCGNATIPv4("100.101.202.55"))
        precondition(TailscaleAndUPSDetector.isCGNATIPv4("100.127.255.254"))
        precondition(!TailscaleAndUPSDetector.isCGNATIPv4("100.128.0.1"))
        precondition(!TailscaleAndUPSDetector.isCGNATIPv4("192.168.1.20"))

        let acSnap = TailscaleAndUPSDetector.parsePmsetBattOutput("""
        Now drawing from 'AC Power'
         -Back-UPS ES 650G2 (id=9912)\t100%; charged; 0:00 remaining present: true
        """)
        precondition(acSnap.available)
        precondition(acSnap.source == "ac")
        precondition(!acSnap.onBattery)
        precondition(acSnap.upsPresent)
        precondition(acSnap.percent == 100)
        precondition(acSnap.statusLabel == "市电 + UPS 就绪")

        let lowUpsSnap = TailscaleAndUPSDetector.parsePmsetBattOutput("""
        Now drawing from 'UPS Power'
         -APC Back-UPS 650 (id=9912)\t21%; discharging; 0:12 remaining present: true
        """)
        precondition(lowUpsSnap.available)
        precondition(lowUpsSnap.onBattery)
        precondition(lowUpsSnap.upsPresent)
        precondition(lowUpsSnap.lowBattery)
        precondition(lowUpsSnap.percent == 21)

        let ts = NativeTailscaleSnapshot(
            installed: true,
            connected: true,
            interfaceName: "utun4",
            ipv4: "100.88.19.7"
        )
        let scheme = ["ht", "tps"].joined()
        let lan = "\(scheme)://192.168.31.8:16666"
        precondition(ts.directURL(remoteAddress: lan, fallbackPort: 16666) == "\(scheme)://100.88.19.7:16666")
        print("TailscaleAndUPSCheck passed")
    }
}
