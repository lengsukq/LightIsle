import Foundation

@main
struct StorageVolumeSelectionCheck {
    static func main() {
        let mounts = ["/", "/Volumes/Archive", "/Volumes/Archive 2", "/Volumes/Archive/Media"]
        precondition(StorageVolumeSelection.matchingMount(
            for: "/Volumes/Archive/Media/Film", mounts: mounts) == "/Volumes/Archive/Media")
        precondition(StorageVolumeSelection.matchingMount(
            for: "/Volumes/Archive 2/LightIsle", mounts: mounts) == "/Volumes/Archive 2")
        precondition(!StorageVolumeSelection.contains("/Volumes/Archive 2/Pictures", in: "/Volumes/Archive"))
        precondition(StorageVolumeSelection.matchingMount(for: "/Users/a/Documents", mounts: mounts) == "/")
        precondition(StorageVolumeSelection.matchingMount(
            for: "/Volumes/Detached/LightIsle", mounts: ["/", "/Volumes/Archive"]) == nil)
        precondition(StorageVolumeSelection.matchingMount(
            for: "/Volumes/Archive 22/LightIsle", mounts: mounts) == nil)
        precondition(StorageVolumeSelection.matchingMount(for: nil, mounts: mounts) == nil)
        precondition(StorageVolumeSelection.canChooseOnVolume(mount: "/Volumes/External SSD", readOnly: false))
        precondition(!StorageVolumeSelection.canChooseOnVolume(mount: "/Volumes/External SSD", readOnly: true))
        precondition(!StorageVolumeSelection.canChooseOnVolume(mount: "/", readOnly: false))
        precondition(!StorageVolumeSelection.canChooseOnVolume(mount: "/Volumes/", readOnly: false))
        precondition(!StorageVolumeSelection.canChooseOnVolume(mount: "/Volumes/Disk/Other", readOnly: false))
        precondition(!StorageVolumeSelection.canChooseOnVolume(mount: "/Volumes/../Users", readOnly: false))
        precondition(StorageVolumeSelection.canInspectExternalVolume(mount: "/Volumes/NTFS"))
        precondition(!StorageVolumeSelection.canInspectExternalVolume(mount: "/"))
        precondition(!StorageVolumeSelection.canInspectExternalVolume(mount: "/Volumes/External/Nested"))
        print("PASS: storage mount selection and path boundaries")
    }
}
