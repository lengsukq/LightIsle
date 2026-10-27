package top.lengsu.lightisle

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The key never leaves Android Keystore; preferences contain ciphertext only. */
internal object SessionVault {
    private const val alias = "lightisle_login_session_aes_v1"
    private const val store = "lightisle_login_session"
    private const val aad = "lightisle/session-vault/v1"
    private fun preferences(ctx: Context) = ctx.getSharedPreferences(store, Context.MODE_PRIVATE)
    private fun key(create: Boolean): SecretKey {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keys.getKey(alias, null) as? SecretKey)?.let { return it }
        check(create) { "Session key unavailable" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            generateKey()
        }
    }
    @Synchronized fun read(ctx: Context): String? {
        val stored = preferences(ctx).getString("sealed", null) ?: return null
        require(stored.length <= 12000) { "Invalid stored session" }
        val bytes = Base64.decode(stored, Base64.NO_WRAP)
        require(bytes.size in 28..8220) { "Invalid encrypted session" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(false), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        return String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
    }
    @Synchronized fun write(ctx: Context, value: String) {
        val plain = value.toByteArray(Charsets.UTF_8)
        require(plain.size <= 8192) { "Session too large" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(true))
        check(cipher.iv.size == 12)
        cipher.updateAAD(aad.toByteArray(Charsets.UTF_8))
        val sealed = Base64.encodeToString(cipher.iv + cipher.doFinal(plain), Base64.NO_WRAP)
        check(preferences(ctx).edit().putString("sealed", sealed).commit()) { "Cannot save session" }
    }
    @Synchronized fun clear(ctx: Context) {
        check(preferences(ctx).edit().remove("sealed").commit()) { "Cannot clear session" }
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(alias) }
    }
}
