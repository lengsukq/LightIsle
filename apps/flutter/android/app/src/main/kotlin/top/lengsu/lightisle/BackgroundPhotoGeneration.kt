package top.lengsu.lightisle

/** Small, platform-independent rules shared by the worker and persistence layer. */
internal object BackgroundPhotoGeneration {
    const val maxPagesPerBatch = 3
    const val maxPhotosPerBatch = 30

    enum class BatchDecision {
        FETCH_NEXT_PAGE,
        ENQUEUE_CONTINUATION,
        COMPLETE,
        STOP,
    }

    fun canContinueScan(pages: Int, visited: Int): Boolean =
        pages < maxPagesPerBatch && visited < maxPhotosPerBatch

    /** A cursor moves only after every item in its page has been handled. */
    fun checkpointAfterPage(
        nextCursor: String,
        pageSucceeded: Boolean,
        generationCurrent: Boolean,
        cancelled: Boolean,
    ): String? {
        if (!pageSucceeded || !generationCurrent || cancelled) return null
        return nextCursor
    }

    /** Decide whether a bounded unit fetches another page, chains, or stops. */
    fun afterPage(
        pages: Int,
        visited: Int,
        nextCursor: String,
        generationCurrent: Boolean,
        cancelled: Boolean,
    ): BatchDecision {
        if (!generationCurrent || cancelled) return BatchDecision.STOP
        if (nextCursor.isEmpty()) return BatchDecision.COMPLETE
        return if (canContinueScan(pages, visited)) {
            BatchDecision.FETCH_NEXT_PAGE
        } else {
            BatchDecision.ENQUEUE_CONTINUATION
        }
    }

    fun next(current: Long): Long {
        require(current >= 0) { "Invalid backup generation" }
        check(current < Long.MAX_VALUE) { "Backup generation exhausted" }
        return current + 1
    }

    fun isCurrent(expected: Long, current: Long): Boolean =
        expected > 0 && expected == current

    fun stateKey(name: String, generation: Long): String {
        require(generation > 0) { "Invalid backup generation" }
        require(name.matches(Regex("^[A-Za-z0-9_.-]{1,180}$"))) {
            "Invalid background backup state key"
        }
        return "${name}_$generation"
    }
}
