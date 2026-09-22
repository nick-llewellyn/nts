# Strict clock evidence matrix (NTS-180)

Machine-checked record of what has actually been observed for the
strict clock (`lib/src/api/strict_clock.dart`,
`rust/src/nts/boottime.rs`) on each supported platform. Validated by
`dart run tool/clock_evidence/check_evidence_matrix.dart`.

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
| `rust-unit-tests` | `cargo test --lib` passes for this target's reader paths. |
| `dart-hermetic-tests` | The mock-bridge strict-clock suite passes. |
| `native-runtime-read` | A `StrictClockContext` resolved with `StrictClockProvenance.native` returned a reading on the expected backend, on real hardware. |
| `multi-engine` | Two live Flutter engines in one process each hold a valid context, and a fault in one is observed by the other. |
| `bridge-teardown` | `NtsBridge.dispose()` invalidates contexts in every engine of the process. |
| `process-relaunch` | After process death and relaunch, a fresh context resolves and old persisted generations are refused. |
| `descriptor-compatibility` | The descriptor is stable across relaunch on one boot and its `isCompatibleWith` verdict matches the observed coordinate. |
| `suspend-resume` | Readings advance across a real device suspend/resume by the wall duration of the suspend. |
| `locked-after-first-unlock` | Reads keep working while the device is locked after first unlock. |
| `rtc-change` | A wall-clock/RTC change does not move the coordinate. |
| `process-death` | An OS-initiated process kill invalidates nothing silently: the relaunched process refuses stale coordinates. |
| `reboot` | The coordinate resets across reboot and no same-boot claim survives it. |
| `uptime-after-boot` | Immediately after boot the reader returns a small, non-negative value rather than a fault. |

## android

| dimension | status | method | evidence | next-action |
|---|---|---|---|---|
| source-contract | pass | source review | `rust/src/nts/boottime.rs` selects `clock_gettime(CLOCK_BOOTTIME)` for `target_os = "android"` | |
| compilation | pass | ci | `Rust build + tests + coverage` plus the Android KGP gate matrix build the crate for Android targets | |
| rust-unit-tests | pass | ci | `cargo test --lib` covers the Linux/Android reader through `with_raw_override` | |
| dart-hermetic-tests | pass | ci | `strict clock (nts-flr8)` group in `test/api_smoke_test.dart` | |
| native-runtime-read | pending | device | | Run `tool/clock_evidence/native_lifecycle_probe_test.dart` on a physical Android device. |
| multi-engine | pending | device | | Add a second engine to the example app and record both contexts' provenance, descriptor and generation. |
| bridge-teardown | pending | device | | Dispose the bridge from one engine; record the other engine's next read failing with `bridgeReset`/`nativeGeneration`. |
| process-relaunch | pending | device | | Force-stop the example app, relaunch, compare descriptor and generation with the pre-kill record. |
| descriptor-compatibility | pending | device | | Persist the descriptor across a relaunch on one boot and record the `isCompatibleWith` verdict. |
| suspend-resume | pending | device | | Suspend the device for a timed interval; record the coordinate delta against the wall interval. |
| locked-after-first-unlock | pending | device | | Read from a foreground service while the device is locked after first unlock. |
| rtc-change | pending | device | | Change the system date while the app holds a context; record that the coordinate does not jump. |
| process-death | pending | device | | Kill the process from the OS; record the relaunched process refusing the stale coordinate. |
| reboot | pending | device | | Reboot; record that the coordinate resets and no same-boot claim survives. |
| uptime-after-boot | pending | device | | Launch immediately after boot; record the first reading. |

## ios

| dimension | status | method | evidence | next-action |
|---|---|---|---|---|
| source-contract | pass | source review | `rust/src/nts/boottime.rs` selects `mach_continuous_time` scaled by `mach_timebase_info` for Apple targets | |
| compilation | pending | ci | | Record an iOS device build of the example app against the current crate. |
| rust-unit-tests | pass | ci | `cargo test --lib` covers the Apple reader through `with_raw_override` on the macOS leg | |
| dart-hermetic-tests | pass | ci | `strict clock (nts-flr8)` group in `test/api_smoke_test.dart` | |
| native-runtime-read | pending | device | | Run the probe suite on a physical iPhone. |
| multi-engine | pending | device | | Add a second engine to the example app and record both contexts' provenance, descriptor and generation. |
| bridge-teardown | pending | device | | Dispose the bridge from one engine; record the other engine's next read failing. |
| process-relaunch | pending | device | | Kill and relaunch the app; compare descriptor and generation with the pre-kill record. |
| descriptor-compatibility | pending | device | | Persist the descriptor across a relaunch on one boot and record the `isCompatibleWith` verdict. |
| suspend-resume | pending | device | | Background and suspend the device for a timed interval; record the coordinate delta. |
| locked-after-first-unlock | pending | device | | Read from a background task while the device is locked after first unlock. |
| rtc-change | pending | device | | Change the system date while the app holds a context; record that the coordinate does not jump. |
| process-death | pending | device | | Let the OS jetsam the app; record the relaunched process refusing the stale coordinate. |
| reboot | pending | device | | Reboot; record that the coordinate resets and no same-boot claim survives. |
| uptime-after-boot | pending | device | | Launch immediately after boot, before first unlock where possible; record the first reading. |

## macos

| dimension | status | method | evidence | next-action |
|---|---|---|---|---|
| source-contract | pass | source review | Same Apple branch as iOS in `rust/src/nts/boottime.rs` | |
| compilation | pass | ci | `Rust build + tests + coverage` runs on a macOS runner | |
| rust-unit-tests | pass | ci | `cargo test --lib` on the macOS leg | |
| dart-hermetic-tests | pass | ci | `strict clock (nts-flr8)` group in `test/api_smoke_test.dart` | |
| native-runtime-read | pass | host | macOS 27.0 (26A428), 2026-09-22: probe suite resolved `provenance=native`, `backend=appleContinuous`, `micros=45383586503`, `generation=1`; 250 ms delay measured as 252534 us | |
| multi-engine | pending | host | | Run the example app with a second engine and record both contexts. |
| bridge-teardown | pending | host | macOS 27.0 (26A428), 2026-09-22: `dispose()` invalidated a live context in the calling engine with `bridgeReset` | Repeat with a second engine live, and record its next read failing too. |
| process-relaunch | pending | host | | Relaunch the app; compare descriptor and generation with the pre-kill record. |
| descriptor-compatibility | pending | host | macOS 27.0 (26A428), 2026-09-22: two contexts in one process agreed on descriptor and generation | Persist the descriptor across a relaunch on one boot and record the verdict. |
| suspend-resume | pending | device | | Sleep the Mac for a timed interval; record the coordinate delta against the wall interval. |
| locked-after-first-unlock | n/a | — | macOS has no first-unlock keybag stage of the kind iOS/Android define | |
| rtc-change | pending | device | | Change the system date while the app holds a context; record that the coordinate does not jump. |
| process-death | pending | device | | `kill -9` the app; record the relaunched process refusing the stale coordinate. |
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
| process-relaunch | pending | host | | Relaunch the app; compare descriptor and generation with the pre-kill record. |
| descriptor-compatibility | pending | host | | Persist the descriptor across a relaunch on one boot and record the verdict. |
| suspend-resume | pending | device | | Suspend-to-RAM for a timed interval; record the coordinate delta against the wall interval. |
| locked-after-first-unlock | n/a | — | No first-unlock keybag stage on desktop Linux | |
| rtc-change | pending | device | | Step the system clock while the app holds a context; record that the coordinate does not jump. |
| process-death | pending | device | | `kill -9` the app; record the relaunched process refusing the stale coordinate. |
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
| process-relaunch | pending | host | | Relaunch the app; compare descriptor and generation with the pre-kill record. |
| descriptor-compatibility | pending | host | | Persist the descriptor across a relaunch on one boot and record the verdict. |
| suspend-resume | pending | device | | Sleep the machine for a timed interval; record the coordinate delta. Note whether `QueryInterruptTimePrecise` includes the sleep. |
| locked-after-first-unlock | n/a | — | No first-unlock keybag stage on Windows | |
| rtc-change | pending | device | | Change the system date while the app holds a context; record that the coordinate does not jump. |
| process-death | pending | device | | `taskkill /F` the app; record the relaunched process refusing the stale coordinate. |
| reboot | pending | device | | Reboot; record that the coordinate resets. |
| uptime-after-boot | pending | device | | Launch immediately after boot; record the first reading. |
