import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Private signing values live in android/key.properties (gitignored).
val signingFile = rootProject.file("key.properties")
val signingProperties = Properties().apply {
    if (signingFile.isFile) signingFile.inputStream().use { load(it) }
}
val requiredSigningKeys = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val hasReleaseSigning = requiredSigningKeys.all {
    !signingProperties.getProperty(it).isNullOrBlank()
}

// Fail closed: never silently distribute a debug-signed release.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.contains("Release") }) {
        check(hasReleaseSigning) {
            "Release signing requires android/key.properties: storeFile, storePassword, keyAlias, keyPassword. See docs/ANDROID_RELEASE.md."
        }
        check(rootProject.file(signingProperties.getProperty("storeFile")).isFile) {
            "Release keystore was not found. Check storeFile in android/key.properties."
        }
    }
}

android {
    namespace = "com.neoen.ie_koto"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.neoen.ie_koto"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(signingProperties.getProperty("storeFile"))
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // Explicit test opt-in keeps emulator tests away from user data.
            if (System.getenv("IE_KOTO_ISOLATED_TEST") == "1") {
                applicationIdSuffix = ".verification"
            }
        }
        release {
            signingConfig = signingConfigs.findByName("release")
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
