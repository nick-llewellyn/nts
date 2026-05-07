// Plugin module Gradle script for the `nts` Flutter plugin's Android side.
//
// This module is consumed by Flutter apps that depend on `nts` from
// pub.dev (or via path/git). It ships:
//
//   * `com.nllewellyn.nts.NtsPlugin`     -- `FlutterPlugin` that auto-inits
//                                          `rustls-platform-verifier` from
//                                          `onAttachedToEngine`.
//   * `com.nllewellyn.nts.PlatformInit`  -- JNI Kotlin counterpart for the
//                                          `Java_com_nllewellyn_nts_PlatformInit_nativeInit`
//                                          symbol exported from
//                                          `rust/src/android_init.rs`.
//   * `consumer-rules.pro`              -- ProGuard / R8 keep rules
//                                          auto-merged into the host app.
//
// The native dylib (`libnts_rust.so`) is **not** built or bundled here.
// It is delivered by the Native Assets pipeline (`hook/build.dart`),
// which copies the FRB-generated cdylib into the host APK at the
// standard JNI library path (`lib/<abi>/`). `System.loadLibrary("nts_rust")`
// in `PlatformInit` resolves it via the platform linker, so this Gradle
// module needs no `jniLibs` directory or Cargo integration of its own.

import groovy.json.JsonSlurper
import java.io.File

plugins {
    // Versions are inherited from the consuming Flutter app's
    // `settings.gradle.kts` `pluginManagement` block, which is how every
    // Flutter plugin module resolves AGP / Kotlin without pinning its
    // own copies. Listing them with `apply false` here would break that
    // contract, so the un-versioned form is intentional.
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

group = "com.nllewellyn.nts"
version = "1.4.0"

// Locate the on-disk Maven repository bundled inside the
// `rustls-platform-verifier-android` companion crate. The crate publishes a
// pre-built AAR (`rustls:rustls-platform-verifier`) that contains the
// Kotlin glue `org.rustls.platformverifier.CertificateVerifier` invoked
// over JNI by `rustls-platform-verifier 0.5.x` on Android.
//
// We resolve the path by asking `cargo` for resolved package metadata of
// the `nts_rust` crate (which transitively pulls in
// `rustls-platform-verifier-android`) and walking to the `maven/`
// directory next to its `Cargo.toml`. This makes Gradle resilient to:
//
//   * Crate version bumps (no hard-coded path).
//   * Different on-disk layouts (source tree vs pub cache vs monorepo).
//
// `Cargo.toml` of the parent crate sits at `<plugin>/rust/Cargo.toml`.
// `projectDir` here is `<plugin>/android/`, so the relative path is
// stable regardless of where the plugin is installed.
fun resolveRustlsPlatformVerifierMaven(): String {
    val manifest = projectDir.resolve("../rust/Cargo.toml").canonicalFile
    require(manifest.isFile) {
        "Expected nts Rust crate at $manifest. Has the plugin layout changed?"
    }
    val proc = ProcessBuilder(
        "cargo",
        "metadata",
        "--format-version",
        "1",
        "--manifest-path",
        manifest.absolutePath,
    ).start()
    // Drain stderr concurrently so a verbose `cargo metadata` failure cannot
    // deadlock the build by filling the OS-level stderr pipe buffer
    // (typically 64 KiB on Linux) while we block on `waitFor()` reading
    // stdout. The captured text is folded into the `require` message below
    // so a non-zero exit surfaces actionable diagnostics rather than just
    // the bare exit code.
    val stderrBuf = StringBuilder()
    val stderrThread = Thread {
        proc.errorStream.bufferedReader().forEachLine { stderrBuf.appendLine(it) }
    }.apply { isDaemon = true; start() }
    val stdout = proc.inputStream.bufferedReader().readText()
    val rc = proc.waitFor()
    stderrThread.join()
    require(rc == 0) {
        "cargo metadata exited with $rc while resolving " +
            "rustls-platform-verifier-android. stderr:\n$stderrBuf"
    }
    @Suppress("UNCHECKED_CAST")
    val json = JsonSlurper().parseText(stdout) as Map<String, Any>
    @Suppress("UNCHECKED_CAST")
    val packages = json["packages"] as List<Map<String, Any>>
    val pkg = packages.first { it["name"] == "rustls-platform-verifier-android" }
    val manifestPath = pkg["manifest_path"] as String
    return File(manifestPath).parentFile.resolve("maven").absolutePath
}

// Cache the resolved Maven path for the duration of the Gradle build.
// `rootProject.allprojects { repositories { ... } }` below evaluates its
// closure once per project visited (root + `:app` + every plugin module
// in a typical Flutter app), so without this `by lazy` the `cargo metadata`
// subprocess would fork once per project. `cargo metadata` walks the entire
// resolved dependency graph and is multi-second on a cold cache, so the
// per-project fan-out was a measurable configuration-time regression for
// multi-module hosts. The path is a pure function of the on-disk Cargo
// workspace, which does not move during a single Gradle run.
val rustlsPlatformVerifierMavenPath: String by lazy { resolveRustlsPlatformVerifierMaven() }

// Inject the on-disk `rustls:rustls-platform-verifier` Maven repository
// into every project in the host build, not just `:nts`. Gradle resolves
// transitive dependencies of a project against the *consumer*'s repository
// list by default, so a `repositories { ... }` block scoped to this
// module would leave the `:app` -> `:nts` -> `rustls:...` resolution
// looking only at the host's `google()` / `mavenCentral()` chain (where
// the AAR does not exist).
//
// `content { includeGroup("rustls") }` keeps the injected repo strictly
// scoped to the one group we publish from the on-disk crate, so it does
// not slow other dep resolution or override anything resolvable from the
// public mirrors. Failure to find a non-`rustls` artifact will not even
// touch this repo.
//
// Hosts that opt in to `dependencyResolutionManagement.repositoriesMode
// = RepositoriesMode.FAIL_ON_PROJECT_REPOS` (uncommon for Flutter apps;
// not the `flutter create` default) will need to declare this repo
// themselves in `settings.gradle.kts`. The file path printed by
// `cargo metadata --format-version 1 --manifest-path
// <pub-cache>/nts-X.Y.Z/rust/Cargo.toml` is stable and can be reused
// verbatim.
rootProject.allprojects {
    repositories {
        maven {
            url = uri(rustlsPlatformVerifierMavenPath)
            // The crate ships the AAR + POM but no Maven metadata index
            // file; tell Gradle to discover artifacts directly off the
            // filesystem.
            metadataSources { artifact() }
            content { includeGroup("rustls") }
        }
    }
}

repositories {
    google()
    mavenCentral()
}

android {
    namespace = "com.nllewellyn.nts"
    // Pinned to the AGP 8.x / Flutter 3.38 stable default. The plugin
    // module itself only consumes platform APIs available since API 24
    // (see `minSdk` below), but the AAR companion of
    // `rustls-platform-verifier` and the `FlutterPlugin` lifecycle hooks
    // we register against require building with the current SDK. Hosts
    // on older Flutter or AGP toolchains will need to upgrade in lockstep
    // with this floor; making it configurable would let a stale host
    // silently miss compile-time API checks the plugin relies on.
    compileSdk = 35

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Matches Flutter 3.38 stable's default `flutter.minSdkVersion`.
        // Lower than this would require the host app to override and is
        // not a configuration we test.
        minSdk = 24

        // Auto-merged into the consuming application's R8 / ProGuard
        // configuration. Keeps the rustls-platform-verifier glue and our
        // own JNI class alive under aggressive shrinking, which is the
        // Flutter `release` default.
        consumerProguardFiles("consumer-rules.pro")
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }
}

dependencies {
    // Companion AAR for `rustls-platform-verifier`. Provides the Kotlin
    // glue (`org.rustls.platformverifier.*`) that the Rust crate invokes
    // over JNI to delegate X.509 chain validation to Android's
    // `X509TrustManager`. Pinned to the version that ships alongside
    // `rustls-platform-verifier 0.5.3` in our `Cargo.lock`. The `@aar`
    // classifier is required because the on-disk Maven layout produced
    // by `rustls-platform-verifier-android` only ships the AAR + POM and
    // Gradle defaults to looking for a JAR otherwise.
    implementation("rustls:rustls-platform-verifier:0.1.1@aar")
}
