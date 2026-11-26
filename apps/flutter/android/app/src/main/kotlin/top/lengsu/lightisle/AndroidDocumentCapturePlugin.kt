package top.lengsu.lightisle

import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import kotlin.math.max
import kotlin.math.min

/**
 * Native document/receipt capture bridge (`lightisle/document-scanner`) for Android.
 *
 * Uses system camera (`ACTION_IMAGE_CAPTURE`) or system document picker
 * (`ACTION_OPEN_DOCUMENT`) with zero third-party SDKs, normalizes EXIF
 * orientation and downscales oversized photos into app-private cache JPEGs,
 * and returns canonical file paths to Flutter.
 */
internal class AndroidDocumentCapturePlugin(
    private val appContext: Context,
    private val activityRef: WeakReference<Activity>,
    private val mainHandler: Handler,
    private val ioExecutorProvider: () -> ExecutorService,
) {
    companion object {
        const val CHANNEL_NAME = "lightisle/document-scanner"
        const val CAPTURE_CAMERA_REQUEST_CODE = 22996
        const val PICK_DOCUMENT_REQUEST_CODE = 22997

        private const val MAX_PAGES = 10
        private const val MAX_EDGE_PX = 2400
        private const val JPEG_QUALITY = 88
        private const val CACHE_DIR_NAME = "lightisle-doc-scans"
        private const val STALE_CACHE_MS = 24L * 60L * 60L * 1000L
    }

    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingCameraUri: Uri? = null

    fun attach(flutterEngine: FlutterEngine) {
        detach()
        cleanupOldScans()
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME).also { ch ->
            ch.setMethodCallHandler(::onMethodCall)
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        clearPendingCameraEntry()
        pendingResult?.let { res ->
            try {
                res.success(mapOf("cancelled" to true, "paths" to emptyList<String>()))
            } catch (_: Exception) {
            }
        }
        pendingResult = null
    }

    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != CAPTURE_CAMERA_REQUEST_CODE && requestCode != PICK_DOCUMENT_REQUEST_CODE) {
            return false
        }
        val result = pendingResult ?: run {
            clearPendingCameraEntry()
            return true
        }
        pendingResult = null

        if (resultCode != Activity.RESULT_OK) {
            clearPendingCameraEntry()
            deliverSuccess(result, mapOf("cancelled" to true, "paths" to emptyList<String>()))
            return true
        }

        if (requestCode == CAPTURE_CAMERA_REQUEST_CODE) {
            handleCameraResult(data, result)
            return true
        }

        handlePickerResult(data, result)
        return true
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> {
                val hasCamera = appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
                result.success(
                    mapOf(
                        "scanner" to false,
                        "camera" to hasCamera,
                        "picker" to true,
                    ),
                )
            }
            "scanDocument" -> {
                val source = call.argument<String>("source")?.trim()?.lowercase() ?: "camera"
                startCapture(source, result)
            }
            else -> result.notImplemented()
        }
    }

    private fun startCapture(source: String, result: MethodChannel.Result) {
        val activity = activityRef.get()
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            result.error("scanner_unavailable", "当前界面已关闭，请返回重试。", null)
            return
        }
        if (pendingResult != null) {
            result.error("scanner_busy", "请先完成当前的票据拍摄或图片选择。", null)
            return
        }

        val preferCamera = source == "camera" || source == "scanner"
        if (preferCamera && launchCamera(activity, result)) {
            return
        }
        launchDocumentPicker(activity, result)
    }

    @Suppress("DEPRECATION")
    private fun launchCamera(activity: Activity, result: MethodChannel.Result): Boolean {
        if (!appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
            return false
        }
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
        if (intent.resolveActivity(appContext.packageManager) == null) {
            return false
        }

        var outputUri: Uri? = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            try {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, "lightisle_scan_${System.currentTimeMillis()}.jpg")
                    put(MediaStore.Images.Media.MIME_TYPE, "image/jpeg")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                outputUri = appContext.contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    values,
                )
                if (outputUri != null) {
                    intent.putExtra(MediaStore.EXTRA_OUTPUT, outputUri)
                    intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            } catch (_: Exception) {
                outputUri = null
            }
        }

        pendingResult = result
        pendingCameraUri = outputUri
        return try {
            activity.startActivityForResult(intent, CAPTURE_CAMERA_REQUEST_CODE)
            true
        } catch (_: Exception) {
            pendingResult = null
            clearPendingCameraEntry()
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun launchDocumentPicker(activity: Activity, result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        pendingResult = result
        try {
            activity.startActivityForResult(intent, PICK_DOCUMENT_REQUEST_CODE)
        } catch (_: Exception) {
            pendingResult = null
            result.error("scanner_unavailable", "无法打开系统图片选择器，请检查设备权限。", null)
        }
    }

    private fun handleCameraResult(data: Intent?, result: MethodChannel.Result) {
        val capturedUri = pendingCameraUri
        pendingCameraUri = null
        @Suppress("DEPRECATION")
        val fallbackBitmap = data?.extras?.get("data") as? Bitmap

        runOnIo(result) {
            try {
                val savedPath = when {
                    capturedUri != null -> normalizeUriToJpeg(capturedUri)
                    fallbackBitmap != null -> saveBitmapToJpeg(fallbackBitmap)
                    else -> null
                }
                if (capturedUri != null) {
                    try {
                        appContext.contentResolver.delete(capturedUri, null, null)
                    } catch (_: Exception) {
                    }
                }
                if (savedPath == null) {
                    deliverError(result, "capture_failed", "未能读取拍摄的照片，请重试或改用从相册选取。")
                } else {
                    deliverSuccess(
                        result,
                        mapOf(
                            "cancelled" to false,
                            "source" to "camera",
                            "paths" to listOf(savedPath),
                        ),
                    )
                }
            } catch (_: Exception) {
                if (capturedUri != null) {
                    try {
                        appContext.contentResolver.delete(capturedUri, null, null)
                    } catch (_: Exception) {
                    }
                }
                deliverError(result, "capture_failed", "处理拍摄照片失败，请检查存储空间后重试。")
            }
        }
    }

    private fun handlePickerResult(data: Intent?, result: MethodChannel.Result) {
        val uris = mutableListOf<Uri>()
        val clip = data?.clipData
        if (clip != null) {
            val count = min(clip.itemCount, MAX_PAGES)
            for (i in 0 until count) {
                clip.getItemAt(i)?.uri?.let { uris.add(it) }
            }
        } else {
            data?.data?.let { uris.add(it) }
        }

        if (uris.isEmpty()) {
            deliverSuccess(result, mapOf("cancelled" to true, "paths" to emptyList<String>()))
            return
        }

        runOnIo(result) {
            try {
                val paths = mutableListOf<String>()
                for (uri in uris) {
                    val path = normalizeUriToJpeg(uri)
                    if (path != null) {
                        paths.add(path)
                    }
                }
                if (paths.isEmpty()) {
                    deliverError(result, "capture_failed", "所选图片无法解码，请选择常见照片格式（JPG/PNG/HEIC）。")
                } else {
                    deliverSuccess(
                        result,
                        mapOf(
                            "cancelled" to false,
                            "source" to "picker",
                            "paths" to paths,
                        ),
                    )
                }
            } catch (_: Exception) {
                deliverError(result, "capture_failed", "读取所选图片失败，请重新选择后重试。")
            }
        }
    }

    private fun normalizeUriToJpeg(uri: Uri): String? {
        val scanDir = ensureScanDir()
        val rawTemp = File(scanDir, "raw_${UUID.randomUUID()}.tmp")
        try {
            appContext.contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(rawTemp).use { output ->
                    input.copyTo(output, 128 * 1024)
                    output.flush()
                }
            } ?: return null

            if (!rawTemp.isFile || rawTemp.length() <= 0L) return null

            val orientation = try {
                ExifInterface(rawTemp.absolutePath).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            } catch (_: Exception) {
                ExifInterface.ORIENTATION_NORMAL
            }

            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(rawTemp.absolutePath, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

            var sampleSize = 1
            val longest = max(bounds.outWidth, bounds.outHeight)
            while (longest / sampleSize > MAX_EDGE_PX * 2) {
                sampleSize *= 2
            }

            val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
            val decoded = BitmapFactory.decodeFile(rawTemp.absolutePath, decodeOpts) ?: return null
            val transformed = applyOrientationAndScale(decoded, orientation)
            if (transformed !== decoded) {
                decoded.recycle()
            }
            try {
                return saveBitmapToJpeg(transformed)
            } finally {
                transformed.recycle()
            }
        } finally {
            try {
                rawTemp.delete()
            } catch (_: Exception) {
            }
        }
    }

    private fun applyOrientationAndScale(bitmap: Bitmap, orientation: Int): Bitmap {
        val matrix = Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.postScale(-1f, 1f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.postScale(1f, -1f)
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.postRotate(90f)
                matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.postRotate(270f)
                matrix.postScale(-1f, 1f)
            }
        }
        val longest = max(bitmap.width, bitmap.height)
        if (longest > MAX_EDGE_PX) {
            val scale = MAX_EDGE_PX.toFloat() / longest.toFloat()
            matrix.postScale(scale, scale)
        }
        if (matrix.isIdentity) return bitmap
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    private fun saveBitmapToJpeg(bitmap: Bitmap): String {
        val outFile = File(ensureScanDir(), "doc_${System.currentTimeMillis()}_${UUID.randomUUID().toString().take(8)}.jpg")
        FileOutputStream(outFile).use { stream ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, stream)
            stream.flush()
        }
        return outFile.canonicalPath
    }

    private fun ensureScanDir(): File {
        val dir = File(appContext.cacheDir, CACHE_DIR_NAME)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    private fun cleanupOldScans() {
        val dir = File(appContext.cacheDir, CACHE_DIR_NAME)
        val files = dir.listFiles() ?: return
        val cutoff = System.currentTimeMillis() - STALE_CACHE_MS
        for (file in files) {
            if (file.isFile && file.lastModified() < cutoff) {
                try {
                    file.delete()
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun clearPendingCameraEntry() {
        val uri = pendingCameraUri ?: return
        pendingCameraUri = null
        try {
            appContext.contentResolver.delete(uri, null, null)
        } catch (_: Exception) {
        }
    }

    private fun runOnIo(result: MethodChannel.Result, block: () -> Unit) {
        try {
            ioExecutorProvider().execute(block)
        } catch (_: RejectedExecutionException) {
            deliverError(result, "scanner_unavailable", "扫描任务已取消，请重试。")
        }
    }

    private fun deliverSuccess(result: MethodChannel.Result, payload: Any?) {
        mainHandler.post {
            val act = activityRef.get()
            if (act != null && !act.isDestroyed) {
                try {
                    result.success(payload)
                } catch (_: Exception) {
                }
            }
        }
    }

    private fun deliverError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post {
            val act = activityRef.get()
            if (act != null && !act.isDestroyed) {
                try {
                    result.error(code, message, null)
                } catch (_: Exception) {
                }
            }
        }
    }
}
