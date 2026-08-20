pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.2.1" apply false
    // AGP 9.0+ ships built-in Kotlin support, so the standalone Kotlin
    // Gradle plugin is no longer applied here. `android/build.gradle.kts`
    // (the `nts` plugin module) still declares its own conditional
    // `org.jetbrains.kotlin.android` apply for hosts on AGP < 9; see
    // NTS-161.
}

include(":app")
