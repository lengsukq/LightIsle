package top.lengsu.lightisle

import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import java.io.IOException
import java.time.Instant
import java.time.ZoneId

/**
 * MediaStore album/bucket discovery, SQL bucket filtering, folder naming, and
 * typed URI resolution for Android 11+ MediaStore.createDeleteRequest.
 */
internal object AndroidPhotoAlbums {
    const val scopeCamera = "camera"
    const val scopeAll = "all"
    const val scopeSelected = "selected"
    const val scopeExcluded = "excluded"

    const val organizeFlat = "flat"
    const val organizeYearMonth = "yearMonth"
    const val organizeByAlbum = "byAlbum"
    const val organizeByAlbumYearMonth = "byAlbumYearMonth"

    private const val maxBucketFilterCount = 200
    private const val maxAlbumFolderNameLength = 64
    private const val defaultAlbumFolderName = "未分类相簿"
    private val bucketIdPattern = Regex("^-?[0-9]{1,20}$")
    private val controlCharsPattern = Regex("[\\x00-\\x1f\\x7f]")
    private val forbiddenPathCharsPattern = Regex("[/\\\\:*?\"<>|]")
    private val multiUnderscorePattern = Regex("_+")
    private val multiSpacePattern = Regex("\\s+")

    internal data class BucketSelection(
        val clause: String?,
        val args: List<String>,
    )

    private data class AlbumAccumulator(
        val id: String,
        val name: String,
        val relativePath: String,
        var count: Int,
        var totalBytes: Long,
        val coverAssetId: String,
        val isCamera: Boolean,
    )

    fun normalizeAlbumScope(raw: String?): String = when (raw) {
        scopeCamera -> scopeCamera
        scopeSelected -> scopeSelected
        scopeExcluded -> scopeExcluded
        else -> scopeAll
    }

    fun normalizeOrganizeMode(raw: String?, legacyByYearMonth: Boolean = false): String = when (raw) {
        organizeFlat -> organizeFlat
        organizeYearMonth -> organizeYearMonth
        organizeByAlbum -> organizeByAlbum
        organizeByAlbumYearMonth -> organizeByAlbumYearMonth
        else -> if (legacyByYearMonth) organizeYearMonth else organizeFlat
    }

    fun normalizeBucketIds(raw: Collection<String>?): List<String> {
        if (raw.isNullOrEmpty()) return emptyList()
        return raw.asSequence()
            .map { it.trim() }
            .filter { bucketIdPattern.matches(it) }
            .distinct()
            .sorted()
            .take(maxBucketFilterCount)
            .toList()
    }

    fun sanitizeAlbumFolderName(raw: String?): String {
        val cleaned = (raw ?: "")
            .replace(controlCharsPattern, " ")
            .replace(forbiddenPathCharsPattern, "_")
            .replace("..", "_")
            .replace(multiUnderscorePattern, "_")
            .replace(multiSpacePattern, " ")
            .trim()
            .trim('.')
            .trim()
        if (cleaned.isEmpty() || cleaned.all { it == '_' || it == '.' }) {
            return defaultAlbumFolderName
        }
        return cleaned.take(maxAlbumFolderNameLength)
    }

    fun isCameraLocation(relativePath: String?, bucketName: String?): Boolean {
        val normalizedPath = (relativePath ?: "").trim().trimStart('/').lowercase()
        if (normalizedPath == "dcim" || normalizedPath.startsWith("dcim/")) {
            return true
        }
        val normalizedName = (bucketName ?: "").trim().lowercase()
        return normalizedName == "camera" || normalizedName == "dcim"
    }

    fun buildBucketSelection(
        albumScope: String,
        bucketIds: List<String>,
        sdkInt: Int = Build.VERSION.SDK_INT,
    ): BucketSelection {
        val scope = normalizeAlbumScope(albumScope)
        val normalizedIds = normalizeBucketIds(bucketIds)
        return when (scope) {
            scopeAll -> BucketSelection(null, emptyList())
            scopeCamera -> buildCameraSelection(sdkInt)
            scopeSelected -> {
                if (normalizedIds.isEmpty()) {
                    BucketSelection("1 = 0", emptyList())
                } else {
                    val placeholders = normalizedIds.joinToString(",") { "?" }
                    BucketSelection(
                        "${MediaStore.MediaColumns.BUCKET_ID} IN ($placeholders)",
                        normalizedIds,
                    )
                }
            }
            scopeExcluded -> {
                if (normalizedIds.isEmpty()) {
                    BucketSelection(null, emptyList())
                } else {
                    val placeholders = normalizedIds.joinToString(",") { "?" }
                    BucketSelection(
                        "(${MediaStore.MediaColumns.BUCKET_ID} IS NULL OR " +
                            "${MediaStore.MediaColumns.BUCKET_ID} NOT IN ($placeholders))",
                        normalizedIds,
                    )
                }
            }
            else -> BucketSelection(null, emptyList())
        }
    }

    private fun buildCameraSelection(sdkInt: Int): BucketSelection {
        if (sdkInt >= 29) {
            return BucketSelection(
                clause = "(${MediaStore.MediaColumns.RELATIVE_PATH} LIKE ? OR " +
                    "${MediaStore.MediaColumns.RELATIVE_PATH} = ?) " +
                    "AND ${MediaStore.MediaColumns.RELATIVE_PATH} NOT LIKE ?",
                args = listOf("DCIM/%", "DCIM", "%/.%"),
            )
        }
        @Suppress("DEPRECATION")
        val dataColumn = MediaStore.MediaColumns.DATA
        return BucketSelection(
            clause = "$dataColumn LIKE ? AND $dataColumn NOT LIKE ?",
            args = listOf("%/DCIM/%", "%/.%"),
        )
    }

    fun resolveDestinationSubdir(
        deviceFolder: String,
        organizeMode: String,
        albumName: String?,
        modifiedEpoch: Long,
        zoneId: ZoneId = ZoneId.systemDefault(),
    ): String {
        val mode = normalizeOrganizeMode(organizeMode)
        val albumSegment = sanitizeAlbumFolderName(albumName)
        val yearMonth = formatYearMonth(modifiedEpoch, zoneId)
        return when (mode) {
            organizeFlat -> deviceFolder
            organizeYearMonth -> if (yearMonth != null) "$deviceFolder/$yearMonth" else deviceFolder
            organizeByAlbum -> "$deviceFolder/$albumSegment"
            organizeByAlbumYearMonth -> {
                val base = "$deviceFolder/$albumSegment"
                if (yearMonth != null) "$base/$yearMonth" else base
            }
            else -> deviceFolder
        }
    }

    private fun formatYearMonth(modifiedEpoch: Long, zoneId: ZoneId): String? {
        if (modifiedEpoch <= 0L) return null
        val epochSec = if (modifiedEpoch > 100_000_000_000L) modifiedEpoch / 1000L else modifiedEpoch
        val zdt = Instant.ofEpochSecond(epochSec).atZone(zoneId)
        return "%04d/%02d".format(zdt.year, zdt.monthValue)
    }

    fun listAlbums(context: Context, includeVideos: Boolean): List<Map<String, Any>> {
        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val projection = mutableListOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
        )
        val pathColumnName = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.MediaColumns.RELATIVE_PATH
        } else {
            @Suppress("DEPRECATION")
            MediaStore.MediaColumns.DATA
        }
        projection.add(pathColumnName)

        val kinds = if (includeVideos) {
            listOf(
                MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE,
                MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO,
            )
        } else {
            listOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE)
        }
        val selection = "(" + kinds.joinToString(" OR ") {
            "${MediaStore.Files.FileColumns.MEDIA_TYPE}=?"
        } + ") AND ${MediaStore.Files.FileColumns.SIZE} > 0"
        val args = kinds.map { it.toString() }.toTypedArray()

        val albums = LinkedHashMap<String, AlbumAccumulator>()
        resolver.query(
            collection,
            projection.toTypedArray(),
            selection,
            args,
            "${MediaStore.Files.FileColumns._ID} DESC",
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            val bucketIdCol = cursor.getColumnIndex(MediaStore.MediaColumns.BUCKET_ID)
            val bucketNameCol = cursor.getColumnIndex(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val pathCol = cursor.getColumnIndex(pathColumnName)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idCol)
                val size = cursor.getLong(sizeCol)
                if (id <= 0L || size <= 0L) continue
                val bucketId = if (bucketIdCol >= 0) cursor.getString(bucketIdCol)?.trim() else null
                if (bucketId.isNullOrEmpty() || !bucketIdPattern.matches(bucketId)) continue
                val rawName = if (bucketNameCol >= 0) cursor.getString(bucketNameCol)?.trim() else null
                val rawPath = if (pathCol >= 0) cursor.getString(pathCol) else null
                val relativePath = normalizeRelativeFolder(rawPath)
                val existing = albums[bucketId]
                if (existing != null) {
                    existing.count += 1
                    existing.totalBytes += size
                } else {
                    val displayName = rawName?.takeIf { it.isNotEmpty() }
                        ?: relativePath.trimEnd('/').substringAfterLast('/').takeIf { it.isNotEmpty() }
                        ?: defaultAlbumFolderName
                    albums[bucketId] = AlbumAccumulator(
                        id = bucketId,
                        name = displayName,
                        relativePath = relativePath,
                        count = 1,
                        totalBytes = size,
                        coverAssetId = id.toString(),
                        isCamera = isCameraLocation(relativePath, displayName),
                    )
                }
            }
        } ?: throw IOException("MediaStore could not be queried for albums")

        return albums.values
            .sortedWith(
                compareByDescending<AlbumAccumulator> { it.isCamera }
                    .thenByDescending { it.count }
                    .thenBy { it.name.lowercase() },
            )
            .map { album ->
                mapOf(
                    "id" to album.id,
                    "name" to album.name,
                    "relativePath" to album.relativePath,
                    "count" to album.count,
                    "totalBytes" to album.totalBytes,
                    "coverAssetId" to album.coverAssetId,
                    "isCamera" to album.isCamera,
                    "kind" to "bucket",
                )
            }
    }

    private fun normalizeRelativeFolder(rawPath: String?): String {
        if (rawPath.isNullOrBlank()) return ""
        val normalized = rawPath.replace('\\', '/').trim()
        if (Build.VERSION.SDK_INT >= 29) {
            return normalized.trimEnd('/')
        }
        val parent = normalized.substringBeforeLast('/', "")
        val marker = "/storage/emulated/0/"
        val index = parent.indexOf(marker)
        return if (index >= 0) parent.substring(index + marker.length) else parent
    }

    /**
     * Resolves verified MediaStore IDs to typed Image/Video content URIs required
     * by Android 11+ MediaStore.createDeleteRequest.
     */
    fun buildDeleteUris(context: Context, rawAssetIds: List<String>): List<Uri> {
        val ids = rawAssetIds.asSequence()
            .mapNotNull { it.trim().toLongOrNull() }
            .filter { it > 0L }
            .distinct()
            .toList()
        if (ids.isEmpty()) return emptyList()

        val resolver = context.contentResolver
        val collection = MediaStore.Files.getContentUri("external")
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
        )
        val uris = ArrayList<Uri>(ids.size)
        val batchSize = 100
        var offset = 0
        while (offset < ids.size) {
            val batch = ids.subList(offset, minOf(offset + batchSize, ids.size))
            offset += batch.size
            val placeholders = batch.joinToString(",") { "?" }
            val selection = "${MediaStore.Files.FileColumns._ID} IN ($placeholders)"
            val args = batch.map { it.toString() }.toTypedArray()
            resolver.query(collection, projection, selection, args, null)?.use { cursor ->
                val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                val typeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(idCol)
                    val base = when (cursor.getInt(typeCol)) {
                        MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE ->
                            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                        MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO ->
                            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                        else -> null
                    }
                    if (base != null) {
                        uris.add(ContentUris.withAppendedId(base, id))
                    }
                }
            }
        }
        return uris
    }
}
