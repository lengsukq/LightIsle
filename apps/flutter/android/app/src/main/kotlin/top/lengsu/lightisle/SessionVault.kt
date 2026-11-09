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
    private const val davAlias = "lightisle_dav_local_aes_v1"
    private const val davStore = "lightisle_dav_local"
    private const val davAad = "lightisle/dav-local-v1"
    private const val historyAlias = "lightisle_login_history_aes_v1"
    private const val historyStore = "lightisle_login_history"
    private const val historyAad = "lightisle/login-history-v1"
    private fun preferences(ctx: Context, name: String) = ctx.getSharedPreferences(name, Context.MODE_PRIVATE)
    private fun key(name: String, create: Boolean): SecretKey {
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keys.getKey(name, null) as? SecretKey)?.let { return it }
        check(create) { "Session key unavailable" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(name, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
            generateKey()
        }
    }
    private fun readSealed(ctx: Context, name: String, keyName: String, domain: String): String? {
        val stored = preferences(ctx, name).getString("sealed", null) ?: return null
        require(stored.length <= 12000) { "Invalid stored session" }
        val bytes = Base64.decode(stored, Base64.NO_WRAP)
        require(bytes.size in 28..8220) { "Invalid encrypted session" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(keyName, false), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(domain.toByteArray(Charsets.UTF_8))
        return String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
    }
    private fun writeSealed(ctx: Context, name: String, keyName: String, domain: String, value: String) {
        val plain = value.toByteArray(Charsets.UTF_8)
        require(plain.size <= 8192) { "Session too large" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(keyName, true))
        check(cipher.iv.size == 12)
        cipher.updateAAD(domain.toByteArray(Charsets.UTF_8))
        val sealed = Base64.encodeToString(cipher.iv + cipher.doFinal(plain), Base64.NO_WRAP)
        check(preferences(ctx, name).edit().putString("sealed", sealed).commit()) { "Cannot save session" }
    }
    private fun clearSealed(ctx: Context, name: String, keyName: String) {
        check(preferences(ctx, name).edit().remove("sealed").commit()) { "Cannot clear session" }
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(keyName) }
    }
    @Synchronized fun read(ctx: Context) = readSealed(ctx, store, alias, aad)
    @Synchronized fun write(ctx: Context, value: String) =
        writeSealed(ctx, store, alias, aad, value)
    @Synchronized fun clear(ctx: Context) = clearSealed(ctx, store, alias)
    @Synchronized fun readDav(ctx: Context) = readSealed(ctx, davStore, davAlias, davAad)
    @Synchronized fun writeDav(ctx: Context, value: String) =
        writeSealed(ctx, davStore, davAlias, davAad, value)
    @Synchronized fun clearDav(ctx: Context) = clearSealed(ctx, davStore, davAlias)
    @Synchronized fun readHistory(ctx: Context) = readSealed(ctx, historyStore, historyAlias, historyAad)
    @Synchronized fun writeHistory(ctx: Context, value: String) =
        writeSealed(ctx, historyStore, historyAlias, historyAad, value)
    @Synchronized fun clearHistory(ctx: Context) = clearSealed(ctx, historyStore, historyAlias)
}
