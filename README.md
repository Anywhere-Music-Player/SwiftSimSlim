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
| Slim a stopped simulator | Offline override merge, boot and verify | Same offline approach, with readback verification |
| Fallback service updates | Shell batches; unconfirmed changes retried serially | Up to eight concurrent direct `launchctl` commands |
| Apply an unchanged profile | Boot/readiness handling before checking the profile | Check a booted device first; skip boot and restart |
| Other devices during an operation | Mutation controls share a global busy state | Separate device reservations and progress; two heavy operations at a time |

The comparison refers to [simslim at `4ae1659`](https://github.com/MobAI-App/simslim/tree/4ae1659a0c0265787c2a7047fab466b326ba6d7e). The offline optimization originated upstream; SwiftSimSlim extends it to operations started on a booted device. These scheduling changes can also be implemented in Go.

## How slimming avoids unnecessary work

1. **Check before changing anything.** If a booted simulator already has the requested profile, finish without another boot or restart.
2. **Apply the profile while shut down.** If changes are needed, stop the simulator, merge the managed service overrides in one write, then boot and verify the actual service state. This also works when Slim was started on a running simulator, replacing hundreds of individual service commands with one restart.
3. **Use bounded parallel commands when needed.** The offline override store is an undocumented CoreSimulator detail, so its results are always checked. If the store cannot be written or the runtime does not honor all changes, apply the remaining changes through up to eight concurrent `simctl spawn … launchctl` commands. Retry only failed transitions, then restart and verify persistence.

The fallback does not require a shell inside the simulator. The tested iOS 27 runtime contains `launchctl` but no `/bin/sh`, so shell-based batching cannot be relied on there.

Only allowlisted services are changed. Unmanaged overrides are preserved, and required compatibility services may only be re-enabled.

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
