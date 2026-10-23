package top.lengsu.lightisle

import java.io.IOException
import java.io.InputStream

/** Uses the original InputStream API so photo backup also runs on API 24–32. */
internal fun readBoundedPhotoResponse(input: InputStream, maximum: Int = 64 * 1024): ByteArray {
    require(maximum in 1..64 * 1024)
    val bytes = ByteArray(maximum + 1)
    var size = 0
    while (size < bytes.size) {
        val count = input.read(bytes, size, bytes.size - size)
        if (count < 0) return bytes.copyOf(size)
        if (count == 0) {
            // A defensive fallback also handles unusual streams without
            // spinning forever or treating a temporary zero as end of input.
            val next = input.read()
            if (next < 0) return bytes.copyOf(size)
            bytes[size++] = next.toByte()
        } else {
            size += count
        }
    }
    throw IOException("Oversized NAS API response")
}
