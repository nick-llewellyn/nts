# Strict clock evidence matrix (NTS-180)

Machine-checked record of what has actually been observed for the
strict clock (`lib/src/api/strict_clock.dart`,
`rust/src/nts/boottime.rs`) on each supported platform. Validated by
`dart run tool/clock_evidence/check_evidence_matrix.dart`. With
`--require-complete` that command is the `nts-flr8.9` matrix gate: it
fails while any `android` or `ios` row is outstanding. Outstanding
`macos`, `linux` and `windows` rows are reported but do not gate the
release. The bead's other release criteria, such as the post-`4d3f42b`
Android NTS query, are recorded on the bead, not in this matrix.

A row is the unit of evidence. `status` is one of:

| Status | Meaning |
|---|---|
| `pass` | Observed, on the stated platform, by the stated method. Requires a non-empty `evidence`. |
| `fail` | Observed and did not hold. Requires a `next-action`. |
| `pending` | Not yet attempted. Requires a `next-action`. |
| `blocked` | Attempted, cannot proceed. Requires a `next-action` naming the blocker. |
| `n/a` | The dimension does not exist on this platform. Requires an `evidence` cell saying why. |

Per the `nts-flr8` delivery policy an unavailable proof stays
`pending` or `blocked`; it is never promoted to `pass` on the
strength of a simulator, a mock, a thread sleep, or a CI compile.
The dimensions from `suspend-resume` down are physical-device
observations and cannot be satisfied by any automated run in this
repository.

Dimension meanings:

| Dimension | What a `pass` asserts |
|---|---|
| `source-contract` | The platform reader named in `evidence` is the one the build selects, read from source. |
| `compilation` | The crate compiles for this target with that reader selected. |
| `rust-unit-tests` | `cargo test --lib nts::boottime`, the unit tests of the platform reader module, passes for this target. A passing unfiltered `cargo test --lib` also satisfies it. |
| `dart-hermetic-tests` | The mock-bridge strict-clock suite passes. |
| `native-runtime-read` | A `StrictClockContext` resolved with `StrictClockProvenance.native` returned a reading on the expected backend, on real hardware. |
| `multi-engine` | Two live Flutter engines in one process each hold a valid context, and a fault in one is observed by the other. |
| `bridge-teardown` | `NtsBridge.dispose()` invalidates contexts in every engine of the process. |
| `process-relaunch` | After process death and relaunch on the same boot, a fresh context resolves on a descriptor compatible with the pre-kill one. Generations are not compared: a generation is a per-process lifecycle token that restarts independently in each process, so equal values across two launches prove nothing. |
| `descriptor-compatibility` | The descriptor is stable across relaunch on one boot and its `isCompatibleWith` verdict matches the observed coordinate. |
| `suspend-resume` | Readings advance across a real device suspend/resume by the wall duration of the suspend. |
| `locked-after-first-unlock` | Reads keep working while the device is locked after first unlock. |
| `rtc-change` | A wall-clock/RTC change does not move the coordinate. |
| `process-death` | An OS-initiated process kill loses the coordinate cleanly: the relaunched process resolves a fresh context, a reference persisted before the kill does not bind there without an approved `BootScopeProvider` vouching for the boot, and nothing accepts a raw pre-kill reading as a coordinate. While no provider is approved, `exportReference` mints no `SameBootReference` and `bindReference` refuses with or without a kill, so a `pass` shows the approval gate holding across the kill, not the library detecting it. As above, no generation crosses the process boundary to compare. |
| `reboot` | The coordinate resets across reboot and no same-boot claim survives it. |
| `uptime-after-boot` | Immediately after boot the reader returns a small, non-negative value rather than a fault. |

## android

| dimension | status | method | evidence | next-action |
|---|---|---|---|---|
| source-contract | pass | source review | `rust/src/nts/boottime.rs` selects `clock_gettime(CLOCK_BOOTTIME)` for `target_os = "android"` | |
| compilation | pass | host cross-compile | macOS 27.0 host, rustc 1.98.0, cargo-dinghy 0.8.6, 2026-09-29: `cargo dinghy -d <Pixel Tablet> test --lib` built the crate for `aarch64-linux-android`. The example app's profile build of `example/lib/clock_probe_main.dart` built, installed and ran on the same device for every device row below. Not CI: the KGP gate matrix (`tool/test_android_kgp_gate.sh`) does not build the crate for Android. | |
| rust-unit-tests | pass | ci + device | The Android reader is the `any(target_os = "android", target_os = "linux")` arm of `rust/src/nts/boottime.rs`, which `cargo test --lib` compiles and exercises on the Ubuntu leg. On device (Pixel Tablet, Android 17 CP3A.260905.009, rustc 1.98.0, cargo-dinghy 0.8.6, 2026-10-10): `cargo dinghy -d <Pixel Tablet> test --lib nts::boottime`, 40 passed / 0 failed / 0 ignored, 352 filtered out. The unfiltered `cargo dinghy test --lib` (CP2A.260705.006, 2026-09-24 and again 2026-09-29) does not pass: 386 passed / 4 failed / 2 ignored both times. The 4 failures are the live Cloudflare NTS tests (`nts_query_live_cloudflare*`, `nts_warm_cookies_live_cloudflare*`), none in `nts::boottime`; they fail because the dinghy harness never runs the `rustls-platform-verifier` JNI bootstrap (`nts-6d24`). | |
| dart-hermetic-tests | pass | ci | `strict clock (nts-flr8)` group in `test/api_smoke_test.dart` | |
| native-runtime-read | pass | device | Pixel Tablet, Android 17 CP2A.260705.006, 2026-09-24, `example/lib/clock_probe_main.dart`: `provenance=native`, `backend=linuxBoottime`, `generation=1`, two consecutive reads increasing (debug build 17:23:17Z; profile build 19:05:06Z). | |
| multi-engine | pass | device | Pixel Tablet, 2026-09-24 17:29:00Z, second `FlutterEngine` hosted by `MainActivity.kt`: both engines resolved `provenance=native`, `linuxBoottime`, `generation=1`. After `ntsClockInvalidate` (native generation 1 → 2), engine 1's next read was invalidated with `nativeGeneration` and so was engine 2's; engine 2 re-resolved on generation 2 and read again. | |
| bridge-teardown | pass | device | Pixel Tablet, 2026-09-24 17:29:17Z: `NtsBridge.dispose()` in engine 1 invalidated engine 1's context with `bridgeReset` and engine 2's next read with `nativeGeneration`; engine 2 re-resolved on generation 3. | |
| process-relaunch | pass | device | Pixel Tablet, profile build, 2026-09-24: force-stop and relaunch, pid 7954 → 8107 (19:05:49Z): the fresh context resolved `provenance=native` on a descriptor compatible with the pre-kill record; clock delta matched wall delta to −1 µs. Generations not compared. | |
| descriptor-compatibility | pass | device | Pixel Tablet, 2026-09-24/26: descriptor persisted across six same-boot relaunches into a new process: pids 4228 → 4645 (17:27:39Z), 4645 → 7954 (19:05:06Z), 7954 → 8107 (19:05:49Z) and 8107 → 9563 (19:36:18Z) on one boot; 3833 → 4805 and 4805 → 4930 (2026-09-26 18:09:08Z, 18:09:20Z) on the next. Every `isCompatibleWith` verdict was `true`. Clock deltas matched wall deltas to within 26 µs, except at 19:36:18Z (+1.159524 s), where the two manual time changes of the `rtc-change` row had left the wall clock 1.159564 s behind. A restart at 17:36:54Z stayed in pid 4645 and is not counted. | |
| suspend-resume | pass | device | Pixel Tablet, profile build, 2026-09-24, screen off unplugged: marks 19:18:46Z → 19:27:11Z gave strict 505.121924 s vs wall 505.121906 s (−18 µs). Dart `Stopwatch` (`CLOCK_MONOTONIC`) advanced 191.999 s over the same interval, so the device was suspended for 313.12 s and the strict clock counted it. | |
| locked-after-first-unlock | pass | device | Pixel Tablet, profile build, 2026-09-24: lock screen shown 19:21:07Z, dismissed 19:27:07Z (after first unlock). Nine periodic reads succeeded while locked (19:21:12Z–19:25:19Z, spanning the suspend above). Reads ran from a Dart timer in the foreground app process, not a foreground service. | |
| rtc-change | pass | device | Pixel Tablet, profile build, 2026-09-24: system time set forward 1 h, then back. Wall moved +3606.262591 s and −3597.711133 s while strict moved +6.390369 s and +3.320653 s, matching `Stopwatch` (+6.390351 s, +3.320627 s) to within 26 µs. | |
| process-death | pass | device | Pixel Tablet, profile build, 2026-09-24: export at 19:36:05Z persisted the candidate reference (`referenceMicros` and descriptor of a strict sync); `exportReference` refuses it with `providerNotApproved`, so no `SameBootReference` was minted. The app was sent to the background (Home) and killed with `adb shell am kill com.nts.example`, the ActivityManager path used to reclaim background processes. Relaunch as pid 9563 (19:36:18Z) resolved a fresh native context; a `SameBootReference` rebuilt from the persisted candidate did not bind (`providerNotApproved`, no approved `BootScopeProvider`). No raw pre-kill reading was accepted. The bind is refused without a kill too, so this shows the approval gate holds across an OS kill, not that the library detected the kill. | |
| reboot | pass | device | Pixel Tablet, profile build, 2026-09-24: first launch after reboot (19:41:59Z, pid 3833) read 57.625092 s; against the pre-reboot record the clock went back 2002611.10 s while wall advanced 341.38 s (`clockBackwards=true`). The descriptor stayed compatible, because it names the backend, not the boot. The persisted reference did not bind (`providerNotApproved`), so this shows the approval gate holds, not that the library detected the reboot. | |
| uptime-after-boot | pass | device | Pixel Tablet, profile build, 2026-09-24 19:41:59Z: first launch after reboot, first native read 57.625092 s, non-negative, `generation=1`, no fault. | |

## ios

| dimension | status | method | evidence | next-action |
|---|---|---|---|---|
| source-contract | pass | source review | `rust/src/nts/boottime.rs` selects `mach_continuous_time` scaled by `mach_timebase_info` for Apple targets | |
| compilation | pass | host | macOS 27.0 host, Flutter 3.44.0, Xcode 26.6, 2026-09-29: `flutter build ios --profile -t lib/clock_probe_main.dart` built `Runner.app` for device, and `cargo dinghy` built the crate for `aarch64-apple-ios` (rustc 1.98.0). The same profile build was installed and run on the iPad for every device row below. Not CI: every `ci.yml` job runs on `ubuntu-latest`. | |
| rust-unit-tests | pass | device | iPad mini 6, iOS 27.0 (24A437), rustc 1.98.0, cargo-dinghy 0.8.6, 2026-09-24 and again 2026-09-29: `cargo dinghy test --lib` ran on the device, 391 passed / 0 failed / 2 ignored both times; all 41 `nts::boottime` tests passed in the 2026-09-29 run, compiling the real `cfg(any(ios, macos))` `mach_continuous_time` reader. No CI job does this: every `ci.yml` job runs on `ubuntu-latest`. | |
| dart-hermetic-tests | pass | ci | `strict clock (nts-flr8)` group in `test/api_smoke_test.dart` | |
| native-runtime-read | pass | device | iPad mini 6, iOS 27.0 (24A437), 2026-09-24, `example/lib/clock_probe_main.dart`: `provenance=native`, `backend=appleContinuous`, `generation=1`, two consecutive reads increasing (debug build 17:31:03Z; profile build 17:38:13Z). | |
| multi-engine | pass | device | iPad mini 6, profile build, 2026-09-24 17:43:31Z, second `FlutterEngine` hosted by `AppDelegate.swift`: both engines resolved `provenance=native`, `appleContinuous`, `generation=1`. After `ntsClockInvalidate`, engine 1's next read was invalidated with `nativeGeneration` and so was engine 2's. | |
| bridge-teardown | pass | device | iPad mini 6, profile build, 2026-09-24 17:43:35Z: `NtsBridge.dispose()` in engine 1 invalidated engine 1's context with `bridgeReset` and engine 2's next read with `nativeGeneration`. | |
| process-relaunch | pass | device | iPad mini 6, profile build, 2026-09-24: swipe-kill and Home Screen relaunch, pid 1289 → 1302 (19:48:13Z): the fresh context resolved `provenance=native` on a descriptor compatible with the pre-kill record; clock delta matched wall delta to −480 µs. Generations not compared. | |
| descriptor-compatibility | pass | device | iPad mini 6, 2026-09-24/26: descriptor persisted across eleven same-boot relaunches into a new process: pids 929 → 943 → 949 → 952 → 1289 → 1302 → 2467 → 2468 → 2543 on one boot (2026-09-24 17:38:13Z to 2026-09-26 08:12:45Z) and 466 → 630 → 904 → 908 on the next (2026-09-26 08:46:01Z to 08:48:32Z). Every `isCompatibleWith` verdict was `true`. Clock deltas matched wall deltas to within 3.9 ms for relaunches minutes apart; the two relaunches hours apart differed by −27.9 ms (pid 1289, after 2 h 3 min) and −178.0 ms (pid 2467, after 36 h 19 min). | |
| suspend-resume | pass | device | iPad mini 6, profile build, 2026-09-24, unplugged sleep: marks 20:08:28Z → 20:20:24Z gave strict 715.741001 s vs wall 715.742862 s (1.86 ms). The iPad's power-management log (`IOPMrootDomain`) confirms the sleep: Last Sleep Reason=Idle Sleep, Wake Reason=USBPlugEvent. Dart `Stopwatch` also counts through sleep on iOS, so it cannot show the sleep here. | |
| locked-after-first-unlock | pass | device | iPad mini 6, profile build, 2026-09-24: locked 19:58:21Z (after first unlock); six reads from a `beginBackgroundTask` in `AppDelegate.swift` succeeded while locked (19:58:24Z–19:58:49Z; the task expired 19:58:48Z). First read after unlock (20:03:48Z): strict delta 298.262105 s vs wall 298.262786 s. | |
| rtc-change | pass | device | iPad mini 6, profile build, 2026-09-24: date set back one day, then restored. Wall moved −86412.04 s and +86471.98 s while strict moved +44.19 s and +15.75 s; the two wall-minus-strict offsets cancel to 0.1 ms. | |
| process-death | pass | device | iPad mini 6, profile build, 2026-09-26 (`nts-flr8.10`): export at 08:46:12Z persisted the candidate reference (`referenceMicros` and descriptor of a strict sync) and was refused (`providerNotApproved`), so no `SameBootReference` was minted. The probe's Jetsam action then filled foreground memory until iOS killed the app: `JetsamEvent-2026-09-26-094645.ips` lists `Runner` pid 630 as the largest process, `reason=vm-pageshortage` (system-wide page shortage, not `per-process-limit`), states active and frontmost. Relaunch from the Home Screen as pid 904 (08:48:00Z) resolved a fresh native context; a `SameBootReference` rebuilt from the persisted candidate did not bind (`providerNotApproved`, no approved `BootScopeProvider`). No raw pre-kill reading was accepted. The bind is refused without a kill too, so this shows the approval gate holds across an OS kill, not that the library detected the kill. | |
| reboot | pass | device | iPad mini 6, profile build, 2026-09-26: first launch after reboot (08:36:28Z, pid 466) read 120.145085 s; against the pre-reboot record the clock went back 158517.53 s while wall advanced 1423.35 s (`clockBackwards=true`). The descriptor stayed compatible, because it names the backend, not the boot. The persisted reference did not bind (`providerNotApproved`), so this shows the approval gate holds, not that the library detected the reboot. | |
| uptime-after-boot | pass | device | iPad mini 6, profile build, 2026-09-26 08:36:28Z: first launch after reboot and first unlock, first native read 120.145085 s, non-negative, `generation=1`, no fault. A launch before first unlock was not possible: the iPad does not appear over USB until first unlock, and `devicectl` returns error 4016. | |

## macos

| dimension | status | method | evidence | next-action |
|---|---|---|---|---|
| source-contract | pass | source review | Same Apple branch as iOS in `rust/src/nts/boottime.rs` | |
| compilation | pass | host | macOS 27.0 (26A428), 2026-09-22: `cargo build --release -p nts_rust` succeeded locally. Not CI — every `ci.yml` job runs on `ubuntu-latest`. | |
| rust-unit-tests | pass | host | macOS 27.0 (26A428), 2026-09-22: `cargo test --lib --locked` locally, 391 passed / 0 failed / 2 ignored, compiling the real `cfg(any(ios, macos))` reader | |
| dart-hermetic-tests | pass | ci | `strict clock (nts-flr8)` group in `test/api_smoke_test.dart` | |
| native-runtime-read | pass | host | macOS 27.0 (26A428), 2026-09-22: probe suite resolved `provenance=native`, `backend=appleContinuous`, `micros=45383586503`, `generation=1`; 250 ms delay measured as 252534 us | |
| multi-engine | pending | host | | Run the example app with a second engine and record both contexts. |
| bridge-teardown | pending | host | macOS 27.0 (26A428), 2026-09-22: `dispose()` invalidated a live context in the calling engine with `bridgeReset` | Repeat with a second engine live, and record its next read failing too. |
| process-relaunch | pending | host | | Relaunch the app; compare the fresh descriptor with the pre-kill record. Do not compare generations across the boundary. |
| descriptor-compatibility | pending | host | macOS 27.0 (26A428), 2026-09-22: two contexts in one process agreed on `ClockSourceDescriptor(backend: appleContinuous, semanticsVersion: 1, conversionVersion: 1)` | Persist the descriptor across a relaunch on one boot and record the `isCompatibleWith` verdict. |
| suspend-resume | pending | device | | Sleep the Mac for a timed interval; record the coordinate delta against the wall interval. |
| locked-after-first-unlock | n/a | — | macOS has no first-unlock keybag stage of the kind iOS/Android define | |
| rtc-change | pending | device | | Change the system date while the app holds a context; record that the coordinate does not jump. |
| process-death | pending | device | | `kill -9` the app; record that a reference persisted before the kill does not bind in the relaunched process. |
| reboot | pending | device | | Reboot; record that the coordinate resets. |
| uptime-after-boot | pending | device | | Launch immediately after boot; record the first reading. |

## linux

| dimension | status | method | evidence | next-action |
|---|---|---|---|---|
| source-contract | pass | source review | `rust/src/nts/boottime.rs` selects `clock_gettime(CLOCK_BOOTTIME)` for `target_os = "linux"` | |
| compilation | pass | ci | `Rust build + tests + coverage` runs on an Ubuntu runner | |
| rust-unit-tests | pass | ci | `cargo test --lib` on the Ubuntu leg | |
| dart-hermetic-tests | pass | ci | `strict clock (nts-flr8)` group in `test/api_smoke_test.dart` | |
| native-runtime-read | pending | host | | Run the probe suite against a release dylib on a Linux host. |
| multi-engine | pending | host | | Run the example app with a second engine and record both contexts. |
| bridge-teardown | pending | host | | Dispose the bridge from one engine; record the other engine's next read failing. |
| process-relaunch | pending | host | | Relaunch the app; compare the fresh descriptor with the pre-kill record. Do not compare generations across the boundary. |
| descriptor-compatibility | pending | host | | Persist the descriptor across a relaunch on one boot and record the verdict. |
| suspend-resume | pending | device | | Suspend-to-RAM for a timed interval; record the coordinate delta against the wall interval. |
| locked-after-first-unlock | n/a | — | No first-unlock keybag stage on desktop Linux | |
| rtc-change | pending | device | | Step the system clock while the app holds a context; record that the coordinate does not jump. |
| process-death | pending | device | | `kill -9` the app; record that a reference persisted before the kill does not bind in the relaunched process. |
| reboot | pending | device | | Reboot; record that the coordinate resets. |
| uptime-after-boot | pending | device | | Launch immediately after boot; record the first reading. |

## windows

| dimension | status | method | evidence | next-action |
|---|---|---|---|---|
| source-contract | pass | source review | `rust/src/nts/boottime.rs` selects `QueryInterruptTimePrecise` for `target_os = "windows"` | |
| compilation | pending | ci | | Record a Windows build of the crate and the example app. |
| rust-unit-tests | pending | ci | | Run `cargo test --lib` on a Windows runner or host. |
| dart-hermetic-tests | pass | ci | `strict clock (nts-flr8)` group in `test/api_smoke_test.dart` | |
| native-runtime-read | pending | host | | Run the probe suite against a release dylib on a Windows host. |
| multi-engine | pending | host | | Run the example app with a second engine and record both contexts. |
| bridge-teardown | pending | host | | Dispose the bridge from one engine; record the other engine's next read failing. |
| process-relaunch | pending | host | | Relaunch the app; compare the fresh descriptor with the pre-kill record. Do not compare generations across the boundary. |
| descriptor-compatibility | pending | host | | Persist the descriptor across a relaunch on one boot and record the verdict. |
| suspend-resume | pending | device | | Sleep the machine for a timed interval; record the coordinate delta. Note whether `QueryInterruptTimePrecise` includes the sleep. |
| locked-after-first-unlock | n/a | — | No first-unlock keybag stage on Windows | |
| rtc-change | pending | device | | Change the system date while the app holds a context; record that the coordinate does not jump. |
| process-death | pending | device | | `taskkill /F` the app; record that a reference persisted before the kill does not bind in the relaunched process. |
| reboot | pending | device | | Reboot; record that the coordinate resets. |
| uptime-after-boot | pending | device | | Launch immediately after boot; record the first reading. |
