package top.lengsu.lightisle

import java.net.Inet6Address
import java.net.InetAddress

internal const val LIGHTISLE_NAS_SERVICE_TYPE = "_lightisle._tcp."
internal const val NAS_DISCOVERY_DEFAULT_TIMEOUT_MS = 10_000
internal const val NAS_DISCOVERY_MAX_TIMEOUT_MS = 10_000
internal const val NAS_DISCOVERY_MIN_TIMEOUT_MS = 1_000
internal const val NAS_DISCOVERY_MAX_CANDIDATES = 16
internal const val NAS_DISCOVERY_MAX_QUEUED_SERVICES = 16
internal const val NAS_DISCOVERY_MAX_TRACKED_SERVICES = 64

internal data class NasDiscoveryServer(
    val name: String,
    val host: String,
    val port: Int,
    val url: String,
    val scheme: String = "https",
) {
    fun asMap(): Map<String, Any> = mapOf(
        "name" to name,
        "host" to host,
        "port" to port,
        "url" to url,
        "scheme" to scheme,
    )

    internal fun endpointKey(): String = "$scheme|${host.lowercase()}|$port"
}

/** Pure input validation and bounded state shared by the Android NSD adapter and offline tests. */
internal object NasDiscoveryPolicy {
    fun timeoutMs(requested: Int?): Long =
        (requested ?: NAS_DISCOVERY_DEFAULT_TIMEOUT_MS)
            .coerceIn(NAS_DISCOVERY_MIN_TIMEOUT_MS, NAS_DISCOVERY_MAX_TIMEOUT_MS)
            .toLong()

    fun isLightIsleService(type: String?): Boolean =
        type?.trim()?.trimEnd('.')?.equals("_lightisle._tcp", ignoreCase = true) == true

    fun serviceKey(name: String?, type: String?, domain: String?): String? {
        if (!isLightIsleService(type)) return null
        val serviceName = name?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        if (serviceName.length > 255) return null
        val normalizedDomain = domain?.trim()?.trimEnd('.')?.lowercase()?.takeIf { it.isNotEmpty() } ?: "local"
        return "${serviceName.lowercase()}|_lightisle._tcp|$normalizedDomain"
    }

    fun candidate(name: String?, rawHost: String?, port: Int, rawScheme: String? = null): NasDiscoveryServer? {
        if (port !in 1..65535) return null
        // Absent TXT records come from older HTTPS-only hosts. Unexpected
        // values must never turn into an implicit insecure downgrade.
        val scheme = rawScheme?.trim()?.lowercase() ?: "https"
        if (scheme != "http" && scheme != "https") return null
        val host = normalizeLocalHost(rawHost ?: return null) ?: return null
        val safeName = displayName(name)
        val urlHost = if (host.contains(':')) "[${host.replace("%", "%25")}]" else host
        return NasDiscoveryServer(safeName, host, port, "$scheme://$urlHost:$port", scheme)
    }

    private fun displayName(value: String?): String {
        val cleaned = value.orEmpty()
            .filterNot { Character.isISOControl(it) }
            .trim()
            .take(128)
        return cleaned.ifEmpty { "LightIsle NAS" }
    }

    /** Accept numeric LAN addresses only. This deliberately never performs a DNS lookup. */
    private fun normalizeLocalHost(rawHost: String): String? {
        if (rawHost.isEmpty() || rawHost.length > 128 || rawHost != rawHost.trim()) return null
        if (rawHost.contains(':')) return normalizeIpv6(rawHost)
        return normalizeIpv4(rawHost)
    }

    private fun normalizeIpv4(rawHost: String): String? {
        val pieces = rawHost.split('.')
        if (pieces.size != 4) return null
        val octets = pieces.map { piece ->
            if (piece.isEmpty() || piece.length > 3 || !piece.all { it in '0'..'9' }) return null
            piece.toIntOrNull()?.takeIf { it in 0..255 } ?: return null
        }
        val address = try {
            InetAddress.getByAddress(ByteArray(4) { octets[it].toByte() })
        } catch (_: Exception) {
            return null
        }
        if (!isLanAddress(address)) return null
        return octets.joinToString(".")
    }

    private fun normalizeIpv6(rawHost: String): String? {
        val zoneIndex = rawHost.lastIndexOf('%')
        val addressText = if (zoneIndex >= 0) rawHost.substring(0, zoneIndex) else rawHost
        val zone = if (zoneIndex >= 0) rawHost.substring(zoneIndex + 1) else null
        if (zone != null && (!zone.matches(Regex("[A-Za-z0-9_.-]{1,32}")))) return null
        if (addressText.isEmpty() || !addressText.all { it.isDigit() || it in "abcdefABCDEF:." }) return null
        val address = try {
            InetAddress.getByName(addressText) as? Inet6Address ?: return null
        } catch (_: Exception) {
            return null
        }
        if (!isLanAddress(address)) return null
        if (zone != null && !address.isLinkLocalAddress && !address.isSiteLocalAddress) return null
        val canonicalAddress = address.hostAddress?.substringBefore('%') ?: return null
        return if (zone == null) canonicalAddress else "$canonicalAddress%$zone"
    }

    private fun isLanAddress(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress || address.isLoopbackAddress || address.isMulticastAddress) return false
        if (address.isSiteLocalAddress || address.isLinkLocalAddress) return true
        val bytes = address.address
        // IPv6 unique-local addresses occupy fc00::/7; Java's site-local check does not include them.
        return bytes.size == 16 && ((bytes[0].toInt() and 0xff) and 0xfe) == 0xfc
    }
}

/** A bounded FIFO of service records and distinct, displayable endpoints. */
internal class BoundedNasDiscoveryQueue<T>(
    private val maxQueuedServices: Int = NAS_DISCOVERY_MAX_QUEUED_SERVICES,
    private val maxCandidates: Int = NAS_DISCOVERY_MAX_CANDIDATES,
    private val maxTrackedServices: Int = NAS_DISCOVERY_MAX_TRACKED_SERVICES,
) {
    private val pending = java.util.ArrayDeque<T>()
    private val seenServices = HashSet<String>()
    private val serversByEndpoint = LinkedHashMap<String, NasDiscoveryServer>()
    private var resolutionInFlight = false

    val queuedCount: Int get() = pending.size
    val candidateCount: Int get() = serversByEndpoint.size
    val candidatesFull: Boolean get() = candidateCount >= maxCandidates

    fun offer(serviceKey: String, service: T): Boolean {
        if (serviceKey.isBlank() || serviceKey in seenServices) return false
        if (pending.size >= maxQueuedServices || seenServices.size >= maxTrackedServices) return false
        if (candidatesByQueueReservationsFull()) return false
        seenServices += serviceKey
        pending.addLast(service)
        return true
    }

    fun takeNext(): T? {
        if (resolutionInFlight || pending.isEmpty()) return null
        resolutionInFlight = true
        return pending.removeFirst()
    }

    fun resolutionFinished() {
        resolutionInFlight = false
    }

    fun addCandidate(server: NasDiscoveryServer): Boolean {
        if (candidatesFull) return false
        val key = server.endpointKey()
        if (key in serversByEndpoint) return false
        serversByEndpoint[key] = server
        return true
    }

    fun candidates(): List<NasDiscoveryServer> = serversByEndpoint.values.toList()

    fun clear() {
        pending.clear()
        seenServices.clear()
        serversByEndpoint.clear()
        resolutionInFlight = false
    }

    private fun candidatesByQueueReservationsFull(): Boolean =
        serversByEndpoint.size + pending.size + (if (resolutionInFlight) 1 else 0) >= maxCandidates
}

/** Generation values make late NSD callbacks harmless after cancel or replacement. */
internal class NasDiscoveryGeneration {
    private var current = 0L

    fun begin(): Long {
        current += 1
        return current
    }

    fun isCurrent(token: Long): Boolean = token == current

    fun invalidate(token: Long) {
        if (isCurrent(token)) current += 1
    }
}
