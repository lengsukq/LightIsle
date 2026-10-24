package top.lengsu.lightisle

import java.util.concurrent.TimeoutException

/** Plain JVM policy checks; intentionally uses no test framework dependency. */
fun main() {
    var triggerRead = false
    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { listOf("ENQUEUED", "BLOCKED", "RUNNING") },
            triggerStates = {
                triggerRead = true
                listOf("ENQUEUED")
            },
        ) == "running",
    )
    check(!triggerRead) { "active scan state must take priority without reading the trigger" }

    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { listOf("BLOCKED", "ENQUEUED") },
            triggerStates = { listOf("RUNNING") },
        ) == "blocked",
    )
    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { listOf("ENQUEUED") },
            triggerStates = { listOf("RUNNING") },
        ) == "enqueued",
    )
    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { listOf("SUCCEEDED", "FAILED") },
            triggerStates = { listOf("RUNNING", "ENQUEUED") },
        ) == "trigger_running",
    )
    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { emptyList() },
            triggerStates = { listOf("ENQUEUED") },
        ) == "scheduled",
    )
    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { emptyList() },
            triggerStates = { emptyList() },
        ) == "none",
    )
    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { throw TimeoutException("scan status timeout") },
            triggerStates = { emptyList() },
        ) == "unknown",
    )
    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { emptyList() },
            triggerStates = { throw TimeoutException("trigger status timeout") },
        ) == "unknown",
    )
    check(
        BackgroundPhotoWorkStatePolicy.resolve(
            scanStates = { throw IllegalStateException("WorkManager unavailable") },
            triggerStates = { emptyList() },
        ) == "unknown",
    )
}
