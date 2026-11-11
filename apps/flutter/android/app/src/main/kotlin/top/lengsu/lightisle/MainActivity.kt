package top.lengsu.lightisle

import android.Manifest
import android.app.Activity
import android.app.PictureInPictureParams
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class MainActivity : FlutterActivity() {
    companion object {
        // Method-channel enable/disable/session calls arrive on the main thread,
        // then run in this process-wide FIFO so a delayed older callback cannot
        // overtake a newer account replacement.
        private val backgroundOperations = Executors.newSingleThreadExecutor { task ->
            Thread(task, "lightisle-background-photo-config").apply { isDaemon = true }
        }

        private fun newIoExecutor(): ExecutorService =
            Executors.newFixedThreadPool(2) { task ->
                Thread(task, "lightisle-activity-io").apply { isDaemon = true }
            }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var ioExecutor: ExecutorService = newIoExecutor()

    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingBatchExportResult: MethodChannel.Result? = null
    private var exportSource: File? = null
    private var exportBatchFiles: List<Pair<File, String>>? = null
    private val exportRequest = 22991
    private val exportBatchRequest = 22993
    private val photosPermissionRequest = 22992
    private var photosPermissionPending: MethodChannel.Result? = null
    private var photosPermissionIncludesVideos = false
    private val photoPrepareRequests = ConcurrentHashMap<String, CancellationSignal>()
    private var nasDiscovery: AndroidNasDiscovery? = null

    private var pipChannel: MethodChannel? = null
    private var sessionVaultChannel: MethodChannel? = null
    private var photosBackgroundChannel: MethodChannel? = null
    private var discoveryChannel: MethodChannel? = null
    private var photosChannel: MethodChannel? = null
    private var exportChannel: MethodChannel? = null

    private fun ensureIoExecutor(): ExecutorService {
        if (ioExecutor.isShutdown) {
            ioExecutor = newIoExecutor()
        }
        return ioExecutor
    }

    override fun onPictureInPictureModeChanged(inPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(inPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("state", inPictureInPictureMode)
    }

    private fun photoReadPermission(): String =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES
        else Manifest.permission.READ_EXTERNAL_STORAGE

    private fun canReadPhotos(includeVideos: Boolean = false): Boolean =
        checkSelfPermission(photoReadPermission()) == PackageManager.PERMISSION_GRANTED &&
            (!includeVideos || Build.VERSION.SDK_INT < 33 ||
                checkSelfPermission(Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED)

    private fun photoReadPermissions(includeVideos: Boolean): Array<String> =
        if (Build.VERSION.SDK_INT >= 34) {
            if (includeVideos) arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VIDEO,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
            else arrayOf(
                Manifest.permission.READ_MEDIA_IMAGES,
                Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
            )
        } else if (Build.VERSION.SDK_INT >= 33 && includeVideos) {
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        } else arrayOf(photoReadPermission())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ensureIoExecutor()
        val appContext = applicationContext
        val activityRef = WeakReference(this)

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "lightisle/pip").also { channel ->
            channel.setMethodCallHandler { call, result ->
                val activity = activityRef.get()
                if (activity == null || activity.isFinishing || activity.isDestroyed) {
                    result.error("pip_unavailable", "当前界面已关闭。", null)
                    return@setMethodCallHandler
                }
                val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                when (call.method) {
                    "supported" -> result.success(supported)
                    "enter" -> {
                        if (!supported) {
                            result.error("pip_unavailable", "此设备不支持画中画。", null)
                        } else {
                            try {
                                result.success(
                                    activity.enterPictureInPictureMode(
                                        PictureInPictureParams.Builder().build(),
                                    ),
                                )
                            } catch (_: Exception) {
                                result.error("pip_failed", "无法进入画中画，请在设备设置中检查权限。", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        sessionVaultChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lightisle/session-vault",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                val method = call.method
                val rawValue = call.argument<String>("value")
                backgroundOperations.execute {
                    try {
                        val value: Any? = when (method) {
                            "read" -> SessionVault.read(appContext)
                            "dav.read" -> SessionVault.readDav(appContext)
                            "history.read" -> SessionVault.readHistory(appContext)
                            "write" -> {
                                SessionVault.write(appContext, rawValue ?: error("Missing session"))
                                null
                            }
                            "clear" -> {
                                SessionVault.clear(appContext)
                                null
                            }
                            "dav.write" -> {
                                SessionVault.writeDav(appContext, rawValue ?: error("Missing DAV vault"))
                                null
                            }
                            "dav.clear" -> {
                                SessionVault.clearDav(appContext)
                                null
                            }
                            "history.write" -> {
                                SessionVault.writeHistory(appContext, rawValue ?: error("Missing history vault"))
                                null
                            }
                            "history.clear" -> {
                                SessionVault.clearHistory(appContext)
                                null
                            }
                            else -> {
                                mainHandler.post {
                                    val act = activityRef.get()
                                    if (act != null && !act.isDestroyed) {
                                        try { result.notImplemented() } catch (_: Exception) { }
                                    }
                                }
                                return@execute
                            }
                        }
                        mainHandler.post {
                            val act = activityRef.get()
                            if (act != null && !act.isDestroyed) {
                                try { result.success(value) } catch (_: Exception) { }
                            }
                        }
                    } catch (_: Exception) {
                        mainHandler.post {
                            val act = activityRef.get()
                            if (act != null && !act.isDestroyed) {
                                try {
                                    result.error(
                                        "session_vault_unavailable",
                                        "无法访问保存的登录状态，请解锁设备并重试。",
                                        null,
                                    )
                                } catch (_: Exception) { }
                            }
                        }
                    }
                }
            }
        }

        photosBackgroundChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lightisle/photos-background",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> runBackgroundOperation(
                        activityRef,
                        result,
                        "background_status_failed",
                        "无法读取系统后台任务状态。",
                    ) {
                        BackgroundPhotoBackup.status(appContext)
                    }
                    "bindSession" -> {
                        val token = call.argument<String>("token") ?: ""
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        val username = call.argument<String>("username") ?: ""
                        runBackgroundOperation(
                            activityRef,
                            result,
                            "background_session_bind_failed",
                            "无法绑定当前登录会话。",
                        ) {
                            BackgroundPhotoBackup.bindSession(appContext, token, server, cookie, username)
                        }
                    }
                    "endSession" -> {
                        val token = call.argument<String>("token") ?: ""
                        runBackgroundOperation(
                            activityRef,
                            result,
                            "background_session_end_failed",
                            "无法清理后台备份授权。",
                        ) {
                            BackgroundPhotoBackup.endSession(appContext, token)
                        }
                    }
                    "forgetSession" -> runBackgroundOperation(
                        activityRef,
                        result,
                        "background_session_end_failed",
                        "无法清理旧账号的后台备份授权，请重试。",
                    ) {
                        BackgroundPhotoBackup.forgetSession(appContext)
                    }
                    "disable" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        runBackgroundOperation(
                            activityRef,
                            result,
                            "background_disable_failed",
                            "无法取消后台任务，请重新尝试。",
                        ) {
                            BackgroundPhotoBackup.disableForSession(appContext, server, cookie)
                        }
                    }
                    "enqueueScan" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        runBackgroundOperation(
                            activityRef,
                            result,
                            "background_scan_enqueue_failed",
                            "无法安排后台检查，请确认仍登录当前账号且后台备份已开启。",
                        ) {
                            BackgroundPhotoBackup.enqueueScanForSession(appContext, server, cookie)
                        }
                    }
                    "enable" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        val pin = call.argument<String>("certificateFingerprint") ?: ""
                        val device = call.argument<String>("deviceId") ?: ""
                        val rootID = call.argument<String>("rootID") ?: ""
                        val rootGeneration = call.argument<Number>("rootGeneration")?.toLong() ?: 0L
                        val photosPath = call.argument<String>("photosPath") ?: ""
                        runBackgroundOperation(
                            activityRef,
                            result,
                            "background_enable_failed",
                            "无法配置后台备份：请确认登录权限、服务器地址和证书安全设置。",
                        ) {
                            BackgroundPhotoBackup.enable(
                                appContext,
                                server,
                                cookie,
                                pin,
                                device,
                                rootID,
                                rootGeneration,
                                photosPath,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        nasDiscovery?.destroy()
        nasDiscovery = AndroidNasDiscovery(appContext)
        discoveryChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lightisle/discovery",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "discover" -> {
                        val requestId = call.argument<String>("requestId")
                        if (requestId == null || !requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))) {
                            result.error("invalid_discovery_request", "局域网发现请求编号无效。", null)
                        } else {
                            val timeoutMs = call.argument<Int>("timeoutMs")
                            val discovery = activityRef.get()?.nasDiscovery
                            if (discovery == null) {
                                result.error("discovery_unavailable", "局域网发现服务不可用。", null)
                            } else {
                                discovery.discover(requestId, timeoutMs) { outcome ->
                                    val act = activityRef.get()
                                    if (act == null || act.isDestroyed) return@discover
                                    try {
                                        if (outcome.errorCode != null) {
                                            result.error(outcome.errorCode, outcome.errorMessage, null)
                                        } else {
                                            result.success(mapOf("servers" to outcome.servers.map { it.asMap() }))
                                        }
                                    } catch (_: Exception) { }
                                }
                            }
                        }
                    }
                    "cancel" -> {
                        val requestId = call.argument<String>("requestId")
                        if (requestId == null || !requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))) {
                            result.error("invalid_discovery_request", "局域网发现请求编号无效。", null)
                        } else {
                            result.success(activityRef.get()?.nasDiscovery?.cancel(requestId) == true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        photosChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lightisle/photos",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                val activity = activityRef.get()
                if (activity == null || activity.isFinishing || activity.isDestroyed) {
                    result.error("activity_unavailable", "当前界面已关闭。", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "permission" -> result.success(activity.canReadPhotos(call.argument<Boolean>("includeVideos") == true))
                    "requestPermission" -> {
                        val includeVideos = call.argument<Boolean>("includeVideos") == true
                        if (activity.canReadPhotos(includeVideos)) result.success(true)
                        else if (activity.photosPermissionPending != null)
                            result.error("permission_busy", "照片权限请求正在进行。", null)
                        else {
                            activity.photosPermissionPending = result
                            activity.photosPermissionIncludesVideos = includeVideos
                            activity.requestPermissions(
                                activity.photoReadPermissions(includeVideos),
                                activity.photosPermissionRequest,
                            )
                        }
                    }
                    "list" -> {
                        val includeVideos = call.argument<Boolean>("includeVideos") == true
                        if (!activity.canReadPhotos(includeVideos)) {
                            result.error("photo_permission_required", "请先允许读取照片或视频。", null)
                        } else {
                            val cursor = call.argument<String>("beforeId")?.toLongOrNull()
                            val size = (call.argument<Int>("limit") ?: 80).coerceIn(1, 100)
                            val handler = activity.mainHandler
                            try {
                                activity.ensureIoExecutor().execute {
                                    try {
                                        val listing = AndroidPhotoImport.list(appContext, cursor, size, includeVideos)
                                        handler.post {
                                            val act = activityRef.get()
                                            if (act != null && !act.isDestroyed) {
                                                try { result.success(listing) } catch (_: Exception) { }
                                            }
                                        }
                                    } catch (_: Exception) {
                                        handler.post {
                                            val act = activityRef.get()
                                            if (act != null && !act.isDestroyed) {
                                                try {
                                                    result.error("photos_list_failed", "无法读取照片目录，请检查权限。", null)
                                                } catch (_: Exception) { }
                                            }
                                        }
                                    }
                                }
                            } catch (_: RejectedExecutionException) {
                                result.error("photos_list_failed", "照片目录读取任务已取消。", null)
                            }
                        }
                    }
                    "prepare" -> {
                        if (!activity.canReadPhotos(call.argument<Boolean>("includeVideos") == true)) {
                            result.error("photo_permission_required", "请先允许读取照片或视频。", null)
                        } else {
                            val raw = call.argument<String>("id")
                            val id = raw?.toLongOrNull()
                            val requestId = call.argument<String>("requestId")
                            if (id == null || id <= 0) {
                                result.error("invalid_photo_id", "无效的照片编号。", null)
                            } else if (requestId == null || !requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))) {
                                result.error("invalid_photo_request", "照片读取请求编号无效。", null)
                            } else {
                                val cancellation = CancellationSignal()
                                val requestsMap = activity.photoPrepareRequests
                                if (requestsMap.putIfAbsent(requestId, cancellation) != null) {
                                    result.error("duplicate_photo_request", "照片读取请求编号重复。", null)
                                    return@setMethodCallHandler
                                }
                                val handler = activity.mainHandler
                                try {
                                    activity.ensureIoExecutor().execute {
                                        var preparedPath: String? = null
                                        var resultDeliveryQueued = false
                                        try {
                                            val prepared = AndroidPhotoImport.prepare(appContext, id, cancellation)
                                            preparedPath = prepared["path"] as? String
                                            if (cancellation.isCanceled) throw OperationCanceledException()
                                            handler.post {
                                                try {
                                                    val act = activityRef.get()
                                                    if (cancellation.isCanceled || act == null || act.isFinishing || act.isDestroyed) {
                                                        releasePreparedPhotoAsync(appContext, preparedPath)
                                                        try {
                                                            result.error("photo_prepare_cancelled", "照片读取已取消。", null)
                                                        } catch (_: Exception) { }
                                                    } else {
                                                        try {
                                                            result.success(prepared)
                                                        } catch (_: Exception) {
                                                            // The engine may detach after the copy finishes but before
                                                            // Flutter receives this result.
                                                            releasePreparedPhotoAsync(appContext, preparedPath)
                                                        }
                                                    }
                                                } finally {
                                                    requestsMap.remove(requestId, cancellation)
                                                }
                                            }
                                            resultDeliveryQueued = true
                                        } catch (_: OperationCanceledException) {
                                            AndroidPhotoImport.release(appContext, preparedPath)
                                            handler.post {
                                                try {
                                                    val act = activityRef.get()
                                                    if (act != null && !act.isDestroyed) {
                                                        result.error("photo_prepare_cancelled", "照片读取已取消。", null)
                                                    }
                                                } catch (_: Exception) { } finally {
                                                    requestsMap.remove(requestId, cancellation)
                                                }
                                            }
                                            resultDeliveryQueued = true
                                        } catch (_: Exception) {
                                            AndroidPhotoImport.release(appContext, preparedPath)
                                            handler.post {
                                                try {
                                                    val act = activityRef.get()
                                                    if (act != null && !act.isDestroyed) {
                                                        result.error(
                                                            "photo_prepare_failed",
                                                            "无法复制照片到上传临时区（可能空间不足或照片已变更）。",
                                                            null,
                                                        )
                                                    }
                                                } catch (_: Exception) { } finally {
                                                    requestsMap.remove(requestId, cancellation)
                                                }
                                            }
                                            resultDeliveryQueued = true
                                        } finally {
                                            if (!resultDeliveryQueued) requestsMap.remove(requestId, cancellation)
                                        }
                                    }
                                } catch (_: RejectedExecutionException) {
                                    requestsMap.remove(requestId, cancellation)
                                    result.error("photo_prepare_cancelled", "照片读取已取消。", null)
                                }
                            }
                        }
                    }
                    "cancelPrepare" -> {
                        val requestId = call.argument<String>("requestId")
                        if (requestId == null || !requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))) {
                            result.error("invalid_photo_request", "照片读取请求编号无效。", null)
                        } else {
                            val signal = activity.photoPrepareRequests[requestId]
                            if (signal != null) {
                                backgroundOperations.execute { signal.cancel() }
                            }
                            result.success(signal != null)
                        }
                    }
                    "release" -> {
                        val path = call.argument<String>("path")
                        result.success(AndroidPhotoImport.release(appContext, path))
                    }
                    "isWifi" -> result.success(AndroidPhotoImport.isWifi(appContext))
                    else -> result.notImplemented()
                }
            }
        }

        exportChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "lightisle/export",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                val activity = activityRef.get()
                if (activity == null || activity.isFinishing || activity.isDestroyed) {
                    result.error("export_unavailable", "当前界面已关闭。", null)
                    return@setMethodCallHandler
                }
                if (call.method != "exportFile" && call.method != "exportFiles") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (activity.pendingSaveResult != null || activity.pendingBatchExportResult != null) {
                    result.error("export_busy", "请先完成当前文件导出。", null)
                    return@setMethodCallHandler
                }
                val privateRoot = File(appContext.applicationInfo.dataDir).canonicalPath + File.separator
                if (call.method == "exportFiles") {
                    val raw = call.argument<List<Map<String, String>>>("files")
                    val sources = raw?.mapNotNull { item ->
                        val name = item["name"] ?: return@mapNotNull null
                        val file = item["path"]?.let { File(it).canonicalFile } ?: return@mapNotNull null
                        if (!file.isFile || !file.path.startsWith(privateRoot) ||
                            name.isBlank() || name == "." || name == ".." ||
                            name.contains('/') || name.contains('\\')) null
                        else Pair(file, name)
                    }
                    if (raw.isNullOrEmpty() || raw.size > 20 || sources?.size != raw.size) {
                        result.error("invalid_export", "批量导出列表或本机文件无效。", null)
                        return@setMethodCallHandler
                    }
                    activity.pendingBatchExportResult = result
                    activity.exportBatchFiles = sources
                    try {
                        activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                        }, activity.exportBatchRequest)
                    } catch (_: Exception) {
                        activity.pendingBatchExportResult = null
                        activity.exportBatchFiles = null
                        result.error("export_unavailable", "无法打开系统文件夹选择器。", null)
                    }
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                val name = call.argument<String>("name")?.substringAfterLast('/')?.substringAfterLast('\\')
                val source = path?.let { File(it).canonicalFile }
                if (source == null || !source.isFile || !source.path.startsWith(privateRoot) || name.isNullOrBlank()) {
                    result.error("invalid_export", "无法读取待导出的文件，请重新下载。", null)
                    return@setMethodCallHandler
                }
                activity.pendingSaveResult = result
                activity.exportSource = source
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }, activity.exportRequest)
                } catch (_: Exception) {
                    activity.pendingSaveResult = null
                    activity.exportSource = null
                    result.error("export_unavailable", "系统文件选择器不可用。", null)
                }
            }
        }
    }

    private fun runBackgroundOperation(
        activityRef: WeakReference<MainActivity>,
        result: MethodChannel.Result,
        errorCode: String,
        errorMessage: String,
        operation: () -> Any,
    ) {
        val handler = mainHandler
        backgroundOperations.execute {
            try {
                val value = operation()
                handler.post {
                    val act = activityRef.get()
                    if (act != null && !act.isDestroyed) {
                        try { result.success(value) } catch (_: Exception) { }
                    }
                }
            } catch (_: Exception) {
                handler.post {
                    val act = activityRef.get()
                    if (act != null && !act.isDestroyed) {
                        try { result.error(errorCode, errorMessage, null) } catch (_: Exception) { }
                    }
                }
            }
        }
    }

    private fun releasePreparedPhotoAsync(appContext: android.content.Context, path: String?) {
        if (path == null) return
        backgroundOperations.execute { AndroidPhotoImport.release(appContext, path) }
    }

    override fun onDestroy() {
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
        sessionVaultChannel?.setMethodCallHandler(null)
        sessionVaultChannel = null
        photosBackgroundChannel?.setMethodCallHandler(null)
        photosBackgroundChannel = null
        discoveryChannel?.setMethodCallHandler(null)
        discoveryChannel = null
        photosChannel?.setMethodCallHandler(null)
        photosChannel = null
        exportChannel?.setMethodCallHandler(null)
        exportChannel = null

        pendingSaveResult?.let {
            try { it.success(null) } catch (_: Exception) { }
        }
        pendingSaveResult = null
        exportSource = null

        pendingBatchExportResult?.let {
            try { it.success(null) } catch (_: Exception) { }
        }
        pendingBatchExportResult = null
        exportBatchFiles = null

        photosPermissionPending?.let {
            try { it.success(false) } catch (_: Exception) { }
        }
        photosPermissionPending = null
        photosPermissionIncludesVideos = false

        nasDiscovery?.destroy()
        nasDiscovery = null

        val pending = photoPrepareRequests.values.toList()
        photoPrepareRequests.clear()
        if (pending.isNotEmpty()) {
            backgroundOperations.execute { pending.forEach { it.cancel() } }
        }

        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != photosPermissionRequest) return
        val result = photosPermissionPending ?: return
        photosPermissionPending = null
        result.success(canReadPhotos(photosPermissionIncludesVideos))
        photosPermissionIncludesVideos = false
    }

    @Deprecated("Used by the Flutter activity plugin dispatch contract")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        val appContext = applicationContext
        val activityRef = WeakReference(this)
        val handler = mainHandler

        if (requestCode == exportBatchRequest) {
            val result = pendingBatchExportResult ?: return
            val files = exportBatchFiles
            val tree = data?.data
            if (resultCode != Activity.RESULT_OK || tree == null || files == null) {
                pendingBatchExportResult = null
                exportBatchFiles = null
                result.success(null)
                return
            }
            try {
                ensureIoExecutor().execute {
                    val resolver = appContext.contentResolver
                    var copied = 0
                    try {
                        val parent = DocumentsContract.buildDocumentUriUsingTree(
                            tree,
                            DocumentsContract.getTreeDocumentId(tree),
                        )
                        for ((source, name) in files) {
                            val target = DocumentsContract.createDocument(
                                resolver,
                                parent,
                                "application/octet-stream",
                                name,
                            ) ?: throw java.io.IOException("Unable to create destination")
                            try {
                                resolver.openOutputStream(target, "w").use { output ->
                                    if (output == null) throw java.io.IOException("Missing output")
                                    source.inputStream().use { input -> input.copyTo(output, 256 * 1024) }
                                    output.flush()
                                }
                                copied++
                            } catch (error: Exception) {
                                try { DocumentsContract.deleteDocument(resolver, target) } catch (_: Exception) { }
                                throw error
                            }
                        }
                        handler.post {
                            val act = activityRef.get()
                            act?.pendingBatchExportResult = null
                            act?.exportBatchFiles = null
                            if (act != null && !act.isDestroyed) {
                                try { result.success("$copied/${files.size} 项已保存") } catch (_: Exception) { }
                            }
                        }
                    } catch (_: Exception) {
                        handler.post {
                            val act = activityRef.get()
                            act?.pendingBatchExportResult = null
                            act?.exportBatchFiles = null
                            if (act != null && !act.isDestroyed) {
                                try {
                                    result.error(
                                        "export_partial",
                                        "已保存 $copied/${files.size} 项，其他文件未能保存；已保存文件不会自动删除。请检查文件夹权限与剩余空间。",
                                        null,
                                    )
                                } catch (_: Exception) { }
                            }
                        }
                    }
                }
            } catch (_: RejectedExecutionException) {
                pendingBatchExportResult = null
                exportBatchFiles = null
                result.error("export_unavailable", "导出任务已取消。", null)
            }
            return
        }

        if (requestCode != exportRequest) return
        val result = pendingSaveResult ?: return
        val source = exportSource
        val destination = data?.data
        if (resultCode != Activity.RESULT_OK || destination == null || source == null) {
            pendingSaveResult = null
            exportSource = null
            result.success(null)
            return
        }
        try {
            ensureIoExecutor().execute {
                val resolver = appContext.contentResolver
                var failed = false
                try {
                    resolver.openOutputStream(destination, "w").use { output ->
                        if (output == null) throw java.io.IOException("Missing destination")
                        source.inputStream().use { input -> input.copyTo(output, 256 * 1024) }
                        output.flush()
                    }
                } catch (_: Exception) {
                    failed = true
                    try { DocumentsContract.deleteDocument(resolver, destination) } catch (_: Exception) { }
                }
                handler.post {
                    val act = activityRef.get()
                    act?.pendingSaveResult = null
                    act?.exportSource = null
                    if (act != null && !act.isDestroyed) {
                        try {
                            if (failed) result.error("export_failed", "导出失败，请检查目标位置与存储空间。", null)
                            else result.success(destination.toString())
                        } catch (_: Exception) { }
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            pendingSaveResult = null
            exportSource = null
            result.error("export_failed", "导出任务已取消。", null)
        }
    }
}
