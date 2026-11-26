package top.lengsu.lightisle

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.OperationCanceledException
import android.provider.DocumentsContract
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.InputStream
import java.lang.ref.WeakReference
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.min

internal class FolderSourceChangedException(message: String) : IOException(message)

/**
 * Self-contained Android SAF (`ACTION_OPEN_DOCUMENT_TREE` + `DocumentsContract`)
 * read-only folder backup plugin for channel `lightisle/android-folders`.
 *
 * Streams SHA-256 hashing and chunk reads directly from `ContentResolver`
 * without copying user files into app-private cache. Never modifies or deletes
 * any user files.
 */
internal class AndroidFolderBackupPlugin(
    private val appContext: Context,
    private val activityRef: WeakReference<Activity>,
    private val mainHandler: Handler,
    private val ioExecutorProvider: () -> ExecutorService,
) {
    companion object {
        const val CHANNEL_NAME = "lightisle/android-folders"
        const val PICK_DIRECTORY_REQUEST_CODE = 22995

        private const val MAX_STREAM_BYTES = 32L * 1024 * 1024 * 1024
        private const val CHUNK_DIGEST_THRESHOLD_BYTES = 2L * 1024 * 1024 * 1024
        private const val VERIFY_CHUNK_BYTES = 4 * 1024 * 1024
        private const val MAX_READ_CHUNK_BYTES = 8 * 1024 * 1024
        private const val STREAM_BUF_BYTES = 256 * 1024
        private const val MAX_DEPTH = 64
        private const val MAX_SCAN_ENTRIES = 100_000

        private val SYSTEM_JUNK = setOf(
            ".DS_Store", "Thumbs.db", "desktop.ini", ".Spotlight-V100",
            ".Trashes", ".fseventsd", ".TemporaryItems", "Icon\r",
        )
        private val REQUEST_ID_REGEX = Regex("^[A-Za-z0-9_-]{16,128}$")
    }

    private data class DocSnap(val size: Long, val modifiedMs: Long, val mime: String, val flags: Int)

    private var channel: MethodChannel? = null
    private var pendingPickResult: MethodChannel.Result? = null
    private val activeRequests = ConcurrentHashMap<String, CancellationSignal>()

    fun attach(flutterEngine: FlutterEngine) {
        detach()
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME).also { ch ->
            ch.setMethodCallHandler(::onMethodCall)
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        pendingPickResult?.let { try { it.success(null) } catch (_: Exception) { } }
        pendingPickResult = null
        val pending = activeRequests.values.toList()
        activeRequests.clear()
        pending.forEach { try { it.cancel() } catch (_: Exception) { } }
    }

    /** Returns `true` if [requestCode] was handled by this plugin. */
    fun handleActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_DIRECTORY_REQUEST_CODE) return false
        val result = pendingPickResult ?: return true
        pendingPickResult = null
        val treeUri = data?.data
        if (resultCode != Activity.RESULT_OK || treeUri == null) {
            try { result.success(null) } catch (_: Exception) { }
            return true
        }
        val takeFlags = (data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            .let { if (it == 0) Intent.FLAG_GRANT_READ_URI_PERMISSION else it }
        try {
            appContext.contentResolver.takePersistableUriPermission(treeUri, takeFlags)
        } catch (_: SecurityException) {
            try { result.error("folder_permission_persist_failed", "系统未授予持久读取权限，请重新选择受支持的本机文件夹。", null) } catch (_: Exception) { }
            return true
        }
        val (displayName, displayPath) = describeTreeUri(treeUri)
        try {
            result.success(mapOf("treeUri" to treeUri.toString(), "displayName" to displayName, "displayPath" to displayPath))
        } catch (_: Exception) { }
        return true
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) = when (call.method) {
        "pickDirectory" -> handlePickDirectory(result)
        "checkAccess" -> handleCheckAccess(call, result)
        "scanDirectory" -> handleScanDirectory(call, result)
        "statFile" -> handleStatFile(call, result)
        "hashFile" -> handleHashFile(call, result)
        "readChunk" -> handleReadChunk(call, result)
        "cancelRequest" -> handleCancelRequest(call, result)
        else -> result.notImplemented()
    }

    private fun handlePickDirectory(result: MethodChannel.Result) {
        val activity = activityRef.get()
        if (activity == null || activity.isFinishing || activity.isDestroyed) {
            result.error("activity_unavailable", "当前界面已关闭。", null)
            return
        }
        if (pendingPickResult != null) {
            result.error("folder_picker_busy", "请先完成当前文件夹选择。", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        pendingPickResult = result
        try {
            activity.startActivityForResult(intent, PICK_DIRECTORY_REQUEST_CODE)
        } catch (_: Exception) {
            pendingPickResult = null
            result.error("folder_picker_unavailable", "无法打开系统文件夹选择器。", null)
        }
    }

    private fun handleCheckAccess(call: MethodCall, result: MethodChannel.Result) {
        val rawTree = call.argument<String>("treeUri")?.trim().orEmpty()
        if (rawTree.isEmpty()) {
            result.error("invalid_tree_uri", "文件夹授权地址无效。", null)
            return
        }
        runIo(result, "folder_access_revoked", "Android 文件夹读取授权已失效，请编辑任务重新选择文件夹。") {
            val treeUri = parseAuthorizedTreeUri(rawTree)
            queryDocSnap(buildRootDocUri(treeUri)) ?: throw SecurityException("Tree root inaccessible")
            val (name, path) = describeTreeUri(treeUri)
            mapOf("accessible" to true, "displayName" to name, "displayPath" to path)
        }
    }

    private fun handleScanDirectory(call: MethodCall, result: MethodChannel.Result) {
        val rawTree = call.argument<String>("treeUri")?.trim().orEmpty()
        val ignoreHidden = call.argument<Boolean>("ignoreHidden") != false
        val ignorePatterns = call.argument<List<*>>("ignorePatterns")?.mapNotNull { it as? String } ?: emptyList()
        val maxBytes = call.argument<Number>("maxFileSizeBytes")?.toLong()?.coerceAtLeast(0L) ?: 0L
        val requestId = call.argument<String>("requestId").orEmpty()
        if (rawTree.isEmpty()) return result.error("invalid_tree_uri", "文件夹授权地址无效。", null)
        if (!REQUEST_ID_REGEX.matches(requestId)) return result.error("invalid_folder_request", "目录扫描请求编号无效。", null)
        runCancellableIo(
            requestId, result, "folder_scan_cancelled", "文件夹扫描已取消。",
            failureCode = { if (it is SecurityException) "folder_access_revoked" else "folder_scan_failed" },
            failureMessage = {
                if (it is SecurityException) "Android 文件夹读取授权已失效，请编辑任务重新选择文件夹。"
                else "扫描本机文件夹失败，请检查存储状态与权限。"
            },
        ) { cancel -> scanTree(parseAuthorizedTreeUri(rawTree), ignoreHidden, ignorePatterns, maxBytes, cancel) }
    }

    private fun handleStatFile(call: MethodCall, result: MethodChannel.Result) {
        val rawTree = call.argument<String>("treeUri")?.trim().orEmpty()
        val rawDoc = call.argument<String>("documentUri")?.trim().orEmpty()
        if (rawTree.isEmpty() || rawDoc.isEmpty()) return result.error("invalid_document_uri", "文件地址无效。", null)
        runIo(result, "folder_stat_failed", "无法读取文件信息。") {
            val treeUri = parseAuthorizedTreeUri(rawTree)
            val snap = queryDocSnap(parseScopedDocUri(treeUri, rawDoc))
            if (snap == null || !isRegularDoc(snap)) null
            else mapOf("size" to snap.size, "modifiedMs" to snap.modifiedMs)
        }
    }

    private fun handleHashFile(call: MethodCall, result: MethodChannel.Result) {
        val rawTree = call.argument<String>("treeUri")?.trim().orEmpty()
        val rawDoc = call.argument<String>("documentUri")?.trim().orEmpty()
        val expectedSize = call.argument<Number>("expectedSize")?.toLong() ?: -1L
        val expectedMod = call.argument<Number>("expectedModifiedMs")?.toLong() ?: -1L
        val requestId = call.argument<String>("requestId").orEmpty()
        if (rawTree.isEmpty() || rawDoc.isEmpty() || expectedSize < 0L) {
            return result.error("invalid_document_uri", "文件校验参数无效。", null)
        }
        if (!REQUEST_ID_REGEX.matches(requestId)) return result.error("invalid_folder_request", "文件校验请求编号无效。", null)
        runCancellableIo(
            requestId, result, "folder_hash_cancelled", "文件校验已取消。",
            failureCode = { mapIoErrorCode(it, "folder_hash_failed") },
            failureMessage = { mapIoErrorMsg(it, "本地文件在校验期间发生变化，请稍后重试。", "无法流式计算本地文件 SHA-256 摘要。") },
        ) { cancel ->
            val docUri = parseScopedDocUri(parseAuthorizedTreeUri(rawTree), rawDoc)
            streamHashDoc(docUri, expectedSize, expectedMod, cancel)
        }
    }

    private fun handleReadChunk(call: MethodCall, result: MethodChannel.Result) {
        val rawTree = call.argument<String>("treeUri")?.trim().orEmpty()
        val rawDoc = call.argument<String>("documentUri")?.trim().orEmpty()
        val offset = call.argument<Number>("offset")?.toLong() ?: -1L
        val length = call.argument<Number>("length")?.toInt() ?: -1
        val expectedSize = call.argument<Number>("expectedSize")?.toLong() ?: -1L
        val expectedMod = call.argument<Number>("expectedModifiedMs")?.toLong() ?: -1L
        val requestId = call.argument<String>("requestId").orEmpty()
        if (rawTree.isEmpty() || rawDoc.isEmpty()) return result.error("invalid_document_uri", "文件地址无效。", null)
        if (!REQUEST_ID_REGEX.matches(requestId)) return result.error("invalid_folder_request", "文件读取请求编号无效。", null)
        if (offset < 0L || length <= 0 || length > MAX_READ_CHUNK_BYTES || expectedSize <= 0L || offset + length > expectedSize) {
            return result.error("invalid_chunk_range", "无效的分片读取范围。", null)
        }
        runCancellableIo(
            requestId, result, "folder_chunk_cancelled", "文件分片读取已取消。",
            failureCode = { mapIoErrorCode(it, "folder_chunk_failed") },
            failureMessage = { mapIoErrorMsg(it, "本地文件在上传期间发生变化，请稍后重试。", "读取本地文件分片失败。") },
        ) { cancel ->
            val docUri = parseScopedDocUri(parseAuthorizedTreeUri(rawTree), rawDoc)
            readDocChunk(docUri, offset, length, expectedSize, expectedMod, cancel)
        }
    }

    private fun handleCancelRequest(call: MethodCall, result: MethodChannel.Result) {
        val requestId = call.argument<String>("requestId").orEmpty()
        if (!REQUEST_ID_REGEX.matches(requestId)) return result.error("invalid_folder_request", "请求编号无效。", null)
        val signal = activeRequests[requestId]
        signal?.cancel()
        result.success(signal != null)
    }

    private fun parseAuthorizedTreeUri(rawTree: String): Uri {
        val treeUri = Uri.parse(rawTree)
        if (treeUri.scheme != "content") throw SecurityException("Unsupported URI scheme")
        val granted = appContext.contentResolver.persistedUriPermissions.any { it.uri == treeUri && it.isReadPermission }
        if (!granted) throw SecurityException("Persisted read permission missing")
        return treeUri
    }

    private fun parseScopedDocUri(treeUri: Uri, rawDoc: String): Uri {
        val docUri = Uri.parse(rawDoc)
        if (docUri.scheme != "content" || docUri.authority != treeUri.authority) {
            throw SecurityException("Document URI authority mismatch")
        }
        if (DocumentsContract.getTreeDocumentId(treeUri) != DocumentsContract.getTreeDocumentId(docUri)) {
            throw SecurityException("Document URI outside authorized tree")
        }
        return docUri
    }

    private fun buildRootDocUri(treeUri: Uri): Uri =
        DocumentsContract.buildDocumentUriUsingTree(treeUri, DocumentsContract.getTreeDocumentId(treeUri))

    private fun describeTreeUri(treeUri: Uri): Pair<String, String> {
        val treeDocId = try { DocumentsContract.getTreeDocumentId(treeUri) } catch (_: Exception) { "" }
        val displayName = try {
            appContext.contentResolver.query(
                buildRootDocUri(treeUri),
                arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null,
            )?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null }
        } catch (_: Exception) { null }?.takeIf { it.isNotBlank() }
            ?: treeDocId.substringAfterLast('/').ifBlank { "已授权文件夹" }
        val pretty = when {
            treeDocId.startsWith("primary:") -> treeDocId.removePrefix("primary:").trim('/').let {
                if (it.isEmpty()) "内部存储" else "内部存储/$it"
            }
            treeDocId.contains(':') -> {
                val vol = treeDocId.substringBefore(':')
                val rel = treeDocId.substringAfter(':').trim('/')
                if (rel.isEmpty()) vol else "$vol/$rel"
            }
            else -> displayName
        }
        return Pair(displayName, pretty)
    }

    private fun queryDocSnap(docUri: Uri): DocSnap? {
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_FLAGS,
        )
        return appContext.contentResolver.query(docUri, cols, null, null, null)?.use { c ->
            if (!c.moveToFirst()) return null
            val sIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
            val mIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
            val tIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
            val fIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_FLAGS)
            DocSnap(
                size = if (sIdx >= 0 && !c.isNull(sIdx)) c.getLong(sIdx) else -1L,
                modifiedMs = if (mIdx >= 0 && !c.isNull(mIdx)) c.getLong(mIdx) else 0L,
                mime = if (tIdx >= 0 && !c.isNull(tIdx)) c.getString(tIdx) ?: "" else "",
                flags = if (fIdx >= 0 && !c.isNull(fIdx)) c.getInt(fIdx) else 0,
            )
        }
    }

    private fun isRegularDoc(snap: DocSnap): Boolean =
        snap.mime != DocumentsContract.Document.MIME_TYPE_DIR &&
            (snap.flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) == 0 &&
            snap.size in 0L..MAX_STREAM_BYTES

    private fun scanTree(
        treeUri: Uri,
        ignoreHidden: Boolean,
        ignorePatterns: List<String>,
        maxBytes: Long,
        cancellation: CancellationSignal,
    ): Map<String, Any> {
        val matcher = SafIgnoreMatcher(ignoreHidden, ignorePatterns)
        val rootDocId = DocumentsContract.getTreeDocumentId(treeUri)
        val visited = hashSetOf(rootDocId)
        val files = ArrayList<Map<String, Any>>()
        val failures = ArrayList<Map<String, Any>>()
        var skippedIgnored = 0
        var skippedOversized = 0
        var skippedVirtual = 0
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
            DocumentsContract.Document.COLUMN_FLAGS,
        )

        fun walk(parentId: String, prefix: String, depth: Int) {
            cancellation.throwIfCanceled()
            if (depth > MAX_DEPTH || files.size >= MAX_SCAN_ENTRIES) return
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            val cursor = try {
                appContext.contentResolver.query(childrenUri, cols, null, null, null, cancellation)
            } catch (err: OperationCanceledException) {
                throw err
            } catch (err: Exception) {
                failures.add(mapOf("relativePath" to prefix.ifEmpty { "." }, "reason" to "目录无法读取：${err.message ?: "权限不足"}"))
                return
            } ?: run {
                failures.add(mapOf("relativePath" to prefix.ifEmpty { "." }, "reason" to "目录无法读取，请检查系统文件夹授权。"))
                return
            }

            val subDirs = ArrayList<Pair<String, String>>()
            cursor.use { c ->
                val idIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val mimeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                val sizeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_SIZE)
                val modIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                val flagsIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_FLAGS)
                while (c.moveToNext()) {
                    cancellation.throwIfCanceled()
                    val docId = if (idIdx >= 0 && !c.isNull(idIdx)) c.getString(idIdx) else continue
                    val name = if (nameIdx >= 0 && !c.isNull(nameIdx)) c.getString(nameIdx) else continue
                    if (name.isEmpty() || name == "." || name == "..") continue
                    val mime = if (mimeIdx >= 0 && !c.isNull(mimeIdx)) c.getString(mimeIdx) ?: "" else ""
                    val size = if (sizeIdx >= 0 && !c.isNull(sizeIdx)) c.getLong(sizeIdx) else -1L
                    val modMs = if (modIdx >= 0 && !c.isNull(modIdx)) c.getLong(modIdx) else 0L
                    val flags = if (flagsIdx >= 0 && !c.isNull(flagsIdx)) c.getInt(flagsIdx) else 0
                    if ((flags and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT) != 0) {
                        skippedVirtual++
                        continue
                    }
                    val isDir = mime == DocumentsContract.Document.MIME_TYPE_DIR
                    val rel = if (prefix.isEmpty()) name else "$prefix/$name"
                    if (matcher.shouldIgnore(rel, isDir)) {
                        skippedIgnored++
                        continue
                    }
                    if (isDir) {
                        if (visited.add(docId)) subDirs.add(Pair(docId, rel))
                        continue
                    }
                    if (size < 0L || size > MAX_STREAM_BYTES) {
                        failures.add(mapOf("relativePath" to rel, "reason" to if (size > MAX_STREAM_BYTES) "单文件超过 32 GiB 限制" else "无法获取文件大小"))
                        continue
                    }
                    if (maxBytes > 0L && size > maxBytes) {
                        skippedOversized++
                        continue
                    }
                    if (files.size >= MAX_SCAN_ENTRIES) break
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                    files.add(
                        mapOf(
                            "documentId" to docId, "documentUri" to docUri.toString(),
                            "relativePath" to rel, "parentRelativeDir" to prefix,
                            "fileName" to name, "size" to size, "modifiedMs" to modMs,
                        ),
                    )
                }
            }
            subDirs.sortBy { it.second }
            for ((childId, childRel) in subDirs) walk(childId, childRel, depth + 1)
        }

        walk(rootDocId, "", 0)
        files.sortBy { it["relativePath"] as String }
        return mapOf(
            "files" to files, "failures" to failures,
            "skippedIgnored" to skippedIgnored, "skippedOversized" to skippedOversized,
            "skippedSymlinks" to skippedVirtual,
        )
    }

    private fun streamHashDoc(
        docUri: Uri,
        expectedSize: Long,
        expectedMod: Long,
        cancellation: CancellationSignal,
    ): Map<String, Any> {
        cancellation.throwIfCanceled()
        val before = queryDocSnap(docUri) ?: throw FolderSourceChangedException("Missing before hash")
        if (!isRegularDoc(before) || before.size != expectedSize || before.modifiedMs != expectedMod) {
            throw FolderSourceChangedException("Changed before hash")
        }
        val fullDigest = MessageDigest.getInstance("SHA-256")
        if (expectedSize == 0L) {
            if (queryDocSnap(docUri) != before) throw FolderSourceChangedException("Changed during empty hash")
            return mapOf("sha256" to fullDigest.digest().toHex(), "size" to 0L, "modifiedMs" to before.modifiedMs, "chunkDigests" to emptyList<String>())
        }
        val collectChunks = expectedSize > CHUNK_DIGEST_THRESHOLD_BYTES
        val chunks = if (collectChunks) ArrayList<String>() else emptyList<String>()
        var chunkDigest = MessageDigest.getInstance("SHA-256")
        var chunkBytes = 0
        var totalRead = 0L
        val activeInput = AtomicReference<InputStream?>()
        cancellation.setOnCancelListener { try { activeInput.get()?.close() } catch (_: Exception) { } }
        try {
            val stream = appContext.contentResolver.openInputStream(docUri) ?: throw IOException("Cannot open stream")
            stream.use { input ->
                activeInput.set(input)
                val buf = ByteArray(STREAM_BUF_BYTES)
                while (true) {
                    cancellation.throwIfCanceled()
                    val read = input.read(buf)
                    cancellation.throwIfCanceled()
                    if (read < 0) break
                    if (read == 0) continue
                    totalRead += read
                    if (totalRead > expectedSize || totalRead > MAX_STREAM_BYTES) {
                        throw FolderSourceChangedException("Document grew during hash")
                    }
                    fullDigest.update(buf, 0, read)
                    if (collectChunks && chunks is ArrayList<String>) {
                        var pos = 0
                        while (pos < read) {
                            val take = min(VERIFY_CHUNK_BYTES - chunkBytes, read - pos)
                            chunkDigest.update(buf, pos, take)
                            chunkBytes += take
                            pos += take
                            if (chunkBytes == VERIFY_CHUNK_BYTES) {
                                chunks.add(chunkDigest.digest().toHex())
                                chunkDigest = MessageDigest.getInstance("SHA-256")
                                chunkBytes = 0
                            }
                        }
                    }
                }
            }
            activeInput.set(null)
            cancellation.throwIfCanceled()
            if (totalRead != expectedSize) throw FolderSourceChangedException("Short hash read")
            if (collectChunks && chunkBytes > 0 && chunks is ArrayList<String>) chunks.add(chunkDigest.digest().toHex())
            if (queryDocSnap(docUri) != before) throw FolderSourceChangedException("Changed after hash")
            return mapOf("sha256" to fullDigest.digest().toHex(), "size" to totalRead, "modifiedMs" to before.modifiedMs, "chunkDigests" to chunks)
        } finally {
            activeInput.set(null)
            cancellation.setOnCancelListener(null)
        }
    }

    private fun readDocChunk(
        docUri: Uri,
        offset: Long,
        length: Int,
        expectedSize: Long,
        expectedMod: Long,
        cancellation: CancellationSignal,
    ): ByteArray {
        cancellation.throwIfCanceled()
        val before = queryDocSnap(docUri) ?: throw FolderSourceChangedException("Missing before chunk")
        if (!isRegularDoc(before) || before.size != expectedSize || before.modifiedMs != expectedMod) {
            throw FolderSourceChangedException("Changed before chunk")
        }
        val out = ByteArray(length)
        var filled = 0
        var fallbackStream = false
        try {
            appContext.contentResolver.openFileDescriptor(docUri, "r", cancellation)?.use { pfd ->
                while (filled < length) {
                    cancellation.throwIfCanceled()
                    try {
                        val n = Os.pread(pfd.fileDescriptor, out, filled, length - filled, offset + filled)
                        if (n <= 0) break
                        filled += n
                    } catch (errno: ErrnoException) {
                        if (errno.errno == OsConstants.EINTR) continue
                        if (errno.errno == OsConstants.ESPIPE || errno.errno == OsConstants.EINVAL) {
                            fallbackStream = true
                            break
                        }
                        throw IOException("pread failed", errno)
                    }
                }
            } ?: run { fallbackStream = true }
        } catch (_: UnsupportedOperationException) {
            fallbackStream = true
        }
        if (fallbackStream) {
            filled = readDocChunkViaStream(docUri, offset, length, out, cancellation)
        }
        cancellation.throwIfCanceled()
        if (filled != length) throw FolderSourceChangedException("Short chunk read")
        if (queryDocSnap(docUri) != before) throw FolderSourceChangedException("Changed after chunk")
        return out
    }

    private fun readDocChunkViaStream(
        docUri: Uri,
        offset: Long,
        length: Int,
        out: ByteArray,
        cancellation: CancellationSignal,
    ): Int {
        val activeInput = AtomicReference<InputStream?>()
        cancellation.setOnCancelListener { try { activeInput.get()?.close() } catch (_: Exception) { } }
        try {
            val stream = appContext.contentResolver.openInputStream(docUri) ?: throw IOException("Stream unavailable")
            stream.use { input ->
                activeInput.set(input)
                var remainingSkip = offset
                val skipBuf = ByteArray(STREAM_BUF_BYTES)
                while (remainingSkip > 0L) {
                    cancellation.throwIfCanceled()
                    val skipped = input.skip(remainingSkip)
                    if (skipped > 0L) {
                        remainingSkip -= skipped
                    } else {
                        val step = input.read(skipBuf, 0, min(skipBuf.size.toLong(), remainingSkip).toInt())
                        if (step < 0) break
                        remainingSkip -= step
                    }
                }
                if (remainingSkip != 0L) throw FolderSourceChangedException("Unable to reach chunk offset")
                var filled = 0
                while (filled < length) {
                    cancellation.throwIfCanceled()
                    val step = input.read(out, filled, length - filled)
                    if (step < 0) break
                    filled += step
                }
                return filled
            }
        } finally {
            activeInput.set(null)
            cancellation.setOnCancelListener(null)
        }
    }

    private fun mapIoErrorCode(err: Exception, fallback: String): String = when (err) {
        is FolderSourceChangedException -> "folder_source_changed"
        is SecurityException -> "folder_access_revoked"
        else -> fallback
    }

    private fun mapIoErrorMsg(err: Exception, changedMsg: String, fallback: String): String = when (err) {
        is FolderSourceChangedException -> changedMsg
        is SecurityException -> "Android 文件夹读取授权已失效，请编辑任务重新选择文件夹。"
        else -> fallback
    }

    private fun runIo(result: MethodChannel.Result, errCode: String, errMsg: String, work: () -> Any?) {
        try {
            ioExecutorProvider().execute {
                try {
                    val value = work()
                    mainHandler.post {
                        val act = activityRef.get()
                        if (act != null && !act.isDestroyed) try { result.success(value) } catch (_: Exception) { }
                    }
                } catch (_: Exception) {
                    mainHandler.post {
                        val act = activityRef.get()
                        if (act != null && !act.isDestroyed) try { result.error(errCode, errMsg, null) } catch (_: Exception) { }
                    }
                }
            }
        } catch (_: RejectedExecutionException) {
            result.error(errCode, errMsg, null)
        }
    }

    private fun runCancellableIo(
        requestId: String,
        result: MethodChannel.Result,
        cancelledCode: String,
        cancelledMsg: String,
        failureCode: (Exception) -> String,
        failureMessage: (Exception) -> String,
        work: (CancellationSignal) -> Any,
    ) {
        val cancellation = CancellationSignal()
        if (activeRequests.putIfAbsent(requestId, cancellation) != null) {
            return result.error("duplicate_folder_request", "文件夹读取请求编号重复。", null)
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
                                try { result.error(cancelledCode, cancelledMsg, null) } catch (_: Exception) { }
                            } else {
                                try { result.success(output) } catch (_: Exception) { }
                            }
                        } finally { activeRequests.remove(requestId, cancellation) }
                    }
                    queued = true
                } catch (_: OperationCanceledException) {
                    postErrorAndRemove(result, requestId, cancellation, cancelledCode, cancelledMsg)
                    queued = true
                } catch (err: Exception) {
                    postErrorAndRemove(result, requestId, cancellation, failureCode(err), failureMessage(err))
                    queued = true
                } finally {
                    if (!queued) activeRequests.remove(requestId, cancellation)
                }
            }
        } catch (_: RejectedExecutionException) {
            activeRequests.remove(requestId, cancellation)
            result.error(cancelledCode, cancelledMsg, null)
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
                if (act != null && !act.isDestroyed) result.error(code, message, null)
            } catch (_: Exception) { } finally { activeRequests.remove(requestId, cancellation) }
        }
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    private class SafIgnoreMatcher(private val ignoreHidden: Boolean, rawPatterns: List<String>) {
        private data class Rule(val anySeg: Boolean, val dirOnly: Boolean, val regex: Regex, val treePrefix: Regex?)

        private val rules: List<Rule> = rawPatterns.mapNotNull(::compileRule)

        fun shouldIgnore(relativePath: String, isDirectory: Boolean): Boolean {
            val norm = relativePath.replace('\\', '/').trim('/')
            if (norm.isEmpty()) return false
            val segs = norm.split('/')
            for (seg in segs) {
                if (seg.isEmpty() || seg == "." || seg == ".." || SYSTEM_JUNK.contains(seg) ||
                    seg.startsWith(".lightisle-") || (ignoreHidden && seg.startsWith("."))
                ) return true
            }
            return rules.any { matches(it, norm, segs, isDirectory) }
        }

        private fun matches(r: Rule, norm: String, segs: List<String>, isDir: Boolean): Boolean {
            if (r.anySeg) {
                val end = if (r.dirOnly && !isDir) segs.size - 1 else segs.size
                for (i in 0 until end) if (r.regex.matches(segs[i])) return true
                return false
            }
            if (r.treePrefix != null && isDir && r.treePrefix.matches(norm)) return true
            if (r.dirOnly) {
                if (isDir && r.regex.matches(norm)) return true
                for (i in 1 until segs.size) if (r.regex.matches(segs.subList(0, i).joinToString("/"))) return true
                return false
            }
            return r.regex.matches(norm)
        }

        private fun compileRule(raw: String): Rule? {
            var p = raw.trim().replace('\\', '/')
            if (p.isEmpty() || p.startsWith("#")) return null
            var anchored = false
            while (p.startsWith("/")) { anchored = true; p = p.substring(1) }
            var dirOnly = false
            while (p.endsWith("/")) { dirOnly = true; p = p.substring(0, p.length - 1) }
            if (p.isEmpty()) return null
            val treePrefix = if (p.endsWith("/**") && p.length > 3) compileGlob(p.substring(0, p.length - 3), false) else null
            val anySeg = !anchored && !p.contains('/')
            return Rule(anySeg, dirOnly, compileGlob(p, !anySeg && !p.endsWith("/**")), treePrefix)
        }

        private fun compileGlob(glob: String, allowSubtree: Boolean): Regex {
            val sb = StringBuilder("^")
            var i = 0
            while (i < glob.length) {
                when {
                    glob.startsWith("**/", i) -> { sb.append("(?:.+/)?"); i += 3 }
                    glob.startsWith("/**", i) && i + 3 == glob.length -> { sb.append("/.*"); i += 3 }
                    glob.startsWith("**", i) -> { sb.append(".*"); i += 2 }
                    glob[i] == '*' -> { sb.append("[^/]*"); i++ }
                    glob[i] == '?' -> { sb.append("[^/]"); i++ }
                    else -> { sb.append(Regex.escape(glob[i].toString())); i++ }
                }
            }
            if (allowSubtree) sb.append("(?:/.*)?")
            return Regex(sb.append("$").toString())
        }
    }
}
