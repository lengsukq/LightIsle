import java.util.Properties
import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// GitHub Actions passes signing values as environment variables. A developer
// can build the same signed APK locally using their private home-directory
// properties file. Do not fall back to the Android DEBUG certificate.
val localSigningFile = File(System.getProperty("user.home"), ".config/lightisle/android-release.properties")
val localSigning = Properties().apply {
    if (localSigningFile.isFile) {
        localSigningFile.inputStream().use { load(it) }
    }
}
fun signingValue(envName: String, localName: String): String? =
    System.getenv(envName)?.takeIf { it.isNotBlank() }
        ?: localSigning.getProperty(localName)?.takeIf { it.isNotBlank() }

val releaseStorePath = signingValue("LIGHTISLE_ANDROID_KEYSTORE_PATH", "storeFile")
val releaseStorePassword = signingValue("LIGHTISLE_ANDROID_STORE_PASSWORD", "storePassword")
val releaseKeyPassword = signingValue("LIGHTISLE_ANDROID_KEY_PASSWORD", "keyPassword")
val releaseKeyAlias = signingValue("LIGHTISLE_ANDROID_KEY_ALIAS", "keyAlias")
val hasReleaseSigning = listOf(releaseStorePath, releaseStorePassword, releaseKeyPassword, releaseKeyAlias)
    .all { !it.isNullOrBlank() } && releaseStorePath?.let { File(it).isFile } == true
val releaseTaskRequested = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true) || it.contains("bundle", ignoreCase = true)
}
if (releaseTaskRequested && !hasReleaseSigning) {
    throw GradleException("LightIsle Android Release requires a private signing keystore and its credentials; refusing a debug/unsigned release.")
}

android {
    namespace = "top.lengsu.lightisle"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "top.lengsu.lightisle"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = File(requireNotNull(releaseStorePath))
                storePassword = releaseStorePassword
                keyPassword = releaseKeyPassword
                keyAlias = releaseKeyAlias
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Reliable, OS-constrained periodic work; no permanent foreground service.
    implementation("androidx.work:work-runtime-ktx:2.11.2")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
