package top.lengsu.lightisle

import android.content.ContentResolver
import android.content.Context
import android.os.Build
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.content.ContentUris
import android.provider.MediaStore
import android.os.CancellationSignal
import java.io.InputStream
import java.io.File
import java.util.concurrent.atomic.AtomicReference

/**
 * Read-only MediaStore snapshot for explicit foreground photo backup.
 * This deliberately does not keep credentials, register a background service,
 * delete photos or bypass Android 14 partial-library consent.
 */
internal object AndroidPhotoImport {
    private const val maxTemporaryBytes = 2L * 1024 * 1024 * 1024
    private val collection = MediaStore.Images.Media.EXTERNAL_CONTENT_URI

    fun list(context: Context, beforeId: Long?, limit: Int): Map<String, Any> {
        val resolver: ContentResolver = context.contentResolver
        // A MediaStore generation can restart when Android rebuilds its
        // database. Pair generation numbers with the provider's opaque
        // version; absent version means the client must hash original bytes.
        val storeVersion = if (Build.VERSION.SDK_INT >= 30) {
            try { MediaStore.getVersion(context) } catch (_: Exception) { "" }
        } else ""
        val projection = mutableListOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.DATE_MODIFIED,
        )
        // On Android 11+ this counter changes even when a photo is replaced
        // by different bytes having the same size and second-level mtime.
        // Older Android versions conservatively recompute SHA-256 before a
        // local success entry may skip an original.
        if (Build.VERSION.SDK_INT >= 30) {
            projection.add(MediaStore.Images.Media.GENERATION_MODIFIED)
        }
        val selection = if (beforeId != null && beforeId > 0L) "${MediaStore.Images.Media._ID} < ?" else null
        val args = if (selection != null) arrayOf(beforeId.toString()) else null
        val results = ArrayList<Map<String, Any>>()
        var lastVisitedId: Long? = null
        var hasMore = false
        resolver.query(collection, projection.toTypedArray(), selection, args, "${MediaStore.Images.Media._ID} DESC")?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
            val timeColumn = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_MODIFIED)
            val generationColumn = if (Build.VERSION.SDK_INT >= 30)
                cursor.getColumnIndexOrThrow(MediaStore.Images.Media.GENERATION_MODIFIED) else -1
            // Do not walk tens of thousands of invalid/zero-byte rows on the
            // Activity thread. Progress by last *visited* ID, not last
            // accepted ID, so skipped metadata never causes an endless page.
            var visited = 0
            while (visited < limit * 4 && results.size < limit && cursor.moveToNext()) {
                visited++
                lastVisitedId = cursor.getLong(idColumn)
                val size = cursor.getLong(sizeColumn)
                val id = cursor.getLong(idColumn)
                if (id <= 0 || size <= 0 || size > maxTemporaryBytes) continue
                results.add(mapOf(
                    "id" to id.toString(),
                    "name" to (cursor.getString(nameColumn) ?: "photo"),
                    "size" to size,
                    "modified" to cursor.getLong(timeColumn),
                    "generation" to (if (generationColumn >= 0) cursor.getLong(generationColumn) else 0L)
                ))
            }
            hasMore = cursor.moveToNext()
        } ?: throw java.io.IOException("MediaStore could not be queried")
        val nextCursor = if (hasMore) lastVisitedId?.toString() ?: "" else ""
        return mapOf("items" to results, "nextCursor" to nextCursor, "version" to storeVersion)
    }

    fun prepare(context: Context, id: Long): Map<String, Any> =
        prepare(context, id, CancellationSignal())

    fun prepare(context: Context, id: Long, cancellation: CancellationSignal): Map<String, Any> {
        cancellation.throwIfCanceled()
        val dir = File(context.cacheDir, "lightisle-photo-backup")
        if (!dir.exists() && !dir.mkdirs()) throw java.io.IOException("No private cache")
        val expiry = System.currentTimeMillis() - 24L * 60 * 60 * 1000
        dir.listFiles()?.forEach { leftover ->
            if (leftover.isFile && leftover.name.startsWith("incoming-") &&
                leftover.name.endsWith(".tmp") && leftover.lastModified() < expiry) {
                leftover.delete()
            }
        }
        val file = File.createTempFile("incoming-", ".tmp", dir)
        val activeInput = AtomicReference<InputStream?>()
        cancellation.setOnCancelListener {
            try {
                activeInput.get()?.close()
            } catch (_: Exception) {
                // The read loop also checks the signal; closing the stream
                // here interrupts providers that block while producing bytes.
            }
        }
        try {
            val uri = ContentUris.withAppendedId(collection, id)
            var count = 0L
            val descriptor = context.contentResolver.openAssetFileDescriptor(uri, "r", cancellation)
                ?: throw java.io.IOException("Photo unavailable")
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
                            if (count > maxTemporaryBytes) throw java.io.IOException("Photo exceeds limit")
                            output.write(buffer, 0, bytes)
                        }
                        output.flush()
                    }
                }
            }
            activeInput.set(null)
            cancellation.throwIfCanceled()
            if (count == 0L) throw java.io.IOException("Empty photo")
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
}
