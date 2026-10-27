package top.lengsu.lightisle

/** Immutable physical-disk binding for an encrypted WorkManager backup. */
internal data class BackgroundPhotoRoot(val id: String, val generation: Long, val photosPath: String) {
    init {
        require(id.matches(Regex("^[A-Za-z0-9_-]{1,128}$"))) { "Invalid NAS root identifier" }
        require(generation > 0) { "Invalid NAS disk generation" }
        require(photosPath.matches(Regex("^Users/u[1-9][0-9]*/photos$"))) {
            "Backup destination must be the assigned personal photos directory"
        }
    }

    fun endpoint(suffix: String): String {
        require(suffix.startsWith("/files") || suffix.startsWith("/uploads")) {
            "Unsupported backup API endpoint"
        }
        require(!suffix.contains("..") && !suffix.contains('\\') &&
            !suffix.contains('\r') && !suffix.contains('\n') && !suffix.startsWith("//")) {
            "Invalid backup API endpoint"
        }
        return "/api/v2/roots/$id$suffix"
    }

    fun deviceFolder(device: String): String {
        require(device.matches(Regex("^[a-f0-9]{24}$"))) { "Invalid backup device" }
        return "$photosPath/$device"
    }
}
