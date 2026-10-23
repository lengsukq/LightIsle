package top.lengsu.lightisle

private data class ScanPage(val itemCount: Int, val nextCursor: String)

private fun scanPages(pages: List<ScanPage>): Pair<Int, Int> {
    var index = 0
    var checked = 0
    var continuations = 0
    while (index < pages.size) {
        var pageCount = 0
        var visited = 0
        while (index < pages.size) {
            val page = pages[index++]
            pageCount++
            visited += page.itemCount
            checked += page.itemCount

            val checkpoint = BackgroundPhotoGeneration.checkpointAfterPage(
                nextCursor = page.nextCursor,
                pageSucceeded = true,
                generationCurrent = true,
                cancelled = false,
            ) ?: error("A successful current page must checkpoint")
            when (
                BackgroundPhotoGeneration.afterPage(
                    pages = pageCount,
                    visited = visited,
                    nextCursor = checkpoint,
                    generationCurrent = true,
                    cancelled = false,
                )
            ) {
                BackgroundPhotoGeneration.BatchDecision.FETCH_NEXT_PAGE -> Unit
                BackgroundPhotoGeneration.BatchDecision.ENQUEUE_CONTINUATION -> {
                    continuations++
                    break
                }
                BackgroundPhotoGeneration.BatchDecision.COMPLETE -> return checked to continuations
                BackgroundPhotoGeneration.BatchDecision.STOP -> error("Current scan stopped unexpectedly")
            }
        }
    }
    error("Test scan ended without a terminal page")
}

fun main() {
    val first = BackgroundPhotoGeneration.next(0)
    check(first == 1L)
    check(BackgroundPhotoGeneration.isCurrent(first, first))

    // A delayed worker from the old account may neither commit state nor
    // interpret a 401 as authority to disable the replacement account.
    val replacement = BackgroundPhotoGeneration.next(first)
    check(replacement == 2L)
    check(!BackgroundPhotoGeneration.isCurrent(first, replacement))
    check(BackgroundPhotoGeneration.isCurrent(replacement, replacement))

    // Cursor, MediaStore version, and upload sessions stay within one task
    // generation and cannot be consumed by a later login.
    val oldCursor = BackgroundPhotoGeneration.stateKey("cursor", first)
    val newCursor = BackgroundPhotoGeneration.stateKey("cursor", replacement)
    check(oldCursor == "cursor_1")
    check(newCursor == "cursor_2")
    check(oldCursor != newCursor)

    // A large first scan crosses the per-worker 30-photo limit, then resumes
    // through a metadata-only page before reaching its real terminal page.
    val (checked, continuations) = scanPages(
        listOf(
            ScanPage(10, "50"),
            ScanPage(10, "40"),
            ScanPage(10, "30"),
            ScanPage(0, "20"),
            ScanPage(1, ""),
        ),
    )
    check(checked == 31)
    check(continuations == 1)

    // Empty nextCursor is the only normal end condition. A page cap with a
    // cursor schedules the chain; a stale generation or cancellation cannot.
    check(
        BackgroundPhotoGeneration.afterPage(3, 30, "20", true, false) ==
            BackgroundPhotoGeneration.BatchDecision.ENQUEUE_CONTINUATION,
    )
    check(
        BackgroundPhotoGeneration.afterPage(1, 1, "", true, false) ==
            BackgroundPhotoGeneration.BatchDecision.COMPLETE,
    )
    check(
        BackgroundPhotoGeneration.afterPage(3, 30, "20", false, false) ==
            BackgroundPhotoGeneration.BatchDecision.STOP,
    )
    check(
        BackgroundPhotoGeneration.afterPage(3, 30, "20", true, true) ==
            BackgroundPhotoGeneration.BatchDecision.STOP,
    )

    // A failed or cancelled page keeps its prior durable cursor for retry;
    // only a completed page in the active generation may advance it.
    val durableCursor = "30"
    check(
        BackgroundPhotoGeneration.checkpointAfterPage(
            nextCursor = "20",
            pageSucceeded = false,
            generationCurrent = true,
            cancelled = false,
        ) == null,
    )
    check(
        BackgroundPhotoGeneration.checkpointAfterPage(
            nextCursor = "20",
            pageSucceeded = true,
            generationCurrent = true,
            cancelled = true,
        ) == null,
    )
    check(durableCursor == "30")
    check(
        BackgroundPhotoGeneration.checkpointAfterPage(
            nextCursor = "20",
            pageSucceeded = true,
            generationCurrent = true,
            cancelled = false,
        ) == "20",
    )

    check(runCatching { BackgroundPhotoGeneration.next(-1) }.isFailure)
    check(runCatching { BackgroundPhotoGeneration.stateKey("cursor", 0) }.isFailure)
    println("background photo generation checks passed")
}
