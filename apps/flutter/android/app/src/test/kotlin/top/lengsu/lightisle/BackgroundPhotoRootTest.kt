package top.lengsu.lightisle

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class BackgroundPhotoRootTest {
    private fun rejects(block: () -> Unit) {
        try {
            block()
            fail("Invalid physical root binding must not be accepted")
        } catch (_: IllegalArgumentException) { }
    }
    @Test fun `backup endpoints use only v2 and are physically generation-bound`() {
        val root = BackgroundPhotoRoot("disk_1", 12, "Users/u7/photos")
        assertEquals("/api/v2/roots/disk_1/uploads/abc/complete", root.endpoint("/uploads/abc/complete"))
        assertEquals("/api/v2/roots/disk_1/files/sha256?path=abc", root.endpoint("/files/sha256?path=abc"))
        assertEquals("Users/u7/photos/aabbccddeeff001122334455", root.deviceFolder("aabbccddeeff001122334455"))
    }

    @Test fun `rejects stale or forged destinations`() {
        rejects { BackgroundPhotoRoot("../escape", 1, "Users/u7/photos") }
        rejects { BackgroundPhotoRoot("disk", 0, "Users/u7/photos") }
        rejects { BackgroundPhotoRoot("disk", 1, "Users/u7/files") }
        rejects { BackgroundPhotoRoot("disk", 1, "Users/u7/photos/../../files") }
        rejects {
            BackgroundPhotoRoot("disk", 1, "Users/u7/photos").endpoint("/auth/login")
        }
    }
}
