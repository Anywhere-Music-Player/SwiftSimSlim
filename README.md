# SwiftSimSlim

A native macOS app in Swift and SwiftUI for managing and slimming iOS simulators. Calls Apple’s `simctl` directly, with per-device progress and command logs. No Go or helper service.

## Run

Open `SwiftSimSlim.xcodeproj` and select **SimSlim → My Mac**.

- **⌘R** — run the app.
- **⌘B** — build.
- **⌘U** — run unit tests without modifying real simulators.

Xcode stores build products in its standard DerivedData directory. Install an iOS Simulator runtime in Xcode to manage simulators. Persistent slimming requires iOS 18.5 or later.

## Origin and license

Based on [simslim by Interlap / MobAI](https://github.com/MobAI-App/simslim), source snapshot `4ae1659a0c0265787c2a7047fab466b326ba6d7e`. The initial interface, service catalog, and simulator-management behavior were adapted into this independent Swift app.

Distributed under the [MIT license](LICENSE). The original **Copyright (c) 2026 Interlap** notice is retained; LICENSE is also included in the app bundle.
