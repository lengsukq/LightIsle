package top.lengsu.lightisle

fun main() {
    check(NasDiscoveryPolicy.timeoutMs(null) == 10_000L)
    check(NasDiscoveryPolicy.timeoutMs(-1) == 1_000L)
    check(NasDiscoveryPolicy.timeoutMs(120_000) == 10_000L)
    check(NasDiscoveryPolicy.timeoutMs(4_500) == 4_500L)

    check(NasDiscoveryPolicy.isLightIsleService("_lightisle._tcp."))
    check(NasDiscoveryPolicy.isLightIsleService(" _LIGHTISLE._TCP "))
    check(!NasDiscoveryPolicy.isLightIsleService("_lightisle._udp."))
    check(!NasDiscoveryPolicy.isLightIsleService("_http._tcp."))
    check(!NasDiscoveryPolicy.isLightIsleService("_lightisle._tcp.local."))
    check(NasDiscoveryPolicy.serviceKey("Office Mac", "_lightisle._tcp.", "local.") != null)
    check(NasDiscoveryPolicy.serviceKey("Office Mac", "_http._tcp.", "local.") == null)

    val ipv4 = NasDiscoveryPolicy.candidate("NAS", "192.168.31.39", 8443)
        ?: error("private IPv4 candidate rejected")
    check(ipv4.host == "192.168.31.39")
    check(ipv4.url == "https://192.168.31.39:8443")
    check(ipv4.asMap().keys == setOf("name", "host", "port", "url"))
    check(NasDiscoveryPolicy.candidate("\u0001NAS\n", "10.0.0.5", 443)?.name == "NAS")
    check(NasDiscoveryPolicy.candidate("NAS", "10.0.0.5", 0) == null)
    check(NasDiscoveryPolicy.candidate("NAS", "10.0.0.5", 65536) == null)
    check(NasDiscoveryPolicy.candidate("NAS", "127.0.0.1", 443) == null)
    check(NasDiscoveryPolicy.candidate("NAS", "0.0.0.0", 443) == null)
    check(NasDiscoveryPolicy.candidate("NAS", "224.0.0.1", 443) == null)
    check(NasDiscoveryPolicy.candidate("NAS", "8.8.8.8", 443) == null)
    check(NasDiscoveryPolicy.candidate("NAS", "nas.local", 443) == null)

    val ipv6 = NasDiscoveryPolicy.candidate("NAS", "fd12:3456::1", 8443)
        ?: error("IPv6 unique-local candidate rejected")
    check(ipv6.host.contains(':'))
    check(ipv6.url.startsWith("https://["))
    check(ipv6.url.endsWith("]:8443"))
    val linkLocal = NasDiscoveryPolicy.candidate("NAS", "fe80::2%wlan0", 443)
        ?: error("scoped IPv6 link-local candidate rejected")
    check(linkLocal.host.endsWith("%wlan0"))
    check(linkLocal.url.contains("%25wlan0"))
    check(NasDiscoveryPolicy.candidate("NAS", "2001:4860:4860::8888", 443) == null)
    check(NasDiscoveryPolicy.candidate("NAS", "::1", 443) == null)
    check(NasDiscoveryPolicy.candidate("NAS", "ff02::fb", 443) == null)

    val queue = BoundedNasDiscoveryQueue<String>()
    repeat(NAS_DISCOVERY_MAX_QUEUED_SERVICES) { index ->
        check(queue.offer("service-$index", "service-$index"))
    }
    check(!queue.offer("overflow", "overflow"))
    check(!queue.offer("service-0", "duplicate"))
    val active = queue.takeNext()
    check(active == "service-0")
    check(!queue.offer("over-reserved", "over-reserved"))
    queue.resolutionFinished()
    check(queue.offer("service-later", "service-later"))

    val endpointQueue = BoundedNasDiscoveryQueue<String>()
    val seed = NasDiscoveryPolicy.candidate("NAS", "10.0.0.5", 443)!!
    check(endpointQueue.addCandidate(seed))
    check(!endpointQueue.addCandidate(seed.copy(name = "Same endpoint, other label")))
    repeat(NAS_DISCOVERY_MAX_CANDIDATES - 1) { index ->
        endpointQueue.addCandidate(NasDiscoveryPolicy.candidate("NAS $index", "10.0.0.${index + 6}", 443)!!)
    }
    check(endpointQueue.candidateCount == NAS_DISCOVERY_MAX_CANDIDATES)
    check(endpointQueue.candidatesFull)
    check(!endpointQueue.addCandidate(NasDiscoveryPolicy.candidate("Last", "10.0.0.99", 443)!!))

    val generations = NasDiscoveryGeneration()
    val oldScan = generations.begin()
    val newScan = generations.begin()
    check(!generations.isCurrent(oldScan))
    check(generations.isCurrent(newScan))
    generations.invalidate(oldScan)
    check(generations.isCurrent(newScan))
    generations.invalidate(newScan)
    check(!generations.isCurrent(newScan))

    println("PASS: LightIsle NSD address validation, fixed HTTPS output, bounded queues, candidate dedupe and stale callback generations")
}
