import Foundation
import SwiftUI

/// Subscribes only its child subtree to high-frequency `HostMetricsStore` updates
/// so parent containers (`ContentView`, navigation chrome, settings forms) never redraw
/// on 3-second metric ticks.
struct HostMetricsObserver<Content: View>: View {
    @ObservedObject var store: HostMetricsStore
    @ViewBuilder let content: (HostMetricsStore) -> Content

    var body: some View {
        content(store)
    }
}

/// High-frequency host telemetry store (CPU, memory, network throughput, disk I/O,
/// mounted volumes, power/UPS, and Tailscale interface probe).
///
/// Kept separate from `AppModel` so 3-second metric ticks only invalidate views
/// that explicitly observe `HostMetricsStore`, preventing whole-window redraw storms.
@MainActor
final class HostMetricsStore: ObservableObject {
    @Published var metrics: HostMetrics?
    @Published var metricHistory: [MetricHistoryPoint] = []
    @Published var lastMetricsAt: Date?
    @Published var powerSnapshot: NativePowerSnapshot?
    @Published var tailscaleStatus: NativeTailscaleSnapshot = .empty

    var lastPowerPollAt = Date.distantPast
    var powerPollTask: Task<Void, Never>?
    var tailscaleStatusLoaded = false
    var lastTailscalePollAt = Date.distantPast
    var tailscalePollTask: Task<Void, Never>?

    func recordMetrics(_ reading: HostMetrics) {
        if metrics != reading { metrics = reading }
        lastMetricsAt = Date()
        metricHistory.append(MetricHistoryPoint(
            time: Date(),
            cpu: reading.cpuPercent ?? 0,
            memory: Double(reading.memoryUsed) / Double(max(reading.memoryTotal, 1)) * 100,
            download: reading.networkDownBps ?? 0,
            upload: reading.networkUpBps ?? 0
        ))
        if metricHistory.count > 120 {
            metricHistory.removeFirst(metricHistory.count - 120)
        }
    }

    func releaseCaches() {
        metrics = nil
        metricHistory.removeAll(keepingCapacity: false)
    }

    func refreshPowerSnapshotIfNeeded(isPreview: Bool, force: Bool = false) {
        guard !isPreview, powerPollTask == nil else { return }
        let now = Date()
        if !force && powerSnapshot != nil && now.timeIntervalSince(lastPowerPollAt) < 15 {
            return
        }
        lastPowerPollAt = now
        powerPollTask = Task { @MainActor [weak self] in
            let next = await Task.detached(priority: .utility) {
                TailscaleAndUPSDetector.currentPowerSnapshot()
            }.value
            guard let self else { return }
            self.powerPollTask = nil
            if self.powerSnapshot != next {
                self.powerSnapshot = next
            }
        }
    }

    func refreshTailscaleStatusIfNeeded(isPreview: Bool, force: Bool = false) {
        guard !isPreview, tailscalePollTask == nil else { return }
        let now = Date()
        if !force && tailscaleStatusLoaded && now.timeIntervalSince(lastTailscalePollAt) < 15 {
            return
        }
        lastTailscalePollAt = now
        tailscalePollTask = Task { @MainActor [weak self] in
            let next = await Task.detached(priority: .utility) {
                TailscaleAndUPSDetector.detectTailscale()
            }.value
            guard let self else { return }
            self.tailscalePollTask = nil
            self.tailscaleStatusLoaded = true
            if self.tailscaleStatus != next {
                self.tailscaleStatus = next
            }
        }
    }
}
