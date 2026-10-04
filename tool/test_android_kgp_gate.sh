#!/bin/sh
# Functional tests for the Kotlin-Gradle-Plugin gate in
# android/build.gradle.kts.
#
# Configures the `:nts` Android module standalone -- no Flutter app, no
# Flutter Gradle Plugin -- across the `android.newDsl` /
# `android.builtInKotlin` matrix, and asserts on configuration outcome
# plus whether the standalone KGP ended up applied.
#
# The example app cannot cover this: `:app` fails to configure under
# `android.newDsl=true` because the Flutter Gradle Plugin resolves the
# legacy `BaseExtension` with a non-null assertion (flutter/flutter#180137).
# Isolating the module is what makes the `newDsl=true` legs testable
# ahead of that upstream work. See NTS-162.
#
# The matrix only configures the module (`:nts:tasks`); compiling would
# pull in the Flutter embedding, which is the host app's to provide.
# Configuring never resolves dependencies, so two further checks resolve
# the module's runtime classpath and assert that the
# rustls-platform-verifier AAR it declares -- at the version in
# `rust/Cargo.lock` -- downloads from the repository the module injects,
# and from settings alone under the `RepositoriesMode.PREFER_SETTINGS`
# recipe documented in android/build.gradle.kts.
#
# Requires: a JDK, an Android SDK (ANDROID_HOME or ANDROID_SDK_ROOT),
# network access to github.com (where upstream hosts the AAR), and
# Gradle -- either the example app's wrapper, if a local Flutter build
# has materialised it, or `gradle` on PATH.
#
# Run locally:  sh tool/test_android_kgp_gate.sh
set -eu

REPO_ROOT=$(git rev-parse --show-toplevel)
EXAMPLE_ANDROID="$REPO_ROOT/example/android"

SDK_DIR=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
if [ -z "$SDK_DIR" ]; then
  echo "ERROR: set ANDROID_HOME or ANDROID_SDK_ROOT to an Android SDK" >&2
  exit 1
fi
VERIFIER_VERSION=$(awk '$0 == "name = \"rustls-platform-verifier-android\"" { f = 1; next }
  f && /^version = / { gsub(/"/, "", $3); print $3; exit }' "$REPO_ROOT/rust/Cargo.lock")
[ -n "$VERIFIER_VERSION" ] || {
  echo "ERROR: rustls-platform-verifier-android not found in $REPO_ROOT/rust/Cargo.lock" >&2
  exit 1
}
VERIFIER_MAVEN_URL=$(awk 'f { gsub(/[ "]/, ""); print; exit }
  $0 == "val rustlsPlatformVerifierMavenUrl =" { f = 1 }' "$REPO_ROOT/android/build.gradle.kts")
[ -n "$VERIFIER_MAVEN_URL" ] || {
  echo "ERROR: rustlsPlatformVerifierMavenUrl not found in $REPO_ROOT/android/build.gradle.kts" >&2
  exit 1
}

# Versions are read off the example app rather than duplicated, so the
# probe cannot drift from the toolchain the repo actually builds with.
AGP_VERSION=$(sed -n 's/.*id("com.android.application") version "\([^"]*\)".*/\1/p' \
  "$EXAMPLE_ANDROID/settings.gradle.kts")
KGP_VERSION=$(sed -n 's/.*id("org.jetbrains.kotlin.android") version "\([^"]*\)".*/\1/p' \
  "$EXAMPLE_ANDROID/settings.gradle.kts")
[ -n "$AGP_VERSION" ] && [ -n "$KGP_VERSION" ] || {
  echo "ERROR: could not read AGP/KGP versions from $EXAMPLE_ANDROID/settings.gradle.kts" >&2
  exit 1
}
GRADLE_VERSION=$(sed -n 's/.*distributions\/gradle-\([0-9.]*\)-.*\.zip/\1/p' \
  "$EXAMPLE_ANDROID/gradle/wrapper/gradle-wrapper.properties")
echo "AGP $AGP_VERSION / KGP $KGP_VERSION / Gradle ${GRADLE_VERSION:-unknown}"

# The example app's `gradlew` and `gradle-wrapper.jar` are gitignored
# (Flutter's own `.gitignore` for generated app scaffolding), so a fresh
# checkout has no wrapper to reuse. Prefer it when a local Flutter run
# has materialised it -- that is the exact toolchain the repo builds
# with -- and fall back to a `gradle` on PATH otherwise, which is how
# CI runs (the workflow installs the version parsed above).
if [ -x "$EXAMPLE_ANDROID/gradlew" ]; then
  GRADLE="$EXAMPLE_ANDROID/gradlew"
elif command -v gradle >/dev/null 2>&1; then
  GRADLE=$(command -v gradle)
else
  echo "ERROR: no Gradle available. Run 'flutter build apk --config-only' in" >&2
  echo "       example/ to materialise the wrapper, or install Gradle" >&2
  echo "       ${GRADLE_VERSION:-9.x} on PATH." >&2
  exit 1
fi
echo "using $GRADLE"

WORK_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t ntsgate)
cleanup() {
  "$GRADLE" -p "$WORK_DIR" --stop >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

printf 'sdk.dir=%s\n' "$SDK_DIR" > "$WORK_DIR/local.properties"

cat > "$WORK_DIR/settings.gradle.kts" <<EOF
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("com.android.library") version "$AGP_VERSION" apply false
    // Classpath only: the module applies it conditionally, exactly as a
    // host Flutter app's settings script makes it resolvable.
    id("org.jetbrains.kotlin.android") version "$KGP_VERSION" apply false
}

include(":nts")
project(":nts").projectDir = file("$REPO_ROOT/android")

// Reports whether the conditional \`pluginManager.apply\` in the module
// actually fired, which the gate's outcome alone does not reveal.
gradle.projectsEvaluated {
    val nts = rootProject.project(":nts")
    val applied = nts.plugins.hasPlugin("org.jetbrains.kotlin.android")
    println("NTS_PROBE kgp=\$applied")

    // Resolving the runtime classpath downloads the AAR, which
    // configuring alone never does.
    val runtime = nts.configurations.getByName("releaseRuntimeClasspath")
    nts.tasks.register("ntsProbeVerifierAar") {
        doLast { runtime.files.forEach { println("NTS_PROBE artifact=\${it.name}") } }
    }
}
EOF

pass=0
fail=0

# probe <newDsl> <builtInKotlin> <expect: ok|reject> <expect-kgp: true|false|->
probe() {
  new_dsl=$1; built_in=$2; expect=$3; expect_kgp=$4
  label="newDsl=$new_dsl builtInKotlin=$built_in"
  cat > "$WORK_DIR/gradle.properties" <<EOF
android.useAndroidX=true
android.newDsl=$new_dsl
android.builtInKotlin=$built_in
EOF
  out="$WORK_DIR/out.txt"
  set +e
  "$GRADLE" -p "$WORK_DIR" :nts:tasks --console=plain >"$out" 2>&1
  rc=$?
  set -e

  case "$expect" in
    ok)
      if [ "$rc" -eq 0 ]; then
        pass=$((pass + 1)); echo "  PASS: $label configures"
      else
        fail=$((fail + 1)); echo "  FAIL: $label expected to configure (rc=$rc)" >&2
        sed 's/^/    | /' "$out" >&2
        return
      fi
      if grep -qF "NTS_PROBE kgp=$expect_kgp" "$out"; then
        pass=$((pass + 1)); echo "  PASS: $label KGP applied=$expect_kgp"
      else
        fail=$((fail + 1)); echo "  FAIL: $label expected KGP applied=$expect_kgp" >&2
        grep -F 'NTS_PROBE' "$out" >&2 || echo "    (no NTS_PROBE marker)" >&2
      fi
      ;;
    reject)
      if [ "$rc" -ne 0 ]; then
        pass=$((pass + 1)); echo "  PASS: $label rejected"
      else
        fail=$((fail + 1)); echo "  FAIL: $label expected rejection, rc=0" >&2
      fi
      # The point of the gate: an actionable message instead of KGP's
      # opaque BaseExtension ClassCastException.
      if grep -qF 'android.newDsl=true requires android.builtInKotlin=true' "$out"; then
        pass=$((pass + 1)); echo "  PASS: $label reports the gate message"
      else
        fail=$((fail + 1)); echo "  FAIL: $label missing gate message" >&2
        sed 's/^/    | /' "$out" >&2
      fi
      ;;
  esac
}

echo "=== :nts module configuration matrix ==="
probe true  true  ok     false
probe true  false reject -
probe false false ok     true
probe false true  ok     false

echo
echo "=== rustls-platform-verifier AAR resolution ==="
cat > "$WORK_DIR/gradle.properties" <<EOF
android.useAndroidX=true
android.newDsl=false
android.builtInKotlin=false
EOF
out="$WORK_DIR/out.txt"
expected="rustls-platform-verifier-$VERIFIER_VERSION.aar"
set +e
"$GRADLE" -p "$WORK_DIR" :nts:ntsProbeVerifierAar --console=plain >"$out" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -qxF "NTS_PROBE artifact=$expected" "$out"; then
  pass=$((pass + 1)); echo "  PASS: resolves $expected"
else
  fail=$((fail + 1)); echo "  FAIL: expected to resolve $expected (rc=$rc)" >&2
  sed 's/^/    | /' "$out" >&2
fi

echo
echo "=== AAR resolution under RepositoriesMode.PREFER_SETTINGS ==="
# Gradle ignores the module's project-level repositories in this mode,
# so the AAR must resolve from the settings declaration alone. The
# warning Gradle logs for each ignored repository confirms the mode
# took effect.
cat >> "$WORK_DIR/settings.gradle.kts" <<EOF

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("$VERIFIER_MAVEN_URL")
            content { includeGroup("org.rustls") }
        }
    }
}
EOF
set +e
"$GRADLE" -p "$WORK_DIR" :nts:ntsProbeVerifierAar --console=plain >"$out" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -qxF "NTS_PROBE artifact=$expected" "$out" \
  && grep -qF 'prefer settings repositories over project repositories' "$out"; then
  pass=$((pass + 1)); echo "  PASS: resolves $expected from settings repositories"
else
  fail=$((fail + 1)); echo "  FAIL: expected to resolve $expected from settings repositories (rc=$rc)" >&2
  sed 's/^/    | /' "$out" >&2
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ] || exit 1
