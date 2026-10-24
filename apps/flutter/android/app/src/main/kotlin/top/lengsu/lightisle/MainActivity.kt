package top.lengsu.lightisle

import android.app.Activity
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.content.Intent
import android.os.CancellationSignal
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        // Method-channel enable/disable/session calls arrive on the main thread,
        // then run in this process-wide FIFO so a delayed older callback cannot
        // overtake a newer account replacement.
        private val backgroundOperations = Executors.newSingleThreadExecutor { task ->
            Thread(task, "lightisle-background-photo-config")
        }
    }

    private var exportResult: MethodChannel.Result? = null
    private var exportSource: File? = null
    private val exportRequest = 22991
    private val photosPermissionRequest = 22992
    private var photosPermissionPending: MethodChannel.Result? = null
    private val photoPrepareRequests = ConcurrentHashMap<String, CancellationSignal>()
    private var nasDiscovery: AndroidNasDiscovery? = null

    private fun photoReadPermission(): String =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun canReadPhotos(): Boolean =
        checkSelfPermission(photoReadPermission()) == PackageManager.PERMISSION_GRANTED

    private fun photoReadPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= 34)
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        else arrayOf(photoReadPermission())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lightisle/photos-background")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> runBackgroundOperation(result, "background_status_failed", "无法读取系统后台任务状态。") {
                        BackgroundPhotoBackup.status(applicationContext)
                    }
                    "bindSession" -> {
                        val token = call.argument<String>("token") ?: ""
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        val username = call.argument<String>("username") ?: ""
                        runBackgroundOperation(result, "background_session_bind_failed", "无法绑定当前登录会话。") {
                            BackgroundPhotoBackup.bindSession(applicationContext, token, server, cookie, username)
                        }
                    }
                    "endSession" -> {
                        val token = call.argument<String>("token") ?: ""
                        runBackgroundOperation(result, "background_session_end_failed", "无法清理后台备份授权。") {
                            BackgroundPhotoBackup.endSession(applicationContext, token)
                        }
                    }
                    "disable" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        runBackgroundOperation(result, "background_disable_failed", "无法取消后台任务，请重新尝试。") {
                            BackgroundPhotoBackup.disableForSession(applicationContext, server, cookie)
                        }
                    }
                    "enqueueScan" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        runBackgroundOperation(
                            result,
                            "background_scan_enqueue_failed",
                            "无法安排后台检查，请确认仍登录当前账号且后台备份已开启。",
                        ) {
                            BackgroundPhotoBackup.enqueueScanForSession(applicationContext, server, cookie)
                        }
                    }
                    "enable" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        val pin = call.argument<String>("certificateFingerprint") ?: ""
                        val device = call.argument<String>("deviceId") ?: ""
                        runBackgroundOperation(result, "background_enable_failed",
                            "无法配置后台备份：请确认登录权限、服务器地址和证书安全设置。") {
                            BackgroundPhotoBackup.enable(applicationContext, server, cookie, pin, device)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        nasDiscovery = AndroidNasDiscovery(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lightisle/discovery")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "discover" -> {
                        val requestId = call.argument<String>("requestId")
                        if (requestId == null || !requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))) {
                            result.error("invalid_discovery_request", "局域网发现请求编号无效。", null)
                        } else {
                            val timeoutMs = call.argument<Int>("timeoutMs")
                            val discovery = nasDiscovery
                            if (discovery == null) {
                                result.error("discovery_unavailable", "局域网发现服务不可用。", null)
                            } else {
                                discovery.discover(requestId, timeoutMs) { outcome ->
                                    if (outcome.errorCode != null) {
                                        result.error(outcome.errorCode, outcome.errorMessage, null)
                                    } else {
                                        result.success(mapOf("servers" to outcome.servers.map { it.asMap() }))
                                    }
                                }
                            }
                        }
                    }
                    "cancel" -> {
                        val requestId = call.argument<String>("requestId")
                        if (requestId == null || !requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))) {
                            result.error("invalid_discovery_request", "局域网发现请求编号无效。", null)
                        } else {
                            result.success(nasDiscovery?.cancel(requestId) == true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lightisle/photos")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "permission" -> result.success(canReadPhotos())
                    "requestPermission" -> {
                        if (canReadPhotos()) result.success(true)
                        else if (photosPermissionPending != null)
                            result.error("permission_busy", "照片权限请求正在进行。", null)
                        else {
                            photosPermissionPending = result
                            requestPermissions(photoReadPermissions(), photosPermissionRequest)
                        }
                    }
                    "list" -> {
                        if (!canReadPhotos()) result.error("photo_permission_required", "请先允许读取照片。", null)
                        else {
                            val cursor = call.argument<String>("beforeId")?.toLongOrNull()
                            val size = (call.argument<Int>("limit") ?: 80).coerceIn(1, 100)
                            Thread {
                                try {
                                    val listing = AndroidPhotoImport.list(this, cursor, size)
                                    runOnUiThread { result.success(listing) }
                                } catch (_: Exception) {
                                    runOnUiThread { result.error("photos_list_failed", "无法读取照片目录，请检查权限。", null) }
                                }
                            }.start()
                        }
                    }
                    "prepare" -> {
                        if (!canReadPhotos()) result.error("photo_permission_required", "请先允许读取照片。", null)
                        else {
                            val raw = call.argument<String>("id")
                            val id = raw?.toLongOrNull()
                            val requestId = call.argument<String>("requestId")
                            if (id == null || id <= 0) result.error("invalid_photo_id", "无效的照片编号。", null)
                            else if (requestId == null || !requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))) {
                                result.error("invalid_photo_request", "照片读取请求编号无效。", null)
                            } else {
                                val cancellation = CancellationSignal()
                                if (photoPrepareRequests.putIfAbsent(requestId, cancellation) != null) {
                                    result.error("duplicate_photo_request", "照片读取请求编号重复。", null)
                                    return@setMethodCallHandler
                                }
                                Thread {
                                    var preparedPath: String? = null
                                    var resultDeliveryQueued = false
                                    try {
                                        val prepared = AndroidPhotoImport.prepare(this, id, cancellation)
                                        preparedPath = prepared["path"] as? String
                                        if (cancellation.isCanceled) throw OperationCanceledException()
                                        runOnUiThread {
                                            try {
                                                if (cancellation.isCanceled || isFinishing || isDestroyed) {
                                                    releasePreparedPhotoAsync(preparedPath)
                                                    try {
                                                        result.error("photo_prepare_cancelled", "照片读取已取消。", null)
                                                    } catch (_: Exception) { }
                                                } else {
                                                    try {
                                                        result.success(prepared)
                                                    } catch (_: Exception) {
                                                        // The engine may detach after the copy finishes but before
                                                        // Flutter receives this result.
                                                        releasePreparedPhotoAsync(preparedPath)
                                                    }
                                                }
                                            } finally {
                                                photoPrepareRequests.remove(requestId, cancellation)
                                            }
                                        }
                                        resultDeliveryQueued = true
                                    } catch (_: OperationCanceledException) {
                                        AndroidPhotoImport.release(this, preparedPath)
                                        runOnUiThread {
                                            try {
                                                result.error("photo_prepare_cancelled", "照片读取已取消。", null)
                                            } catch (_: Exception) { } finally {
                                                photoPrepareRequests.remove(requestId, cancellation)
                                            }
                                        }
                                        resultDeliveryQueued = true
                                    } catch (_: Exception) {
                                        AndroidPhotoImport.release(this, preparedPath)
                                        runOnUiThread {
                                            try {
                                                result.error("photo_prepare_failed", "无法复制照片到上传临时区（可能空间不足或照片已变更）。", null)
                                            } catch (_: Exception) { } finally {
                                                photoPrepareRequests.remove(requestId, cancellation)
                                            }
                                        }
                                        resultDeliveryQueued = true
                                    } finally {
                                        if (!resultDeliveryQueued) photoPrepareRequests.remove(requestId, cancellation)
                                    }
                                }.start()
                            }
                        }
                    }
                    "cancelPrepare" -> {
                        val requestId = call.argument<String>("requestId")
                        if (requestId == null || !requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))) {
                            result.error("invalid_photo_request", "照片读取请求编号无效。", null)
                        } else {
                            val signal = photoPrepareRequests[requestId]
                            if (signal != null) Thread { signal.cancel() }.start()
                            result.success(signal != null)
                        }
                    }
                    "release" -> {
                        val path = call.argument<String>("path")
                        result.success(AndroidPhotoImport.release(this, path))
                    }
                    "isWifi" -> result.success(AndroidPhotoImport.isWifi(this))
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lightisle/export")
            .setMethodCallHandler { call, result ->
                if (call.method != "exportFile") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (exportResult != null) {
                    result.error("export_busy", "请先完成当前文件导出。", null)
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val name = call.argument<String>("name")?.substringAfterLast('/')?.substringAfterLast('\\')
                val source = path?.let { File(it).canonicalFile }
                val privateRoot = File(applicationInfo.dataDir).canonicalPath + File.separator
                if (source == null || !source.isFile || !source.path.startsWith(privateRoot) || name.isNullOrBlank()) {
                    result.error("invalid_export", "无法读取待导出的文件，请重新下载。", null)
                    return@setMethodCallHandler
                }
                exportResult = result
                exportSource = source
                try {
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }, exportRequest)
                } catch (_: Exception) {
                    exportResult = null
                    exportSource = null
                    result.error("export_unavailable", "系统文件选择器不可用。", null)
                }
            }
    }

    private fun runBackgroundOperation(
        result: MethodChannel.Result,
        errorCode: String,
        errorMessage: String,
        operation: () -> Any,
    ) {
        backgroundOperations.execute {
            try {
                val value = operation()
                runOnUiThread { result.success(value) }
            } catch (_: Exception) {
                runOnUiThread { result.error(errorCode, errorMessage, null) }
            }
        }
    }

    private fun releasePreparedPhotoAsync(path: String?) {
        if (path == null) return
        Thread { AndroidPhotoImport.release(applicationContext, path) }.start()
    }

    override fun onDestroy() {
        nasDiscovery?.destroy()
        nasDiscovery = null
        val pending = photoPrepareRequests.values.toList()
        photoPrepareRequests.clear()
        if (pending.isNotEmpty()) {
            Thread { pending.forEach { it.cancel() } }.start()
        }
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != photosPermissionRequest) return
        val result = photosPermissionPending ?: return
        photosPermissionPending = null
        result.success(canReadPhotos())
    }

    @Deprecated("Used by the Flutter activity plugin dispatch contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != exportRequest) return
        val result = exportResult ?: return
        val source = exportSource
        val destination = data?.data
        if (resultCode != Activity.RESULT_OK || destination == null || source == null) {
            exportResult = null
            exportSource = null
            result.success(null)
            return
        }
        Thread {
            var failed = false
            try {
                contentResolver.openOutputStream(destination, "w").use { output ->
                    if (output == null) throw java.io.IOException("Missing destination")
                    source.inputStream().use { input -> input.copyTo(output, 256 * 1024) }
                    output.flush()
                }
            } catch (_: Exception) {
                failed = true
                try { DocumentsContract.deleteDocument(contentResolver, destination) } catch (_: Exception) { }
            }
            runOnUiThread {
                exportResult = null
                exportSource = null
                if (failed) result.error("export_failed", "导出失败，请检查目标位置与存储空间。", null)
                else result.success(destination.toString())
            }
        }.start()
    }
}
