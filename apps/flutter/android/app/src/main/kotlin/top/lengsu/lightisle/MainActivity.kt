package top.lengsu.lightisle

import android.app.Activity
import android.content.Intent
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var exportResult: MethodChannel.Result? = null
    private var exportSource: File? = null
    private val exportRequest = 22991

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
