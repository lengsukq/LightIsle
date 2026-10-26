package top.lengsu.lightisle

import org.junit.Assert.*
import org.junit.Test

class NasDiscoveryProtocolTest {
    @Test fun httpRequiresExplicitTxtSchemeAndPrivateAddress() {
        val https = NasDiscoveryPolicy.candidate("Home NAS", "192.168.1.40", 16666)
        assertEquals("https://192.168.1.40:16666", https?.url)
        val http = NasDiscoveryPolicy.candidate("Home NAS", "192.168.1.40", 16666, "http")
        assertEquals("http://192.168.1.40:16666", http?.url)
        assertEquals("http", http?.asMap()?.get("scheme"))
        assertNull(NasDiscoveryPolicy.candidate("NAS", "192.168.1.40", 16666, "ftp"))
        assertNull(NasDiscoveryPolicy.candidate("NAS", "8.8.8.8", 16666, "http"))
    }
}
