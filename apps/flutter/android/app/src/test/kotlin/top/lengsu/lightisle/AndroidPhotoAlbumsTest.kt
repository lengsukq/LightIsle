package top.lengsu.lightisle

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset

class AndroidPhotoAlbumsTest {
    @Test
    fun `normalizes album scopes and organize modes with legacy migration`() {
        assertEquals("camera", AndroidPhotoAlbums.normalizeAlbumScope("camera"))
        assertEquals("selected", AndroidPhotoAlbums.normalizeAlbumScope("selected"))
        assertEquals("excluded", AndroidPhotoAlbums.normalizeAlbumScope("excluded"))
        assertEquals("all", AndroidPhotoAlbums.normalizeAlbumScope("unknown"))

        assertEquals("yearMonth", AndroidPhotoAlbums.normalizeOrganizeMode(null, legacyByYearMonth = true))
        assertEquals("flat", AndroidPhotoAlbums.normalizeOrganizeMode(null, legacyByYearMonth = false))
        assertEquals("byAlbum", AndroidPhotoAlbums.normalizeOrganizeMode("byAlbum", legacyByYearMonth = true))
        assertEquals(
            "byAlbumYearMonth",
            AndroidPhotoAlbums.normalizeOrganizeMode("byAlbumYearMonth", legacyByYearMonth = false),
        )
    }

    @Test
    fun `normalizes bucket ids deterministically and rejects invalid values`() {
        val ids = AndroidPhotoAlbums.normalizeBucketIds(
            listOf(" 202 ", "-1739773001", "202", "not-a-bucket", "../escape", ""),
        )
        assertEquals(listOf("-1739773001", "202"), ids)
    }

    @Test
    fun `sanitizes album folder names safely and resolves destination subdirs`() {
        assertEquals("_旅行_2026", AndroidPhotoAlbums.sanitizeAlbumFolderName("../旅行/2026"))
        assertEquals("未分类相簿", AndroidPhotoAlbums.sanitizeAlbumFolderName("   ...   "))
        assertTrue(AndroidPhotoAlbums.isCameraLocation("DCIM/Camera", "Camera"))
        assertFalse(AndroidPhotoAlbums.isCameraLocation("Pictures/Screenshots", "Screenshots"))

        val epochSec = 1784073600L // 2026-07-15T00:00:00Z
        assertEquals(
            "Users/u7/photos/dev1",
            AndroidPhotoAlbums.resolveDestinationSubdir(
                "Users/u7/photos/dev1",
                AndroidPhotoAlbums.organizeFlat,
                "Travel",
                epochSec,
                ZoneOffset.UTC,
            ),
        )
        assertEquals(
            "Users/u7/photos/dev1/2026/07",
            AndroidPhotoAlbums.resolveDestinationSubdir(
                "Users/u7/photos/dev1",
                AndroidPhotoAlbums.organizeYearMonth,
                "Travel",
                epochSec,
                ZoneOffset.UTC,
            ),
        )
        assertEquals(
            "Users/u7/photos/dev1/Travel",
            AndroidPhotoAlbums.resolveDestinationSubdir(
                "Users/u7/photos/dev1",
                AndroidPhotoAlbums.organizeByAlbum,
                "Travel",
                epochSec,
                ZoneOffset.UTC,
            ),
        )
        assertEquals(
            "Users/u7/photos/dev1/Travel/2026/07",
            AndroidPhotoAlbums.resolveDestinationSubdir(
                "Users/u7/photos/dev1",
                AndroidPhotoAlbums.organizeByAlbumYearMonth,
                "Travel",
                epochSec,
                ZoneOffset.UTC,
            ),
        )
    }
}
