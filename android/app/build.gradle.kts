import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// THE UPLOAD KEY, loaded from android/key.properties, which is NOT in the
// repository (see android/.gitignore). Every machine that has to produce a
// build for Google Play needs both that file and the keystore it points at.
//
// A checkout WITHOUT the file still builds: the release type falls back to the
// debug key, which is what `flutter run --release` and a hand-built tester APK
// have always used. The fallback is LOUD, because a debug-signed build that
// reaches Play is rejected, and a debug-signed build that reaches a tester
// under a Play-looking name is worse: it cannot be updated by Play later.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}
val hasUploadKey = keystorePropertiesFile.exists()

// Only shout when a RELEASE build is what was asked for. CI builds a debug
// APK and needs no key, and a warning that fires on every build is a warning
// nobody reads.
if (!hasUploadKey &&
    gradle.startParameter.taskNames.any { it.contains("elease") }
) {
    logger.warn(
        "WARNING: android/key.properties is missing, so this release build is " +
            "signed with the DEBUG key. Google Play will reject it, and no Play " +
            "build can ever update it."
    )
}

android {
    namespace = "com.ballshank.commute_guardian"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // PERMANENT. After the first upload to Google Play this string can
        // never change: it is the app's identity on the store and in its URL.
        applicationId = "com.ballshank.commute_guardian"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("upload")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // MediaSessionCompat, for the wake escalation's earphone-tap
    // acknowledgment (see MainActivity).
    implementation("androidx.media:media:1.7.0")
}

flutter {
    source = "../.."
}
