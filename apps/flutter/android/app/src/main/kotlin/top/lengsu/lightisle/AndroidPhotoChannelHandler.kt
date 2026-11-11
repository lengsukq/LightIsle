package top.lengsu.lightisle

import android.content.Context
import android.os.CancellationSignal
import android.os.Handler
import android.os.OperationCanceledException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException

internal class AndroidPhotoChannelHandler(
    private val appContext: Context,
    private val activityRef: WeakReference<MainActivity>,
    private val mainHandler: Handler,
    private val backgroundOperations: ExecutorService,
    private val ioExecutorProvider: () -> ExecutorService,
    private val canReadPhotos: (Boolean) -> Boolean,
    private val requestPhotosPermission: (Boolean, MethodChannel.Result) -> Unit,
) {
    private val photoRequests = ConcurrentHashMap<String, CancellationSignal>()
    private var photosBackgroundChannel: MethodChannel? = null
    private var photosChannel: MethodChannel? = null

    fun attach(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        photosBackgroundChannel = MethodChannel(messenger, "lightisle/photos-background").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "status" -> runBackground(result, "background_status_failed", "无法读取系统后台任务状态。") {
                        BackgroundPhotoBackup.status(appContext)
                    }
                    "bindSession" -> {
                        val token = call.argument<String>("token") ?: ""
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        val username = call.argument<String>("username") ?: ""
                        runBackground(result, "background_session_bind_failed", "无法绑定当前登录会话。") {
                            BackgroundPhotoBackup.bindSession(appContext, token, server, cookie, username)
                        }
                    }
                    "endSession" -> {
                        val token = call.argument<String>("token") ?: ""
                        runBackground(result, "background_session_end_failed", "无法清理后台备份授权。") {
                            BackgroundPhotoBackup.endSession(appContext, token)
                        }
                    }
                    "forgetSession" -> runBackground(
                        result,
                        "background_session_end_failed",
                        "无法清理旧账号的后台备份授权，请重试。",
                    ) {
                        BackgroundPhotoBackup.forgetSession(appContext)
                    }
                    "disable" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        runBackground(result, "background_disable_failed", "无法取消后台任务，请重新尝试。") {
                            BackgroundPhotoBackup.disableForSession(appContext, server, cookie)
                        }
                    }
                    "enqueueScan" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        runBackground(
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
                        val albumScope = call.argument<String>("albumScope") ?: "all"
                        val organizeByYearMonth = call.argument<Boolean>("organizeByYearMonth") == true
                        runBackground(
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
                                albumScope,
                                organizeByYearMonth,
                            )
                        }
                    }
                    "updateOptions" -> {
                        val server = call.argument<String>("server") ?: ""
                        val cookie = call.argument<String>("cookie") ?: ""
                        val albumScope = call.argument<String>("albumScope") ?: "all"
                        val organizeByYearMonth = call.argument<Boolean>("organizeByYearMonth") == true
                        runBackground(
                            result,
                            "background_options_failed",
                            "无法同步后台备份偏好设置。",
                        ) {
                            BackgroundPhotoBackup.updateOptionsForSession(
                                appContext,
                                server,
                                cookie,
                                albumScope,
                                organizeByYearMonth,
                            )
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        photosChannel = MethodChannel(messenger, "lightisle/photos").also { channel ->
            channel.setMethodCallHandler { call, result ->
                val activity = activityRef.get()
                if (activity == null || activity.isFinishing || activity.isDestroyed) {
                    result.error("activity_unavailable", "当前界面已关闭。", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "permission" -> result.success(canReadPhotos(call.argument<Boolean>("includeVideos") == true))
                    "requestPermission" -> requestPhotosPermission(
                        call.argument<Boolean>("includeVideos") == true,
                        result,
                    )
                    "list" -> {
                        val includeVideos = call.argument<Boolean>("includeVideos") == true
                        if (!canReadPhotos(includeVideos)) {
                            result.error("photo_permission_required", "请先允许读取照片或视频。", null)
                        } else {
                            val cursor = call.argument<String>("beforeId")?.toLongOrNull()
                            val size = (call.argument<Int>("limit") ?: 80).coerceIn(1, 100)
                            val albumScope = call.argument<String>("albumScope") ?: "all"
                            val allowLarge = call.argument<Boolean>("allowLargeOriginals") == true
                            try {
                                ioExecutorProvider().execute {
                                    try {
                                        val listing = AndroidPhotoImport.list(
                                            appContext,
                                            cursor,
                                            size,
                                            includeVideos,
                                            albumScope,
                                            allowLarge,
                                        )
                                        postSuccess(result, listing)
                                    } catch (_: Exception) {
                                        postError(result, "photos_list_failed", "无法读取照片目录，请检查权限。")
                                    }
                                }
                            } catch (_: RejectedExecutionException) {
                                result.error("photos_list_failed", "照片目录读取任务已取消。", null)
                            }
                        }
                    }
                    "inspectAndHash" -> {
                        val includeVideos = call.argument<Boolean>("includeVideos") == true
                        if (!canReadPhotos(includeVideos)) {
                            result.error("photo_permission_required", "请先允许读取照片或视频。", null)
                        } else {
                            val id = call.argument<String>("id")?.toLongOrNull()
                            val requestId = call.argument<String>("requestId")
                            if (id == null || id <= 0) {
                                result.error("invalid_photo_id", "无效的照片编号。", null)
                            } else if (requestId == null || !isValidRequestId(requestId)) {
                                result.error("invalid_photo_request", "照片读取请求编号无效。", null)
                            } else {
                                runCancellableIo(
                                    requestId = requestId,
                                    result = result,
                                    cancelledCode = "photo_prepare_cancelled",
                                    cancelledMessage = "照片读取已取消。",
                                    failureCode = { error ->
                                        if (error is PhotoSourceChangedException) "photo_source_changed"
                                        else "photo_prepare_failed"
                                    },
                                    failureMessage = { error ->
                                        if (error is PhotoSourceChangedException) "照片在读取期间发生变化或不可用。"
                                        else "无法流式读取照片原件，请检查存储状态与权限。"
                                    },
                                ) { cancellation ->
                                    AndroidPhotoImport.inspectAndHash(appContext, id, cancellation)
                                }
                            }
                        }
                    }
                    "readChunk" -> {
                        val includeVideos = call.argument<Boolean>("includeVideos") == true
                        if (!canReadPhotos(includeVideos)) {
                            result.error("photo_permission_required", "请先允许读取照片或视频。", null)
                        } else {
                            val id = call.argument<String>("id")?.toLongOrNull()
                            val requestId = call.argument<String>("requestId")
                            val offset = call.argument<Number>("offset")?.toLong() ?: -1L
                            val length = call.argument<Number>("length")?.toInt() ?: -1
                            val expectedSize = call.argument<Number>("expectedSize")?.toLong() ?: -1L
                            val expectedModified = call.argument<Number>("expectedModified")?.toLong() ?: -1L
                            val expectedGeneration = call.argument<Number>("expectedGeneration")?.toLong() ?: 0L
                            if (id == null || id <= 0) {
                                result.error("invalid_photo_id", "无效的照片编号。", null)
                            } else if (requestId == null || !isValidRequestId(requestId)) {
                                result.error("invalid_photo_request", "照片读取请求编号无效。", null)
                            } else if (offset < 0L || length <= 0 || expectedSize <= 0L) {
                                result.error("invalid_chunk_range", "无效的分块读取范围。", null)
                            } else {
                                runCancellableIo(
                                    requestId = requestId,
                                    result = result,
                                    cancelledCode = "photo_prepare_cancelled",
                                    cancelledMessage = "照片分块读取已取消。",
                                    failureCode = { error ->
                                        if (error is PhotoSourceChangedException) "photo_source_changed"
                                        else "photo_chunk_failed"
                                    },
                                    failureMessage = { error ->
                                        if (error is PhotoSourceChangedException) "照片原件在上传期间发生变更。"
                                        else "读取照片上传数据块失败。"
                                    },
                                ) { cancellation ->
                                    AndroidPhotoImport.readChunk(
                                        appContext,
                                        id,
                                        offset,
                                        length,
                                        expectedSize,
                                        expectedModified,
                                        expectedGeneration,
                                        cancellation,
                                    )
                                }
                            }
                        }
                    }
                    "prepare" -> {
                        if (!canReadPhotos(call.argument<Boolean>("includeVideos") == true)) {
                            result.error("photo_permission_required", "请先允许读取照片或视频。", null)
                        } else {
                            val id = call.argument<String>("id")?.toLongOrNull()
                            val requestId = call.argument<String>("requestId")
                            if (id == null || id <= 0) {
                                result.error("invalid_photo_id", "无效的照片编号。", null)
                            } else if (requestId == null || !isValidRequestId(requestId)) {
                                result.error("invalid_photo_request", "照片读取请求编号无效。", null)
                            } else {
                                val cancellation = CancellationSignal()
                                if (photoRequests.putIfAbsent(requestId, cancellation) != null) {
                                    result.error("duplicate_photo_request", "照片读取请求编号重复。", null)
                                    return@setMethodCallHandler
                                }
                                try {
                                    ioExecutorProvider().execute {
                                        var preparedPath: String? = null
                                        var queued = false
                                        try {
                                            val prepared = AndroidPhotoImport.prepare(appContext, id, cancellation)
                                            preparedPath = prepared["path"] as? String
                                            if (cancellation.isCanceled) throw OperationCanceledException()
                                            mainHandler.post {
                                                try {
                                                    val act = activityRef.get()
                                                    if (cancellation.isCanceled || act == null || act.isFinishing || act.isDestroyed) {
                                                        releaseAsync(preparedPath)
                                                        try {
                                                            result.error("photo_prepare_cancelled", "照片读取已取消。", null)
                                                        } catch (_: Exception) { }
                                                    } else {
                                                        try {
                                                            result.success(prepared)
                                                        } catch (_: Exception) {
                                                            releaseAsync(preparedPath)
                                                        }
                                                    }
                                                } finally {
                                                    photoRequests.remove(requestId, cancellation)
                                                }
                                            }
                                            queued = true
                                        } catch (_: OperationCanceledException) {
                                            AndroidPhotoImport.release(appContext, preparedPath)
                                            postErrorAndRemove(result, requestId, cancellation, "photo_prepare_cancelled", "照片读取已取消。")
                                            queued = true
                                        } catch (_: Exception) {
                                            AndroidPhotoImport.release(appContext, preparedPath)
                                            postErrorAndRemove(
                                                result,
                                                requestId,
                                                cancellation,
                                                "photo_prepare_failed",
                                                "无法复制照片到上传临时区（可能空间不足或照片已变更）。",
                                            )
                                            queued = true
                                        } finally {
                                            if (!queued) photoRequests.remove(requestId, cancellation)
                                        }
                                    }
                                } catch (_: RejectedExecutionException) {
                                    photoRequests.remove(requestId, cancellation)
                                    result.error("photo_prepare_cancelled", "照片读取已取消。", null)
                                }
                            }
                        }
                    }
                    "cancelPrepare" -> {
                        val requestId = call.argument<String>("requestId")
                        if (requestId == null || !isValidRequestId(requestId)) {
                            result.error("invalid_photo_request", "照片读取请求编号无效。", null)
                        } else {
                            val signal = photoRequests[requestId]
                            if (signal != null) {
                                backgroundOperations.execute { signal.cancel() }
                            }
                            result.success(signal != null)
                        }
                    }
                    "release" -> result.success(AndroidPhotoImport.release(appContext, call.argument<String>("path")))
                    "isWifi" -> result.success(AndroidPhotoImport.isWifi(appContext))
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun detach() {
        photosBackgroundChannel?.setMethodCallHandler(null)
        photosBackgroundChannel = null
        photosChannel?.setMethodCallHandler(null)
        photosChannel = null
        val pending = photoRequests.values.toList()
        photoRequests.clear()
        if (pending.isNotEmpty()) {
            backgroundOperations.execute { pending.forEach { it.cancel() } }
        }
    }

    private fun isValidRequestId(requestId: String): Boolean =
        requestId.matches(Regex("^[A-Za-z0-9_-]{16,128}$"))

    private fun runCancellableIo(
        requestId: String,
        result: MethodChannel.Result,
        cancelledCode: String,
        cancelledMessage: String,
        failureCode: (Exception) -> String,
        failureMessage: (Exception) -> String,
        work: (CancellationSignal) -> Any,
    ) {
        val cancellation = CancellationSignal()
        if (photoRequests.putIfAbsent(requestId, cancellation) != null) {
            result.error("duplicate_photo_request", "照片读取请求编号重复。", null)
            return
        }
        try {
            ioExecutorProvider().execute {
                var queued = false
                try {
                    val output = work(cancellation)
                    if (cancellation.isCanceled) throw OperationCanceledException()
                    mainHandler.post {
                        try {
                            val act = activityRef.get()
                            if (cancellation.isCanceled || act == null || act.isFinishing || act.isDestroyed) {
                                try { result.error(cancelledCode, cancelledMessage, null) } catch (_: Exception) { }
                            } else {
                                try { result.success(output) } catch (_: Exception) { }
                            }
                        } finally {
                            photoRequests.remove(requestId, cancellation)
                        }
                    }
                    queued = true
                } catch (_: OperationCanceledException) {
                    postErrorAndRemove(result, requestId, cancellation, cancelledCode, cancelledMessage)
                    queued = true
                } catch (error: Exception) {
                    postErrorAndRemove(result, requestId, cancellation, failureCode(error), failureMessage(error))
                    queued = true
                } finally {
                    if (!queued) photoRequests.remove(requestId, cancellation)
                }
            }
        } catch (_: RejectedExecutionException) {
            photoRequests.remove(requestId, cancellation)
            result.error(cancelledCode, cancelledMessage, null)
        }
    }

    private fun runBackground(
        result: MethodChannel.Result,
        errorCode: String,
        errorMessage: String,
        operation: () -> Any,
    ) {
        backgroundOperations.execute {
            try {
                val value = operation()
                postSuccess(result, value)
            } catch (_: Exception) {
                postError(result, errorCode, errorMessage)
            }
        }
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        mainHandler.post {
            val act = activityRef.get()
            if (act != null && !act.isDestroyed) {
                try { result.success(value) } catch (_: Exception) { }
            }
        }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post {
            val act = activityRef.get()
            if (act != null && !act.isDestroyed) {
                try { result.error(code, message, null) } catch (_: Exception) { }
            }
        }
    }

    private fun postErrorAndRemove(
        result: MethodChannel.Result,
        requestId: String,
        cancellation: CancellationSignal,
        code: String,
        message: String,
    ) {
        mainHandler.post {
            try {
                val act = activityRef.get()
                if (act != null && !act.isDestroyed) {
                    result.error(code, message, null)
                }
            } catch (_: Exception) { } finally {
                photoRequests.remove(requestId, cancellation)
            }
        }
    }

    private fun releaseAsync(path: String?) {
        if (path == null) return
        backgroundOperations.execute { AndroidPhotoImport.release(appContext, path) }
    }
}
