# R8 / ProGuard keep rules for the `nts` example app.
#
# Keep rules for the `rustls-platform-verifier` companion AAR
# (`org.rustls.platformverifier.**`) and for our own JNI bootstrap
# (`com.nllewellyn.nts.PlatformInit`) are contributed by the `nts` plugin
# itself via `consumer-rules.pro` and merged into this app's R8 config
# automatically.
#
# This file is retained as a hook for any rules that are specific to the
# example application and not appropriate to ship inside the plugin.
# Currently empty; the `release` build still references it from
# `app/build.gradle.kts::proguardFiles(...)` so an example-only rule can
# be added without revisiting the Gradle wiring.
