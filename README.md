# SwiftSimSlim

A native macOS app in Swift and SwiftUI for managing and slimming iOS simulators. It calls Apple’s `simctl` directly and shows progress and command logs for each device.

Persistent slimming requires an installed iOS Simulator runtime, version 18.5 or later.

## Why Swift

The interface and simulator logic live in one Xcode project. SwiftUI and Observation drive the interface; Swift concurrency handles command execution, cancellation, and progress. This keeps the app’s interface, simulator operations, and tests together in a single development workflow.

Operations on different simulators can run independently, with separate progress and logs. The app prevents overlapping changes to the same device and limits heavy operations to two devices at a time to avoid overloading CoreSimulator.

Swift does not make Apple’s simulator commands intrinsically faster. The speed improvement comes from changing how those commands are used.

## Compared with simslim

| Area | Original simslim | SwiftSimSlim |
| --- | --- | --- |
| Implementation | SwiftUI interface calling a Go CLI | SwiftUI interface and Swift backend in one Xcode project |
| Slim a booted simulator | Apply service commands, then restart | Stop first, merge overrides, boot and verify |
| Slim a stopped simulator | Offline override merge, boot and verify | Capture and save live original state, then stop, merge, boot and verify |
| Fallback service updates | Shell batches; unconfirmed changes retried serially | Up to eight concurrent direct `launchctl` commands |
| Apply an unchanged profile | Boot/readiness handling before checking the profile | Check a booted device first; skip boot and restart |
| Other devices during an operation | Mutation controls share a global busy state | Separate device reservations and progress; two heavy operations at a time |

The comparison refers to [simslim at `4ae1659`](https://github.com/MobAI-App/simslim/tree/4ae1659a0c0265787c2a7047fab466b326ba6d7e). The offline optimization originated upstream; SwiftSimSlim extends it to operations started on a booted device. These scheduling changes can also be implemented in Go.

## How slimming avoids unnecessary work

1. **Capture and check before changing anything.** The app captures the original live state and saves a recovery point before a changed profile. If a booted simulator already has the requested profile, finish without another boot or restart. A stopped simulator is booted first for a trustworthy original-state capture.
2. **Apply the profile while shut down.** If changes are needed, stop the simulator, merge the managed service overrides in one write, then boot and verify the actual service state. This also works when Slim was started on a running simulator, replacing hundreds of individual service commands with one restart.
3. **Use bounded parallel commands when needed.** The offline override store is an undocumented CoreSimulator detail, so its results are always checked. If the store cannot be written or the runtime does not honor all changes, apply the remaining changes through up to eight concurrent `simctl spawn … launchctl` commands. Retry only failed transitions, then restart and verify persistence.

The fallback does not require a shell inside the simulator. The tested iOS 27 runtime contains `launchctl` but no `/bin/sh`, so shell-based batching cannot be relied on there.

Only allowlisted services are changed. Unmanaged overrides are preserved, and required compatibility services may only be re-enabled.

## Preview, save, export, and restore

Choose **Service State → Preview Service Changes** (also in each simulator’s row menu). Slim and Unslim also show this preview before applying. It lists the exact labels to disable and enable for each selected UUID, including required-service repairs. Closing or refreshing the preview never boots a simulator or changes its services.

A booted device supplies live launchd state. A stopped device supplies an **offline estimate**, clearly labeled as provisional: the private override plist is not proof of runtime behavior. Applying freezes the reviewed profile settings. If a live preview has become stale, the operation stops and asks for a new preview. For an offline preview, actual changes are calculated from live state at apply time.

Before a profile change, the app captures launchd state and atomically saves a JSON recovery point under `~/Library/Application Support/SwiftSimSlim/ServiceBackups/<UUID>.json`. A stopped device is temporarily booted for this capture. If saving fails, service changes do not start. A no-op preserves the existing recovery point. Each subsequent profile change replaces that device’s recovery point, so export it first if you need to keep an older one.

Select one simulator and use **Service State**, or its row menu:

- **Restore Saved State** restores the saved managed-service profile and saved Booted/Shutdown state, with live verification. The snapshot remains available after restoration and app relaunch.
- **Export Saved State…** writes the snapshot as JSON: capture date, exact UUID, device set, runtime, original boot state, and disabled labels. Export is for inspection/archiving; arbitrary JSON import is not supported.
- **Unslim** enables all managed services. It is different from restoring a saved partial profile.

Restoration only touches the current allowlist, always enables required compatibility services, and preserves current unmanaged overrides. Unmanaged labels in the export are informational. The snapshot is not an app-data backup and cannot undo Erase or disk cleanup. Successful Erase/Delete removes that device’s recovery point. Restoration rejects a mismatched UUID, device set, or runtime.

On failure, the original boot state is recovered when possible and the saved service state remains available for explicit restoration. Partially applied service changes are **not automatically rolled back**. Activity reports recovery failures too; inspect the log before retrying.

## Safety and test matrix

Evidence types are separate. Passing synthetic tests does not establish runtime or UI compatibility, and a verified disabled override does not prove every related process has exited.

| Evidence | Environment | Services / checks | Result |
| --- | --- | --- | --- |
| Build and synthetic tests, 2026-09-22 | Apple M1 Pro, 16 GiB; macOS 27.0 (26A428); Xcode 27.0 (27A266a); My Mac | Read-only preview; snapshot persistence/export; stale preview; failed save; cancellation; partial-profile restore; compatibility/unmanaged boundaries; concurrent failure and selective retry | 53 tests passed, 0 failed; live/visual tests are opt-in |
| Service-command benchmark, 2026-09-21 | M1 Pro; Xcode 27.0; isolated iPhone 18 Pro, iOS 27.0 | Same 170 labels; restored state verified after reboot | Historical single-run result below; excludes lifecycle time |
| Visual snapshots, 2026-09-22 | macOS 27.0; synthetic models | Main view at 1500×900 / 1080×700; service preview at 690×640 | Rendered and inspected; does not establish interactive or runtime behavior |
| Live safety attempt, 2026-09-22 | M1 Pro, 16 GiB; macOS 27.0; Xcode 27.0; fresh isolated iPhone 18 Pro / iOS 27.0 | Boot/readiness completed in 101.44 s; fixture installation timed out at 120 s, before profile application | Failed during setup; no before/after memory or apply/restore timing obtained; test device deleted and set verified empty |
| Live follow-up, 2026-09-22 | Same M1 Pro / Xcode 27.0 / iOS 27.0 | Profile and reboot persistence passed, but the fixture crashed before and after Slim because it lacked scene lifecycle support | Failed; memory samples are invalid for performance claims. Fixture now uses scenes and the harness requires app readiness before Slim |
| Live follow-up after fixture changes, 2026-09-22 | Same host/runtime; heavy concurrent host activity | Installation completed; app launch timed out at 120 s before profile changes | Failed during setup; device deleted and set verified empty; full live acceptance remains pending |
| Other Apple Silicon variants; other Xcode/runtime combinations | Not measured for this change | Repeat the same procedure on each combination | No compatibility or speed claim |

To reproduce the optional snapshots, set `SWIFTSIMSLIM_SNAPSHOT_DIR` to an output directory in the Test scheme and run `renderInterfaceSnapshot` / `renderServiceSafetySnapshot` separately from live tests.

The [recorded live attempt](Validation/2026-09-22-safety-matrix.json) preserves the failure and host details. Its `disabledLabels` field is the **requested catalog**, not a claim that those services changed: this attempt stopped before Slim. Current RAM before/after, total apply/restore time, post-profile app launch, and real-runtime saved-state restoration remain unverified. The earlier combined live/visual attempt ended when its test runner exited before completion; its isolated device was also removed.

Follow-up evidence: [fixture-crash run](Validation/2026-09-22-fixture-crash-matrix.json) and [launch-timeout run](Validation/2026-09-22-launch-timeout-matrix.json). The fixture crash also occurred before Slim (`UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption`), so that run does not establish a service regression or valid memory savings. The fixture now adopts scene lifecycle, and the test waits for a new per-launch readiness marker and checks a unique pre-Slim document. The changed fixture builds, but its live acceptance is still pending after the later setup timeout. Further live runs were stopped; ordinary synthetic verification is separate.

The full profile means the full catalog in [ServiceCatalog.swift](SwiftSimSlim/Simulator/ServiceCatalog.swift), not every removable iOS service. The live report records the exact sorted labels rather than relying on a service count that may change between releases. Category memory estimates in the sidebar are not measurements of your current device.

### Reproduce ordinary checks

Open `SwiftSimSlim.xcodeproj`, select **SwiftSimSlim → My Mac**, and run Cmd-B / Cmd-U. The ordinary scheme does not enable live acceptance or screenshots and does not mutate real simulators. Its unit-test host has no main simulator window. Explicit UI test modes display a banner identifying synthetic devices, an intentionally empty list, or an isolated device set. Formatting:

```sh
swift format lint --strict --recursive SwiftSimSlim SwiftSimSlimTests SwiftSimSlimUITests AcceptanceFixture
```

`concurrentProfilesIsolateMidBatchFailureRetryAndSavedRestore` forces the command fallback on two synthetic simulators at once. One label on the first device fails on all three attempts while the second device completes. It checks separate reservations, original snapshots, retry counts (successful transitions run once), UUID-tagged logs, and restoration of only the failed device. This is deterministic fault injection, not a claim of real CoreSimulator failure recovery on every runtime.

### Reproduce the live safety matrix

Use disposable test simulators only. The opt-in test creates its own new device set and never accepts an existing simulator UUID.

1. Build **AcceptanceFixture → Any iOS Simulator Device** in Xcode. Locate `Debug-iphonesimulator/AcceptanceFixture.app` in the project’s default DerivedData products.
2. Switch back to **SwiftSimSlim → My Mac**. In Edit Scheme → Test → Arguments, temporarily add:
   - `SWIFTSIMSLIM_SAFETY_ROOT=/private/tmp/SwiftSimSlim-safety-<new-unique-name>` — the directory must not exist.
   - `SWIFTSIMSLIM_FIXTURE_APP=<absolute path to AcceptanceFixture.app>`.
   - Optionally `SWIFTSIMSLIM_LIVE_RUNTIME` and `SWIFTSIMSLIM_LIVE_DEVICE_TYPE` using exact installed identifiers. Defaults are `com.apple.CoreSimulator.SimRuntime.iOS-27-0` and `com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro`.
3. Run only `isolatedServiceSafetyMatrix` from the Test navigator, separately from builds and visual tests. Fixture installation has a 300-second deadline to allow first-boot installation work to finish. It installs the scene-based fixture, waits for a fresh readiness marker from each app launch, writes a unique durable document before Slim, waits 10 seconds before each memory sample, applies the full catalog through the same backup path used by the app, verifies after another reboot, launches the app again, checks its document, restores saved state, and repeats capture/apply/restore from Shutdown.
4. Read `safety-matrix.json`, `original-state.json`, and `operations.log` in the supplied root. The operation log is written while the test runs, so it also survives an interrupted runner. Keep the `.xcresult` alongside the reports; test assertions determine pass/fail. The report includes Xcode/macOS/chip/RAM, labels, process counts, memory before/after, complete apply/restore times, and cleanup results.
5. Remove the temporary scheme environment variables afterward. Each rerun needs a new root. The test deletes its own device even after a thrown error. If the runner is interrupted, `created-uuid.txt` identifies the only cleanup target; use that exact UUID with `simctl --set <root>/Devices`, never `all` or the default device set.

Memory is the app’s sum of `top MEM` values for the simulator launchd process tree, not host-wide RAM saved. Both samples use the same fixture app and settling interval. Repeat runs and report sample spread before making performance claims. App launch and retained documents do not cover share-sheet interaction, location, StoreKit, notifications, or every application workflow; validate the functions your chosen profile needs separately.

### Read the timings and logs

Command Details / Copy Log includes device name, UUID, and operation ID. `PLANNED`, `SAVED`, `APPLIED`, `FAILED`, retry stages, `VERIFIED`, and `RESTORED` distinguish requested transitions, command outcomes, final state, and recovery. Boot-state recovery is explicitly separate from service restoration. The interface retains the latest 10,000 log entries; the live test writes its full trace.

`TIMING operation-total` measures from reservation through queue wait, execution, and its status refresh request (including refresh work when performed by that operation). `TIMING profile-total` includes original-state capture, backup, profile changes, shutdown, boot/readiness, verification, and recovery when attempted. It excludes queue wait, preview, and the later UI refresh. Separate records show `shutdown`, `boot-and-readiness`, `offline-override-write`, and `service-state-read`. `service-commands-only` includes retries but excludes the restart and final verification. Phase timings are nested observations; do not add them to the total. A timing emitted on failure measures the attempted operation, not successful completion.

## Measured service-update time

Measured on September 21, 2026: Apple M1 Pro, 16 GB RAM, macOS 27.0, Xcode 27.0, and two newly created, isolated iPhone 18 Pro simulators with iOS 27.0. Both implementations used the same 170 service labels.

**Simulator startup, shutdown, restart, preparation, and final verification are excluded.** This compares the service-command phase, not total time after clicking Restore.

| Operation on an already booted, slim simulator | Original simslim | SwiftSimSlim |
| --- | ---: | ---: |
| Re-enable the same 170 services | approximately 144 s | 24.3 s |

The original measurement runs from its “Re-enabling 170 background services” message to “Rebooting the simulator”, using log timestamps with one-second resolution. Its shell batches confirmed no changes, so all 170 services went through the sequential retry pass. The Swift measurement times `applyServiceChanges` directly, using eight concurrent commands. Both completed, and the restored service state was verified after reboot outside the timer.

This deliberately exercises SwiftSimSlim’s command fallback. Normal profile changes first try the offline merge described above and can avoid those 170 commands entirely. The difference comes from command scheduling and avoiding failed shell batches, not from Swift executing faster than Go.

These are individual local observations, not averages or guaranteed speedups. Mac workload and CoreSimulator response times still affect the commands themselves. Only newly created test simulators were used, and they were deleted afterward.

## Why a simulator can finish in Shutdown

**Preserve current boot state** is enabled by default. Slim temporarily boots a stopped simulator to verify the profile, then returns it to its original state:

| State when the operation starts | Preserve current boot state | State after successful Slim or restore |
| --- | --- | --- |
| Booted | On or off | Booted |
| Shutdown | On | Shutdown |
| Shutdown | Off | Booted |

Turn this option off before applying a profile if you want a stopped simulator to remain booted afterward. Returning to Shutdown does not undo slimming: the verified service overrides persist for the next boot. A simulator that started booted should remain booted after a successful operation; a failure or cancellation can interrupt that sequence and is reported in Activity.

## Origin and license

Based on [simslim by Interlap / MobAI](https://github.com/MobAI-App/simslim), source snapshot `4ae1659a0c0265787c2a7047fab466b326ba6d7e`. The initial interface, service catalog, and simulator-management behavior were adapted into this independent Swift app.

Distributed under the [MIT license](LICENSE). The original **Copyright (c) 2026 Interlap** notice is retained; LICENSE is also included in the app bundle.
