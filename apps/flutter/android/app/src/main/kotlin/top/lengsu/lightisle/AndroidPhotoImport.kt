package top.lengsu.lightisle

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.CancellationSignal
import android.provider.MediaStore
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.min

internal class PhotoSourceChangedException(message: String) : IOException(message)

/**
 * Read-only MediaStore access for foreground streaming photo/video backup and
 * legacy bounded WorkManager copies. Never modifies or deletes user assets.
 */
internal object AndroidPhotoImport {
    private const val maxTemporaryBytes = 2L * 1024 * 1024 * 1024
    private const val maxStreamBackupBytes = 32L * 1024 * 1024 * 1024
    private const val verificationChunkBytes = 4 * 1024 * 1024
    private const val maxReadChunkBytes = 8 * 1024 * 1024
    private val collection = MediaStore.Files.getContentUri("external")

    private data class AssetSnapshot(
        val size: Long,
        val modified: Long,
        val generation: Long,
    )

    fun normalizeAlbumScope(raw: String?): String =
        if (raw == "camera") "camera" else "all"

    fun list(
        context: Context,
        beforeId: Long?,
        limit: Int,
        includeVideos: Boolean = false,
        albumScope: String = "all",
        allowLargeOriginals: Boolean = false,
    ): Map<String, Any> {
        val resolver: ContentResolver = context.contentResolver
        val normalizedScope = normalizeAlbumScope(albumScope)
        val sizeLimit = if (allowLargeOriginals) maxStreamBackupBytes else maxTemporaryBytes
        val storeVersion = if (Build.VERSION.SDK_INT >= 30) {
            try { MediaStore.getVersion(context) } catch (_: Exception) { "" }
        } else ""
        val projection = mutableListOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
        )
        if (Build.VERSION.SDK_INT >= 30) {
            projection.add(MediaStore.Files.FileColumns.GENERATION_MODIFIED)
        }
        val kinds = if (includeVideos) {
            listOf(
                MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE,
                MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO,
            )
        } else {
            listOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE)
        }
        val selectionParts = mutableListOf(
            "(" + kinds.joinToString(" OR ") { "${MediaStore.Files.FileColumns.MEDIA_TYPE}=?" } + ")",
        )
        val argList = kinds.map { it.toString() }.toMutableList()
        if (beforeId != null && beforeId > 0L) {
            selectionParts.add("${MediaStore.Files.FileColumns._ID} < ?")
            argList.add(beforeId.toString())
        }
        if (normalizedScope == "camera") {
            if (Build.VERSION.SDK_INT >= 29) {
                selectionParts.add(
                    "(${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? OR ${MediaStore.MediaColumns.RELATIVE_PATH} = ?) " +
                        "AND ${MediaStore.MediaColumns.RELATIVE_PATH} NOT LIKE ?",
                )
                argList.add("DCIM/%")
                argList.add("DCIM")
                argList.add("%/.%")
            } else {
                @Suppress("DEPRECATION")
                val dataColumn = MediaStore.MediaColumns.DATA
                selectionParts.add("$dataColumn LIKE ? AND $dataColumn NOT LIKE ?")
                argList.add("%/DCIM/%")
                argList.add("%/.%")
            }
        }
        val selection = selectionParts.joinToString(" AND ")
        val args = argList.toTypedArray()
        val results = ArrayList<Map<String, Any>>()
        val omittedItems = ArrayList<Map<String, Any>>()
        var lastVisitedId: Long? = null
        var hasMore = false
        var oversizedCount = 0
        var invalidCount = 0
        resolver.query(
            collection,
            projection.toTypedArray(),
            selection,
            args,
            "${MediaStore.Files.FileColumns._ID} DESC",
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            val timeColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED)
            val generationColumn = if (Build.VERSION.SDK_INT >= 30) {
                cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.GENERATION_MODIFIED)
            } else {
                -1
            }
            var visited = 0
            while (visited < limit * 4 && results.size < limit && cursor.moveToNext()) {
                visited++
                lastVisitedId = cursor.getLong(idColumn)
                val size = cursor.getLong(sizeColumn)
                val id = cursor.getLong(idColumn)
                val generation = if (generationColumn >= 0) cursor.getLong(generationColumn) else 0L
                val name = cursor.getString(nameColumn) ?: "photo"
                val modified = cursor.getLong(timeColumn)
                if (id <= 0 || size <= 0) {
                    invalidCount++
                    if (id > 0) {
                        omittedItems.add(
                            mapOf(
                                "id" to id.toString(),
                                "name" to name,
                                "size" to size,
                                "modified" to modified,
                                "generation" to generation,
                                "reason" to "source_unavailable",
                            ),
                        )
                    }
                    continue
                }
                if (size > sizeLimit) {
                    oversizedCount++
                    omittedItems.add(
                        mapOf(
                            "id" to id.toString(),
                            "name" to name,
                            "size" to size,
                            "modified" to modified,
                            "generation" to generation,
                            "reason" to "oversized",
                        ),
                    )
                    continue
                }
                results.add(
                    mapOf(
                        "id" to id.toString(),
                        "name" to name,
                        "size" to size,
                        "modified" to modified,
                        "generation" to generation,
                    ),
                )
            }
            hasMore = cursor.moveToNext()
        } ?: throw IOException("MediaStore could not be queried")
        val nextCursor = if (hasMore) lastVisitedId?.toString() ?: "" else ""
        return mapOf(
            "items" to results,
            "nextCursor" to nextCursor,
            "version" to storeVersion,
            "oversizedCount" to oversizedCount,
            "invalidCount" to invalidCount,
            "omittedItems" to omittedItems,
            "supportsStream" to true,
        )
    }

    private fun querySnapshot(context: Context, id: Long): AssetSnapshot? {
        val projection = mutableListOf(
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_MODIFIED,
        )
        if (Build.VERSION.SDK_INT >= 30) {
            projection.add(MediaStore.Files.FileColumns.GENERATION_MODIFIED)
        }
        val uri = ContentUris.withAppendedId(collection, id)
        context.contentResolver.query(uri, projection.toTypedArray(), null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst()) return null
            val size = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE))
            val modified = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_MODIFIED))
            val generation = if (Build.VERSION.SDK_INT >= 30) {
                cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.GENERATION_MODIFIED))
            } else {
                0L
            }
            return AssetSnapshot(size = size, modified = modified, generation = generation)
        }
        return null
    }

    /**
     * Stream-hash an original asset without copying bytes to app cache.
     * Verifies MediaStore metadata before and after the read pass.
     */
    fun inspectAndHash(
        context: Context,
        id: Long,
        cancellation: CancellationSignal,
    ): Map<String, Any> {
        cancellation.throwIfCanceled()
        val before = querySnapshot(context, id) ?: throw IOException("Photo unavailable")
        if (before.size <= 0L || before.size > maxStreamBackupBytes) {
            throw PhotoSourceChangedException("Photo size invalid or exceeds 32 GiB")
        }
        val uri = ContentUris.withAppendedId(collection, id)
        val activeInput = AtomicReference<InputStream?>()
        cancellation.setOnCancelListener {
            try {
                activeInput.get()?.close()
            } catch (_: Exception) { }
        }
        try {
            val fullDigest = MessageDigest.getInstance("SHA-256")
            var chunkDigest = MessageDigest.getInstance("SHA-256")
            var chunkBytes = 0
            val collectChunks = before.size > maxTemporaryBytes
            val chunkDigests = if (collectChunks) ArrayList<String>() else emptyList<String>()
            var totalRead = 0L
            val descriptor = context.contentResolver.openAssetFileDescriptor(uri, "r", cancellation)
                ?: throw IOException("Photo unavailable")
            descriptor.use { asset ->
                asset.createInputStream().use { input ->
                    activeInput.set(input)
                    val buffer = ByteArray(256 * 1024)
                    while (true) {
                        cancellation.throwIfCanceled()
                        val read = input.read(buffer)
                        cancellation.throwIfCanceled()
                        if (read < 0) break
                        if (read == 0) continue
                        totalRead += read
                        if (totalRead > before.size || totalRead > maxStreamBackupBytes) {
                            throw PhotoSourceChangedException("Photo grew during streaming hash")
                        }
                        fullDigest.update(buffer, 0, read)
                        if (collectChunks && chunkDigests is ArrayList<String>) {
                            var offset = 0
                            while (offset < read) {
                                val take = min(verificationChunkBytes - chunkBytes, read - offset)
                                chunkDigest.update(buffer, offset, take)
                                chunkBytes += take
                                offset += take
                                if (chunkBytes == verificationChunkBytes) {
                                    chunkDigests.add(chunkDigest.digest().toHex())
                                    chunkDigest = MessageDigest.getInstance("SHA-256")
                                    chunkBytes = 0
                                }
                            }
                        }
                    }
                }
            }
            activeInput.set(null)
            cancellation.throwIfCanceled()
            if (totalRead != before.size) {
                throw PhotoSourceChangedException("Photo byte count changed during hash")
            }
            if (collectChunks && chunkBytes > 0 && chunkDigests is ArrayList<String>) {
                chunkDigests.add(chunkDigest.digest().toHex())
            }
            val after = querySnapshot(context, id)
                ?: throw PhotoSourceChangedException("Photo disappeared after hash")
            if (after != before) {
                throw PhotoSourceChangedException("Photo metadata changed during hash")
            }
            return mapOf(
                "size" to totalRead,
                "modified" to before.modified,
                "generation" to before.generation,
                "sha256" to fullDigest.digest().toHex(),
                "chunkDigests" to chunkDigests,
            )
        } finally {
            activeInput.set(null)
            cancellation.setOnCancelListener(null)
        }
    }

    /**
     * Read an exact byte range directly from MediaStore without staging files,
     * failing closed if the underlying asset changed since [inspectAndHash].
     */
    fun readChunk(
        context: Context,
        id: Long,
        offset: Long,
        length: Int,
        expectedSize: Long,
        expectedModified: Long,
        expectedGeneration: Long,
        cancellation: CancellationSignal,
    ): ByteArray {
        cancellation.throwIfCanceled()
        if (offset < 0L || length <= 0 || length > maxReadChunkBytes ||
            expectedSize <= 0L || offset + length > expectedSize
        ) {
            throw IllegalArgumentException("Invalid chunk range")
        }
        val expected = AssetSnapshot(expectedSize, expectedModified, expectedGeneration)
        val before = querySnapshot(context, id)
            ?: throw PhotoSourceChangedException("Photo unavailable before chunk read")
        if (before != expected) {
            throw PhotoSourceChangedException("Photo changed before chunk read")
        }
        val uri = ContentUris.withAppendedId(collection, id)
        val out = ByteArray(length)
        var filled = 0
        var seekUnsupported = false
        context.contentResolver.openFileDescriptor(uri, "r", cancellation)?.use { pfd ->
            while (filled < length) {
                cancellation.throwIfCanceled()
                try {
                    val count = Os.pread(
                        pfd.fileDescriptor,
                        out,
                        filled,
                        length - filled,
                        offset + filled,
                    )
                    if (count <= 0) break
                    filled += count
                } catch (errno: ErrnoException) {
                    if (errno.errno == OsConstants.EINTR) continue
                    if (errno.errno == OsConstants.ESPIPE || errno.errno == OsConstants.EINVAL) {
                        seekUnsupported = true
                        break
                    }
                    throw IOException("Failed to read photo chunk", errno)
                }
            }
        } ?: run { seekUnsupported = true }

        if (seekUnsupported) {
            filled = 0
            context.contentResolver.openAssetFileDescriptor(uri, "r", cancellation)?.use { afd ->
                afd.createInputStream().use { input ->
                    var remainingSkip = offset
                    val skipBuffer = ByteArray(256 * 1024)
                    while (remainingSkip > 0) {
                        cancellation.throwIfCanceled()
                        val skipped = input.skip(remainingSkip)
                        if (skipped > 0) {
                            remainingSkip -= skipped
                        } else {
                            val step = input.read(skipBuffer, 0, min(skipBuffer.size.toLong(), remainingSkip).toInt())
                            if (step < 0) break
                            remainingSkip -= step
                        }
                    }
                    if (remainingSkip != 0L) {
                        throw PhotoSourceChangedException("Could not reach chunk offset")
                    }
                    while (filled < length) {
                        cancellation.throwIfCanceled()
                        val step = input.read(out, filled, length - filled)
                        if (step < 0) break
                        filled += step
                    }
                }
            } ?: throw IOException("Photo descriptor unavailable")
        }

        cancellation.throwIfCanceled()
        if (filled != length) {
            throw PhotoSourceChangedException("Short photo chunk read")
        }
        val after = querySnapshot(context, id)
            ?: throw PhotoSourceChangedException("Photo unavailable after chunk read")
        if (after != expected) {
            throw PhotoSourceChangedException("Photo changed during chunk read")
        }
        return out
    }

    fun prepare(context: Context, id: Long): Map<String, Any> =
        prepare(context, id, CancellationSignal())

    fun prepare(context: Context, id: Long, cancellation: CancellationSignal): Map<String, Any> {
        cancellation.throwIfCanceled()
        val dir = File(context.cacheDir, "lightisle-photo-backup")
        if (!dir.exists() && !dir.mkdirs()) throw IOException("No private cache")
        val expiry = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        dir.listFiles()?.forEach { leftover ->
            if (leftover.isFile && leftover.name.startsWith("incoming-") &&
                leftover.name.endsWith(".tmp") && leftover.lastModified() < expiry
            ) {
                leftover.delete()
            }
        }
        val file = File.createTempFile("incoming-", ".tmp", dir)
        val activeInput = AtomicReference<InputStream?>()
        cancellation.setOnCancelListener {
            try {
                activeInput.get()?.close()
            } catch (_: Exception) { }
        }
        try {
            val uri = ContentUris.withAppendedId(collection, id)
            var count = 0L
            val descriptor = context.contentResolver.openAssetFileDescriptor(uri, "r", cancellation)
                ?: throw IOException("Photo unavailable")
            descriptor.use { asset ->
                asset.createInputStream().use { input ->
                    activeInput.set(input)
                    cancellation.throwIfCanceled()
                    file.outputStream().use { output ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            cancellation.throwIfCanceled()
                            val bytes = input.read(buffer)
                            cancellation.throwIfCanceled()
                            if (bytes < 0) break
                            count += bytes
                            if (count > maxTemporaryBytes) throw IOException("Photo exceeds limit")
                            output.write(buffer, 0, bytes)
                        }
                        output.flush()
                    }
                }
            }
            activeInput.set(null)
            cancellation.throwIfCanceled()
            if (count == 0L) throw IOException("Empty photo")
            return mapOf("path" to file.canonicalPath, "size" to count)
        } catch (e: Exception) {
            file.delete()
            throw e
        } finally {
            activeInput.set(null)
            cancellation.setOnCancelListener(null)
        }
    }

    fun release(context: Context, path: String?): Boolean {
        if (path.isNullOrEmpty()) return false
        return try {
            val root = File(context.cacheDir, "lightisle-photo-backup").canonicalPath + File.separator
            val file = File(path).canonicalFile
            file.isFile && file.path.startsWith(root) && file.delete()
        } catch (_: Exception) { false }
    }

    fun isWifi(context: Context): Boolean {
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = connectivity.activeNetwork ?: return false
        return connectivity.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }
}
