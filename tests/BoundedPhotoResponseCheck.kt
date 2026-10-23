package top.lengsu.lightisle

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream

private class OldAPIStream(private val source: ByteArray, private val shortReads: Boolean = false) : InputStream() {
    var consumed = 0
    private var zeroNext = true
    override fun read(): Int = if (consumed == source.size) -1 else source[consumed++].toInt() and 255
    override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
        if (consumed == source.size) return -1
        if (shortReads && zeroNext) { zeroNext = false; return 0 }
        zeroNext = true
        val size = minOf(length, if (shortReads) 3 else source.size - consumed, source.size - consumed)
        source.copyInto(bytes, offset, consumed, consumed + size)
        consumed += size
        return size
    }
    override fun readNBytes(length: Int): ByteArray = error("API 33-only method must not be called")
}

fun main() {
    val maximum = 64 * 1024
    val original = ByteArray(maximum) { (it % 251).toByte() }
    check(readBoundedPhotoResponse(OldAPIStream(byteArrayOf())).isEmpty())
    check(readBoundedPhotoResponse(OldAPIStream(original)).contentEquals(original))
    check(readBoundedPhotoResponse(OldAPIStream(original, true)).contentEquals(original))
    val oversized = OldAPIStream(ByteArray(maximum * 4))
    try {
        readBoundedPhotoResponse(oversized)
        error("oversized response accepted")
    } catch (_: IOException) {
        check(oversized.consumed == maximum + 1)
    }
    val broken = object : InputStream() {
        override fun read(): Int = throw IOException("broken input")
    }
    try {
        readBoundedPhotoResponse(broken)
        error("read error was swallowed")
    } catch (error: IOException) {
        check(error.message == "broken input")
    }
    check(readBoundedPhotoResponse(ByteArrayInputStream(byteArrayOf(1, 2)), 2).contentEquals(byteArrayOf(1, 2)))
    println("PASS: Android-compatible bounded photo API responses, short reads, empty body, overflow and I/O errors")
}
