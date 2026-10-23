package top.lengsu.lightisle

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ext.SdkExtensions

internal data class NasDiscoveryOutcome(
    val servers: List<NasDiscoveryServer> = emptyList(),
    val errorCode: String? = null,
    val errorMessage: String? = null,
)

/** Activity-scoped Android NSD discovery. It never connects to or authenticates with a NAS. */
internal class AndroidNasDiscovery(context: Context) {
    private val appContext = context.applicationContext
    private val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as? NsdManager
    private val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private val generations = NasDiscoveryGeneration()
    private var activeScan: Scan? = null
    private var activeResolution: Resolution? = null
    private var destroyed = false

    fun discover(requestId: String, requestedTimeoutMs: Int?, callback: (NasDiscoveryOutcome) -> Unit) {
        checkMainThread()
        if (destroyed) {
            callback(failure("discovery_unavailable", "局域网发现服务已关闭。"))
            return
        }
        activeScan?.let { finish(it, failure("discovery_cancelled", "局域网发现已被新的扫描替换。")) }
        val manager = nsdManager
        if (manager == null) {
            callback(failure("discovery_unavailable", "此设备没有可用的局域网发现服务。"))
            return
        }

        val scan = Scan(generations.begin(), requestId, callback)
        activeScan = scan
        try {
            scan.multicastLock = acquireMulticastLock()
            mainHandler.postDelayed(scan.timeout, NasDiscoveryPolicy.timeoutMs(requestedTimeoutMs))
            scan.discoveryRequested = true
            manager.discoverServices(LIGHTISLE_NAS_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, scan.discoveryListener)
        } catch (_: SecurityException) {
            finish(scan, failure("discovery_permission_denied", "系统拒绝了局域网发现，请检查应用的本地网络权限。"))
        } catch (_: Exception) {
            finish(scan, failure("discovery_failed", "无法启动局域网发现，请检查当前网络后重试。"))
        }
    }

    fun cancel(requestId: String): Boolean {
        checkMainThread()
        val scan = activeScan ?: return false
        if (scan.requestId != requestId) return false
        finish(scan, failure("discovery_cancelled", "局域网发现已取消。"))
        return true
    }

    fun destroy() {
        checkMainThread()
        if (destroyed) return
        activeScan?.let { finish(it, failure("discovery_cancelled", "局域网发现已取消。")) }
        destroyed = true
        // Android has no public cancellation method for resolveService callbacks. Keep the listener
        // identity so its eventual callback only releases its own in-flight slot and cannot alter
        // any later scan.
    }

    private fun acquireMulticastLock(): WifiManager.MulticastLock? {
        if (!needsLegacyMulticastLock()) return null
        val manager = wifiManager ?: return null
        return manager.createMulticastLock("LightIsle-NAS-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun needsLegacyMulticastLock(): Boolean = when {
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU -> true
        Build.VERSION.SDK_INT == Build.VERSION_CODES.TIRAMISU ->
            SdkExtensions.getExtensionVersion(Build.VERSION_CODES.TIRAMISU) < 7
        else -> false
    }

    private fun pump(scan: Scan) {
        if (!isCurrent(scan) || activeResolution != null || scan.queue.candidatesFull) return
        val service = scan.queue.takeNext() ?: return
        val listener = object : NsdManager.ResolveListener {
            override fun onServiceResolved(resolvedService: NsdServiceInfo) {
                resolutionFinished(scan, this) {
                    val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        resolvedService.hostAddresses
                    } else {
                        emptyList()
                    }.ifEmpty { listOfNotNull(resolvedService.host) }
                    val candidate = addresses.firstNotNullOfOrNull { address ->
                        NasDiscoveryPolicy.candidate(
                            resolvedService.serviceName,
                            address.hostAddress,
                            resolvedService.port,
                        )
                    }
                    if (candidate != null) scan.queue.addCandidate(candidate)
                }
            }

            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                resolutionFinished(scan, this) { }
            }
        }
        val resolution = Resolution(scan, listener)
        activeResolution = resolution
        try {
            nsdManager?.resolveService(service, listener)
                ?: resolutionFinished(scan, listener) { }
        } catch (_: SecurityException) {
            resolutionFinished(scan, listener) {
                finish(scan, failure("discovery_permission_denied", "系统拒绝读取发现到的设备地址，请检查本地网络权限。"))
            }
        } catch (_: Exception) {
            resolutionFinished(scan, listener) { }
        }
    }

    private fun resolutionFinished(scan: Scan, listener: NsdManager.ResolveListener, accept: () -> Unit) {
        checkMainThread()
        val resolution = activeResolution
        if (resolution?.listener !== listener) return
        activeResolution = null
        scan.queue.resolutionFinished()
        if (isCurrent(scan)) {
            accept()
            if (scan.queue.candidatesFull) {
                finish(scan, NasDiscoveryOutcome(servers = scan.queue.candidates()))
            } else {
                pump(scan)
            }
        } else {
            activeScan?.let(::pump)
        }
    }

    private fun finish(scan: Scan, outcome: NasDiscoveryOutcome) {
        if (!isCurrent(scan)) return
        scan.finished = true
        activeScan = null
        generations.invalidate(scan.generation)
        mainHandler.removeCallbacks(scan.timeout)
        cancelResolution(scan)
        if (scan.discoveryRequested) {
            try {
                nsdManager?.stopServiceDiscovery(scan.discoveryListener)
            } catch (_: Exception) {
                // A start failure or a race with the system callback can make the listener
                // already stopped. The activity still releases the lock and invalidates callbacks.
            }
        }
        scan.multicastLock?.let { lock ->
            try {
                if (lock.isHeld) lock.release()
            } catch (_: Exception) { }
        }
        scan.queue.clear()
        try {
            scan.callback(outcome)
        } catch (_: Exception) {
            // A detached Flutter engine may reject a late result during Activity teardown.
        }
    }

    private fun cancelResolution(scan: Scan) {
        val resolution = activeResolution ?: return
        if (resolution.scan !== scan) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            activeResolution = null
            scan.queue.resolutionFinished()
            try {
                nsdManager?.stopServiceResolution(resolution.listener)
            } catch (_: Exception) { }
        }
    }

    private fun isCurrent(scan: Scan): Boolean =
        !destroyed && !scan.finished && activeScan === scan && generations.isCurrent(scan.generation)

    private fun checkMainThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "AndroidNasDiscovery must be used on the main thread" }
    }

    private fun failure(code: String, message: String) =
        NasDiscoveryOutcome(errorCode = code, errorMessage = message)

    private inner class Scan(
        val generation: Long,
        val requestId: String,
        val callback: (NasDiscoveryOutcome) -> Unit,
    ) {
        val queue = BoundedNasDiscoveryQueue<NsdServiceInfo>()
        var finished = false
        var discoveryRequested = false
        var multicastLock: WifiManager.MulticastLock? = null
        val timeout = Runnable {
            if (!isCurrent(this)) return@Runnable
            val candidates = queue.candidates()
            if (candidates.isEmpty()) {
                finish(this, failure("discovery_timeout", "约10秒内没有发现 LightIsle NAS。可手动输入服务器地址。"))
            } else {
                finish(this, NasDiscoveryOutcome(servers = candidates))
            }
        }
        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (!isCurrent(this@Scan)) return
                val serviceKey = NasDiscoveryPolicy.serviceKey(
                    serviceInfo.serviceName,
                    serviceInfo.serviceType,
                    "local.",
                ) ?: return
                if (queue.offer(serviceKey, serviceInfo)) pump(this@Scan)
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                finish(this@Scan, failure("discovery_failed", "系统无法启动局域网发现，请检查当前网络或权限后重试。"))
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
    }

    private data class Resolution(val scan: Scan, val listener: NsdManager.ResolveListener)
}
