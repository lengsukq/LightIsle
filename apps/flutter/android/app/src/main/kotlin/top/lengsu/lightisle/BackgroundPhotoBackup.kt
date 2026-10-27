package top.lengsu.lightisle

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import org.json.JSONObject
import java.net.InetAddress
import java.net.URI
import java.security.KeyStore
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.TimeoutException
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Background photo backups are opt-in. The session is encrypted with
 * AndroidKeyStore and is never placed in WorkManager input data. Every config
 * replacement advances a generation so an older Worker cannot write status,
 * resume state, or disable a newer account's schedule.
 */
internal object BackgroundPhotoBackup {
    const val workerGenerationKey = "backupGeneration"
    const val workerKindKey = "backupWorkKind"
    const val scanWorkerKind = "scan"

    // Cancel the old periodic BackgroundPhotoWorker on upgrade/rebind. It
    // remains able to act as a trigger until the user re-enables the schedule.
    private const val legacyWorkName = "lightisle-private-photo-backup"
    private const val triggerWorkName = "lightisle-private-photo-backup-trigger"
    private const val scanWorkName = "lightisle-private-photo-backup-scan"
    private const val store = "lightisle_background_photo_backup"
    private const val stateStore = "lightisle_background_photo_state"
    private const val alias = "lightisle_background_photo_cookie_aes_v1"
    private const val secret = "sealed"
    private const val generationKey = "generation"
    private const val ttlMillis = 7L * 24 * 60 * 60 * 1000
    private const val operationTimeoutSeconds = 15L
    private const val workStatusTimeoutMillis = 2_000L
    private val lock = Any()

    private data class ActiveSession(
        val token: String,
        val origin: String,
        val accountKey: String,
        val cookieDigest: String,
    )

    // In-memory only. WorkManager remains able to use its encrypted config
    // when Android starts the process with no foreground Flutter session.
    private var activeSession: ActiveSession? = null

    private fun preferences(ctx: Context) = ctx.getSharedPreferences(store, Context.MODE_PRIVATE)
    private fun statePreferences(ctx: Context) = ctx.getSharedPreferences(stateStore, Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    alias,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generateKey()
        }
    }

    private fun seal(payload: JSONObject): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        require(cipher.iv.size == 12) { "Unsupported Keystore IV" }
        val out = cipher.iv + cipher.doFinal(payload.toString().toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    private fun unseal(stored: String): JSONObject {
        val bytes = Base64.decode(stored, Base64.DEFAULT)
        if (bytes.size < 28) throw SecurityException("Encrypted backup secret is invalid")
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        return JSONObject(String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8))
    }

    private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    private fun privateHTTPHost(host: String): Boolean {
        // No DNS lookups for HTTP; this prevents DNS rebinding before cookies
        // are sent to a non-TLS endpoint.
        if (!host.matches(Regex("^[0-9.]+$")) && !host.contains(':')) return false
        return try {
            val address = InetAddress.getByName(host)
            address.isLoopbackAddress || address.isSiteLocalAddress || address.isLinkLocalAddress
        } catch (_: Exception) {
            false
        }
    }

    private fun normalizeOrigin(server: String): String {
        val parsed = URI(server.trim())
        if (parsed.host.isNullOrBlank() || parsed.userInfo != null ||
            parsed.rawQuery != null || parsed.rawFragment != null ||
            (parsed.rawPath != "" && parsed.rawPath != "/") ||
            parsed.scheme !in listOf("http", "https")
        ) {
            throw IllegalArgumentException("Only a valid NAS origin is supported")
        }
        if (parsed.scheme == "http" && !privateHTTPHost(parsed.host)) {
            throw IllegalArgumentException("Unencrypted background sessions require a numeric private/loopback address")
        }
        return parsed.normalize().toASCIIString().trimEnd('/')
    }

    private fun validate(server: String, cookie: String, pin: String, device: String): String {
        val origin = normalizeOrigin(server)
        if (pin.isNotEmpty() && (!pin.matches(Regex("^[0-9a-f]{64}$")) || !origin.startsWith("https://"))) {
            throw IllegalArgumentException("Invalid TLS leaf certificate SHA-256 fingerprint")
        }
        if (!cookie.matches(Regex("^lightisle_session=[A-Za-z0-9_\\-]{24,256}$"))) {
            throw IllegalArgumentException("Missing login session")
        }
        if (!device.matches(Regex("^[a-f0-9]{24}$"))) {
            throw IllegalArgumentException("Invalid device-scoped backup folder")
        }
        return origin
    }

    /** Bind UI channel operations to the currently signed-in Dart session. */
    fun bindSession(
        ctx: Context,
        token: String,
        server: String,
        cookie: String,
        username: String,
    ): Map<String, Any> = synchronized(lock) {
        require(runCatching { UUID.fromString(token) }.isSuccess) { "Invalid foreground session token" }
        val origin = normalizeOrigin(server)
        if (!cookie.matches(Regex("^lightisle_session=[A-Za-z0-9_\\-]{24,256}$"))) {
            throw IllegalArgumentException("Missing login session")
        }
        val accountName = username.trim()
        require(accountName.isNotEmpty() && accountName.length <= 160) { "Invalid account identity" }
        val accountKey = sha256("$origin\n${accountName.lowercase()}")
        val current = loadConfigLocked(ctx)
        if (current != null && current.optString("accountKey") != accountKey) {
            disableLocked(
                ctx,
                expectedGeneration = current.optLong("generation"),
                expectedAccountKey = current.optString("accountKey"),
                message = "账号或服务器已更换，旧后台任务已关闭",
            )
        }
        activeSession = ActiveSession(token, origin, accountKey, sha256(cookie))
        statusLocked(ctx)
    }

    /** End only the foreground account that initiated this request. */
    fun endSession(ctx: Context, token: String): Map<String, Any> = synchronized(lock) {
        val active = activeSession
        if (active != null && active.token == token) {
            val current = loadConfigLocked(ctx)
            if (current == null) {
                disableLocked(ctx, expectedGeneration = null, expectedAccountKey = null,
                    message = "已退出登录，后台备份已关闭")
            } else if (current.optString("accountKey") == active.accountKey) {
                disableLocked(
                    ctx,
                    expectedGeneration = current.optLong("generation"),
                    expectedAccountKey = active.accountKey,
                    message = "已退出登录，后台备份已关闭",
                )
            }
            activeSession = null
        }
        statusLocked(ctx)
    }

    fun enable(ctx: Context, server: String, cookie: String, pin: String, device: String,
               rootID: String, rootGeneration: Long, photosPath: String): Map<String, Any> =
        synchronized(lock) {
            val origin = validate(server, cookie, pin, device)
            val physicalRoot = BackgroundPhotoRoot(rootID, rootGeneration, photosPath)
            val permission = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES
            else Manifest.permission.READ_EXTERNAL_STORAGE
            if (ctx.checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                throw IllegalArgumentException("Complete photo permission is required")
            }
            val active = activeSession
                ?: throw SecurityException("No signed-in account is bound to background backup")
            if (active.origin != origin || active.cookieDigest != sha256(cookie)) {
                throw SecurityException("Background backup request belongs to a previous account session")
            }

            val prior = loadConfigLocked(ctx)
            val prefs = preferences(ctx)
            val generation = BackgroundPhotoGeneration.next(prefs.getLong(generationKey, 0L))
            val config = JSONObject()
                .put("server", origin)
                .put("cookie", cookie)
                .put("pin", pin)
                .put("device", device)
                .put("rootID", physicalRoot.id)
                .put("rootGeneration", physicalRoot.generation)
                .put("photosPath", physicalRoot.photosPath)
                .put("accountKey", active.accountKey)
                .put("generation", generation)
                .put("until", System.currentTimeMillis() + ttlMillis)
            if (!prefs.edit()
                    .putString(secret, seal(config))
                    .putLong(generationKey, generation)
                    .putString("last", "已开启 Wi-Fi 后台备份，等待系统调度")
                    .commit()
            ) {
                throw IllegalStateException("Could not store encrypted background session")
            }
            prior?.optLong("generation")?.takeIf { it > 0 }?.let { clearGenerationStateLocked(ctx, it) }

            val constraints = Constraints.Builder()
                .setRequiredNetworkType(NetworkType.UNMETERED)
                .setRequiresBatteryNotLow(true)
                .build()
            val periodic = PeriodicWorkRequestBuilder<BackgroundPhotoTriggerWorker>(6, TimeUnit.HOURS)
                .setConstraints(constraints)
                .setInputData(Data.Builder().putLong(workerGenerationKey, generation).build())
                .build()
            try {
                // Fence and cancel both generations before starting a new
                // serial scan chain and its periodic trigger.
                cancelWorkLocked(ctx)
                WorkManager.getInstance(ctx)
                    .enqueueUniquePeriodicWork(triggerWorkName, ExistingPeriodicWorkPolicy.UPDATE, periodic)
                    .result.get(operationTimeoutSeconds, TimeUnit.SECONDS)
                if (!enqueueScanLocked(ctx, generation, ExistingWorkPolicy.KEEP)) {
                    throw IllegalStateException("Could not enqueue initial photo scan")
                }
            } catch (error: Exception) {
                // The config generation has already advanced, so any prior
                // Worker is stale. Remove this config before returning failure.
                disableLocked(ctx, generation, active.accountKey, "无法安排后台任务，后台备份未开启")
                throw IllegalStateException("Could not enqueue background photo backup", error)
            }
            statusLocked(ctx)
        }

    /** Periodic and legacy work only trigger the one-time serial scan chain. */
    fun enqueueTriggeredScan(ctx: Context, expectedGeneration: Long): Boolean = synchronized(lock) {
        enqueueScanLocked(ctx, expectedGeneration, ExistingWorkPolicy.KEEP)
    }

    /** Queue the next bounded batch behind the currently running scan worker. */
    fun enqueueContinuation(ctx: Context, expectedGeneration: Long): Boolean = synchronized(lock) {
        enqueueScanLocked(ctx, expectedGeneration, ExistingWorkPolicy.APPEND_OR_REPLACE)
    }

    private fun enqueueScanLocked(
        ctx: Context,
        expectedGeneration: Long,
        policy: ExistingWorkPolicy,
    ): Boolean {
        if (!isGenerationCurrentLocked(ctx, expectedGeneration)) return false
        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.UNMETERED)
            .setRequiresBatteryNotLow(true)
            .build()
        val request = OneTimeWorkRequestBuilder<BackgroundPhotoWorker>()
            .setConstraints(constraints)
            .setInputData(
                Data.Builder()
                    .putLong(workerGenerationKey, expectedGeneration)
                    .putString(workerKindKey, scanWorkerKind)
                    .build(),
            )
            .build()
        return try {
            WorkManager.getInstance(ctx)
                .enqueueUniqueWork(scanWorkName, policy, request)
                .result.get(operationTimeoutSeconds, TimeUnit.SECONDS)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** User initiated disable; credentials must still be from the bound session. */
    fun disableForSession(ctx: Context, server: String, cookie: String): Map<String, Any> = synchronized(lock) {
        val origin = normalizeOrigin(server)
        val active = activeSession
            ?: throw SecurityException("No signed-in account is bound to background backup")
        if (active.origin != origin || active.cookieDigest != sha256(cookie)) {
            throw SecurityException("Background backup request belongs to a previous account session")
        }
        val current = loadConfigLocked(ctx)
        if (current == null) {
            disableLocked(ctx, null, null, "已关闭后台备份")
        } else if (current.optString("accountKey") == active.accountKey) {
            disableLocked(
                ctx,
                expectedGeneration = current.optLong("generation"),
                expectedAccountKey = active.accountKey,
                message = "已关闭后台备份",
            )
        }
        statusLocked(ctx)
    }

    /** Queue a scan only for the foreground session that owns the enabled config. */
    fun enqueueScanForSession(
        ctx: Context,
        server: String,
        cookie: String,
    ): Map<String, Any> = synchronized(lock) {
        val origin = normalizeOrigin(server)
        val active = activeSession
            ?: throw SecurityException("No signed-in account is bound to background backup")
        if (active.origin != origin || active.cookieDigest != sha256(cookie)) {
            throw SecurityException("Background backup request belongs to a previous account session")
        }

        val config = loadConfigLocked(ctx)
            ?: throw IllegalStateException("Background photo backup is not enabled")
        if (!configMatchesSession(config, active)) {
            throw SecurityException("Background backup is not bound to the current login session")
        }

        val generation = config.optLong("generation", 0L)
        if (generation <= 0L || !enqueueScanLocked(ctx, generation, ExistingWorkPolicy.KEEP)) {
            throw IllegalStateException("Could not enqueue background photo scan")
        }
        statusLocked(ctx) + ("scanRequestAccepted" to true)
    }

    /** Worker-side auth/permission failure; stale Workers are harmless no-ops. */
    fun disable(ctx: Context, expectedGeneration: Long, message: String): Boolean = synchronized(lock) {
        disableLocked(ctx, expectedGeneration, null, message)
    }

    fun load(ctx: Context): JSONObject? = synchronized(lock) { loadConfigLocked(ctx) }

    fun loadForWorker(ctx: Context, expectedGeneration: Long): JSONObject? = synchronized(lock) {
        if (!BackgroundPhotoGeneration.isCurrent(expectedGeneration, preferences(ctx).getLong(generationKey, 0L))) {
            return@synchronized null
        }
        val config = loadConfigLocked(ctx) ?: return@synchronized null
        if (config.optLong("generation", -1) != expectedGeneration) null else config
    }

    fun isGenerationCurrent(ctx: Context, expectedGeneration: Long): Boolean = synchronized(lock) {
        BackgroundPhotoGeneration.isCurrent(expectedGeneration, preferences(ctx).getLong(generationKey, 0L)) &&
            preferences(ctx).getString(secret, null) != null
    }

    fun cursor(ctx: Context, generation: Long): String =
        readState(ctx, "cursor", generation) ?: ""

    fun saveCursor(ctx: Context, generation: Long, value: String): Boolean =
        writeState(ctx, "cursor", generation, value)

    fun state(ctx: Context, name: String, generation: Long): String? = readState(ctx, name, generation)

    fun saveState(ctx: Context, name: String, generation: Long, value: String): Boolean =
        writeState(ctx, name, generation, value)

    fun removeState(ctx: Context, name: String, generation: Long): Boolean = synchronized(lock) {
        if (!isGenerationCurrentLocked(ctx, generation)) return@synchronized false
        statePreferences(ctx).edit().remove(BackgroundPhotoGeneration.stateKey(name, generation)).commit()
    }

    fun note(ctx: Context, expectedGeneration: Long, message: String): Boolean = synchronized(lock) {
        if (!isGenerationCurrentLocked(ctx, expectedGeneration)) return@synchronized false
        preferences(ctx).edit().putString("last", message.take(150)).commit()
    }

    fun status(ctx: Context): Map<String, Any> = synchronized(lock) { statusLocked(ctx) }

    private fun statusLocked(ctx: Context): Map<String, Any> {
        val config = loadConfigLocked(ctx)
        return mapOf(
            "enabled" to (config != null),
            "sessionMatches" to (
                config != null && activeSession?.let { configMatchesSession(config, it) } == true
            ),
            "last" to (preferences(ctx).getString("last", "未开始") ?: "未开始"),
            "expiresAt" to (config?.optLong("until", 0) ?: 0L),
            "workState" to if (config == null) "none" else workStateLocked(ctx),
        )
    }

    private fun workStateLocked(ctx: Context): String {
        val deadlineNanos = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(workStatusTimeoutMillis)
        fun states(name: String): Collection<String> {
            val future = WorkManager.getInstance(ctx).getWorkInfosForUniqueWork(name)
            val remainingNanos = deadlineNanos - System.nanoTime()
            if (remainingNanos <= 0L) throw TimeoutException()
            return future
                .get(remainingNanos, TimeUnit.NANOSECONDS)
                .map { it.state.name }
        }

        return BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { states(scanWorkName) },
            triggerStates = { states(triggerWorkName) },
        )
    }

    private fun configMatchesSession(config: JSONObject, active: ActiveSession): Boolean =
        config.optString("server") == active.origin &&
            config.optString("accountKey") == active.accountKey &&
            sha256(config.optString("cookie")) == active.cookieDigest

    private fun loadConfigLocked(ctx: Context): JSONObject? {
        val prefs = preferences(ctx)
        val sealed = prefs.getString(secret, null) ?: return null
        val config = try {
            unseal(sealed)
        } catch (_: Exception) {
            disableLocked(ctx, null, null, "后台授权信息损坏，已关闭备份")
            return null
        }
        val generation = config.optLong("generation", -1L)
        try {
            // Refuse old unscoped schedules. They may still point to a
            // completely different physical disk, even if account matches.
            BackgroundPhotoRoot(config.getString("rootID"),
                config.getLong("rootGeneration"), config.getString("photosPath"))
        } catch (_: Exception) {
            disableLocked(ctx, null, null, "旧版共享目录后台备份已停用，请重新选择照片硬盘并开启")
            return null
        }
        val storedGeneration = prefs.getLong(generationKey, 0L)
        if (!BackgroundPhotoGeneration.isCurrent(generation, storedGeneration) ||
            config.optString("accountKey").isBlank()
        ) {
            // Legacy/unbound configs are retired. They must be explicitly
            // enabled again after the foreground account has been established.
            disableLocked(ctx, null, null, "后台配置需要重新授权，请在应用内重新开启")
            return null
        }
        if (config.optLong("until", 0L) <= System.currentTimeMillis()) {
            disableLocked(ctx, generation, config.optString("accountKey"), "后台授权已到期，请重新开启")
            return null
        }
        return config
    }

    private fun disableLocked(
        ctx: Context,
        expectedGeneration: Long?,
        expectedAccountKey: String?,
        message: String,
    ): Boolean {
        val prefs = preferences(ctx)
        val sealed = prefs.getString(secret, null)
        val rawConfig = sealed?.let { runCatching { unseal(it) }.getOrNull() }
        val currentGeneration = prefs.getLong(generationKey, 0L)
        if (expectedGeneration != null &&
            (!BackgroundPhotoGeneration.isCurrent(expectedGeneration, currentGeneration) ||
                rawConfig?.optLong("generation", -1L) != expectedGeneration)
        ) return false
        if (expectedAccountKey != null && rawConfig?.optString("accountKey") != expectedAccountKey) return false

        val nextGeneration = BackgroundPhotoGeneration.next(currentGeneration)
        if (!prefs.edit()
                .remove(secret)
                .putLong(generationKey, nextGeneration)
                .putString("last", message.take(150))
                .commit()
        ) {
            throw IllegalStateException("Could not durably disable background photo backup")
        }
        rawConfig?.optLong("generation", -1L)?.takeIf { it > 0 }?.let { clearGenerationStateLocked(ctx, it) }
        clearLegacyStateLocked(ctx)
        try {
            cancelWorkLocked(ctx)
        } catch (error: Exception) {
            // The durable generation change already fences the old Worker.
            throw IllegalStateException("Could not cancel background photo work", error)
        }
        return true
    }

    private fun cancelWorkLocked(ctx: Context) {
        val manager = WorkManager.getInstance(ctx)
        listOf(legacyWorkName, triggerWorkName, scanWorkName).forEach { name ->
            manager.cancelUniqueWork(name).result.get(operationTimeoutSeconds, TimeUnit.SECONDS)
        }
    }

    private fun clearGenerationStateLocked(ctx: Context, generation: Long) {
        val prefs = statePreferences(ctx)
        val keys = prefs.all.keys.filter { key ->
            key == BackgroundPhotoGeneration.stateKey("cursor", generation) ||
                key == BackgroundPhotoGeneration.stateKey("mediastoreVersion", generation) ||
                key.startsWith("upload_${generation}_")
        }
        if (keys.isNotEmpty()) {
            val editor = prefs.edit()
            keys.forEach(editor::remove)
            editor.commit()
        }
    }

    private fun clearLegacyStateLocked(ctx: Context) {
        val prefs = statePreferences(ctx)
        val keys = prefs.all.keys.filter {
            it == "cursor" || it == "mediastoreVersion" || it.startsWith("upload_")
        }
        if (keys.isNotEmpty()) {
            val editor = prefs.edit()
            keys.forEach(editor::remove)
            editor.commit()
        }
    }

    private fun readState(ctx: Context, name: String, generation: Long): String? = synchronized(lock) {
        if (!isGenerationCurrentLocked(ctx, generation)) return@synchronized null
        statePreferences(ctx).getString(BackgroundPhotoGeneration.stateKey(name, generation), null)
    }

    private fun writeState(ctx: Context, name: String, generation: Long, value: String): Boolean = synchronized(lock) {
        if (!isGenerationCurrentLocked(ctx, generation)) return@synchronized false
        statePreferences(ctx).edit()
            .putString(BackgroundPhotoGeneration.stateKey(name, generation), value)
            .commit()
    }

    private fun isGenerationCurrentLocked(ctx: Context, generation: Long): Boolean =
        BackgroundPhotoGeneration.isCurrent(generation, preferences(ctx).getLong(generationKey, 0L)) &&
            preferences(ctx).getString(secret, null) != null
}
