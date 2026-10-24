package top.lengsu.lightisle

/** Converts WorkManager snapshots into a small, user-facing state vocabulary. */
internal object BackgroundPhotoWorkStatePolicy {
    fun resolve(
        scanStates: () -> Collection<String>,
        triggerStates: () -> Collection<String>,
    ): String = try {
        val scan = scanStates()
        when {
            "RUNNING" in scan -> "running"
            "BLOCKED" in scan -> "blocked"
            "ENQUEUED" in scan -> "enqueued"
            else -> resolveTrigger(triggerStates())
        }
    } catch (error: InterruptedException) {
        Thread.currentThread().interrupt()
        "unknown"
    } catch (_: Exception) {
        "unknown"
    }

    private fun resolveTrigger(states: Collection<String>): String = when {
        "RUNNING" in states -> "trigger_running"
        "BLOCKED" in states -> "blocked"
        "ENQUEUED" in states -> "scheduled"
        else -> "none"
    }
}
