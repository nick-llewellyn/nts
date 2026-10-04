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

import com.android.build.api.dsl.LibraryExtension
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension

plugins {
    // Versions are inherited from the consuming Flutter app's
    // `settings.gradle.kts` `pluginManagement` block, which is how every
    // Flutter plugin module resolves AGP / Kotlin without pinning its
    // own copies. Listing them with `apply false` here would break that
    // contract, so the un-versioned form is intentional.
    id("com.android.library")
}

// AGP 9.0 ships built-in Kotlin support and applies it automatically; the
// standalone `org.jetbrains.kotlin.android` plugin is not just redundant
// there but actively incompatible with AGP 9's built-in Kotlin, so it must
// only be applied when built-in Kotlin is not in effect. Gating on the AGP
// major version alone is not sufficient: AGP 9 still supports
// `android.builtInKotlin=false` (Flutter 3.44's migrators force exactly
// that into `gradle.properties` regardless of AGP version -- see this
// repo's own `example/android/gradle.properties`), and Flutter 3.38 (this
// package's floor) has no fallback that applies KGP for us on that
// compatibility path. So the effective property is checked as well as the
// AGP major version. Other published Flutter plugins facing the same AGP 9
// migration use this same gate (e.g. `cunning_document_scanner`).
//
// `android.builtInKotlin` is not a free variable once `android.newDsl=true`,
// though: under the new DSL AGP does not register the legacy
// `com.android.build.gradle.BaseExtension`, and KGP casts the `android`
// extension to exactly that type as it applies itself. So
// `newDsl=true` + `builtInKotlin=false` leaves no way to compile this
// module's Kotlin -- built-in Kotlin is off and the standalone plugin
// cannot attach. AGP only warns about the combination, so the first hard
// signal is a `ClassCastException` raised from this script; the check
// below turns that into an actionable message instead. See NTS-162.
val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val newDslProperty = providers.gradleProperty("android.newDsl").orNull
val newDslEnabled = agpMajor >= 9 && (newDslProperty?.toBoolean() ?: true)
val builtInKotlinProperty = providers.gradleProperty("android.builtInKotlin").orNull
val builtInKotlinEnabled = agpMajor >= 9 && (builtInKotlinProperty?.toBoolean() ?: true)
require(!(newDslEnabled && !builtInKotlinEnabled)) {
    "nts: android.newDsl=true requires android.builtInKotlin=true. The " +
        "standalone Kotlin Gradle Plugin casts the android extension to " +
        "the legacy com.android.build.gradle.BaseExtension, which AGP does " +
        "not register under the new DSL. Set android.builtInKotlin=true in " +
        "gradle.properties, or set android.newDsl=false (what Flutter's own " +
        "migrators write, and currently required by the Flutter Gradle " +
        "Plugin regardless of this package)."
}
if (!builtInKotlinEnabled) {
    pluginManager.apply("org.jetbrains.kotlin.android")
}

group = "com.nllewellyn.nts"
version = "1.4.0"

// The Kotlin glue `org.rustls.platformverifier.CertificateVerifier`,
// invoked over JNI by `rustls-platform-verifier` on Android, ships as a
// pre-built AAR (`org.rustls:rustls-platform-verifier`) in a Maven
// repository that upstream hosts on the `maven-archive` branch of its
// GitHub repository. The AAR version must be identical to the
// `rustls-platform-verifier-android` crate version that Cargo resolves, so
// it is read from `rust/Cargo.lock` rather than hard-coded: a lockfile
// bump moves the AAR with it. This is the `ValueSource` upstream's README
// documents, which keeps the read compatible with the configuration
// cache.
//
// `Cargo.lock` sits at `<plugin>/rust/Cargo.lock` and ships in the
// published package. `projectDir` here is `<plugin>/android/`, so the
// relative path is stable regardless of where the plugin is installed.
abstract class RustlsPlatformVerifierVersion :
    ValueSource<String, RustlsPlatformVerifierVersion.Params> {
    interface Params : ValueSourceParameters {
        val lockFile: RegularFileProperty
    }

    override fun obtain(): String {
        val lockFile = parameters.lockFile.get().asFile
        require(lockFile.isFile) {
            "Expected nts Cargo lockfile at $lockFile. Has the plugin layout changed?"
        }
        val lines = lockFile.readLines()
        val nameIdx = lines.indexOfFirst {
            it.trim() == "name = \"rustls-platform-verifier-android\""
        }
        val version = if (nameIdx < 0) {
            null
        } else {
            lines.drop(nameIdx + 1)
                .firstOrNull { it.trimStart().startsWith("version = ") }
                ?.substringAfter('"', "")
                ?.substringBefore('"', "")
                ?.takeIf { it.isNotEmpty() }
        }
        return version ?: error("rustls-platform-verifier-android not found in $lockFile")
    }
}

val rustlsPlatformVerifierVersion: String = providers
    .of(RustlsPlatformVerifierVersion::class.java) {
        parameters.lockFile.set(layout.projectDirectory.file("../rust/Cargo.lock"))
    }
    .get()

// Inject upstream's `org.rustls` Maven repository into every project in
// the host build, not just `:nts`. Gradle resolves transitive dependencies
// of a project against the *consumer*'s repository list by default, so a
// `repositories { ... }` block scoped to this module would leave the
// `:app` -> `:nts` -> `org.rustls:...` resolution looking only at the
// host's `google()` / `mavenCentral()` chain (where the AAR does not
// exist).
//
// `content { includeGroup("org.rustls") }` keeps the injected repo
// strictly scoped to the one group upstream publishes there, so it does
// not slow other dep resolution or override anything resolvable from the
// public mirrors. Failure to find a non-`org.rustls` artifact will not
// even touch this repo. The first build fetches the AAR from github.com;
// Gradle caches it after that.
//
// `RepositoriesMode.FAIL_ON_PROJECT_REPOS` is not supported: Gradle
// rejects every project-level repository under it, including this
// injection and the module's own `repositories` block below, even when
// settings declares the same URL. The Flutter Gradle Plugin injects its
// engine repository the same way. Hosts that centralise repositories in
// `settings.gradle.kts` (not the `flutter create` default) use
// `PREFER_SETTINGS` instead. Gradle then ignores every project-level
// repository, so settings must declare all the build needs, this one
// included:
//
//     dependencyResolutionManagement {
//         repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
//         repositories {
//             google()
//             mavenCentral()
//             maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
//             maven {
//                 url = uri("https://github.com/rustls/rustls-platform-verifier/raw/maven-archive/android-release-support/maven/")
//                 content { includeGroup("org.rustls") }
//             }
//         }
//     }
//
// `tool/test_android_kgp_gate.sh` resolves the AAR under this recipe.
val rustlsPlatformVerifierMavenUrl =
    "https://github.com/rustls/rustls-platform-verifier/raw/maven-archive/android-release-support/maven/"

rootProject.allprojects {
    repositories {
        maven {
            url = uri(rustlsPlatformVerifierMavenUrl)
            content { includeGroup("org.rustls") }
        }
    }
}

repositories {
    google()
    mavenCentral()
}

// `android { ... }` is the classic extension-function accessor
// (`Project.android(Action<LibraryExtension>)`); it is deprecated once
// `android.newDsl=true` (the AGP 9 default) and removed in AGP 10.
// `configure<LibraryExtension> { ... }` is the stable replacement that
// works unchanged across AGP 8.x and 9.x.
configure<LibraryExtension> {
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
            // `srcDirs(...)` is deprecated in favor of the `directories`
            // mutable set (both add to, rather than replace, the default
            // source dirs).
            java.directories.add("src/main/kotlin")
        }
    }
}

// `android.kotlinOptions { jvmTarget = ... }` had its deprecation level
// raised to ERROR in Kotlin 2.2.0, so it now fails script compilation
// rather than just warning. `kotlin.compilerOptions` is the replacement,
// but it only applies (and only needs applying) when the standalone
// Kotlin plugin is present -- on AGP 9's built-in Kotlin, `jvmTarget`
// already defaults from `compileOptions.targetCompatibility` above.
plugins.withId("org.jetbrains.kotlin.android") {
    configure<KotlinAndroidProjectExtension> {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
}

dependencies {
    // Companion AAR for `rustls-platform-verifier`. Provides the Kotlin
    // glue (`org.rustls.platformverifier.*`) that the Rust crate invokes
    // over JNI to delegate X.509 chain validation to Android's
    // `X509TrustManager`. The version is the
    // `rustls-platform-verifier-android` entry in `rust/Cargo.lock` (see
    // `RustlsPlatformVerifierVersion` above). The `@aar` extension selects
    // the AAR explicitly: upstream's repository publishes a POM but no
    // Gradle module metadata.
    //
    // AAR 0.2.0 carries its own manifest, which the host app's manifest
    // merger folds in: the `INTERNET` permission and an
    // `android:networkSecurityConfig` that permits cleartext HTTP to the
    // CRL distribution hosts upstream lists, so certificate revocation
    // checks can fetch CRLs.
    implementation("org.rustls:rustls-platform-verifier:$rustlsPlatformVerifierVersion@aar")
}
