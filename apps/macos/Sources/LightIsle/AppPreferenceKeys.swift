import Foundation

/// Single source of truth for macOS `UserDefaults` / `@AppStorage` keys used across
/// `AppModel`, `ContentView`, `DockerManagementView`, and volume coordinators.
enum AppPreferenceKeys {
    static let hasSeenIntro = "hasSeenIntro"
    static let keepAwakeWhileServing = "lightisle.keepAwakeWhileServing"
    static let nativeAlertsEnabled = "lightisle.nativeAlertsEnabled"
    static let localPort = "lightisle.localPort"
    static let thumbnailCacheMiB = "lightisle.thumbnailCacheMiB"
    static let sidebarExpanded = "lightisle.sidebarExpanded"
    static let sidebarWidth = "lightisle.sidebarWidth"
    static let dockerContext = "lightisle.dockerContext"
    static let dockerMirrorPreset = "lightisle.docker.mirrorPreset"
    static let dockerCustomMirror = "lightisle.docker.customMirror"
    static let dockerUseCustomMirror = "lightisle.docker.useCustomMirror"
    static let dockerApplyColima = "lightisle.docker.applyColima"
    static let dismissedQuickReadyChecklist = "lightisle.dismissedQuickReadyChecklist"
    static let hasCompletedPersonalSpaceStep = "lightisle.hasCompletedPersonalSpaceStep"
    static let mutedExternalVolumePromptKeys = "lightisle.mutedExternalVolumePromptKeys"
}
