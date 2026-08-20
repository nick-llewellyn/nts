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
    // AGP 9.0+ ships built-in Kotlin support, but Flutter 3.44's
    // migrators (disable_built_in_kotlin_migration.dart,
    // disable_new_dsl_migration.dart) currently force
    // `android.builtInKotlin=false` / `android.newDsl=false` into
    // `gradle.properties`, so this app and the `nts` plugin module
    // still need to resolve `org.jetbrains.kotlin.android` on the
    // classpath to satisfy their conditional `pluginManager.apply(...)`
    // calls (see `app/build.gradle.kts` and
    // `../../android/build.gradle.kts`). `apply false` only adds the
    // plugin to the classpath without applying it, so it's safe to
    // keep declared here even once built-in Kotlin is the norm. See
    // NTS-161.
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
