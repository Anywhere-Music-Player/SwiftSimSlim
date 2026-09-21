# SwiftSimSlim

Native macOS app in Swift 6 and SwiftUI. No Go, bundled CLI, daemon, or helper service. Keep system-command execution in CommandRunner and simulator operations in the in-process backend.

## Build and test

- Use Xcode with the `SwiftSimSlim` scheme and `My Mac`: Cmd-B builds, Cmd-R runs, Cmd-U runs the native `SwiftSimSlimTests` target.
- Prefer the Xcode build/test tools for verification. Keep generated products in Xcode's default DerivedData, outside this repository.
- Do not add Package.swift, build scripts, a local build directory, or CI workflows unless explicitly requested.
- Ordinary unit tests do not mutate real simulators. UI and live simulator acceptance are separate, opt-in checks.
- `swift format lint --strict --recursive SwiftSimSlim SwiftSimSlimTests SwiftSimSlimUITests AcceptanceFixture` checks Swift formatting.
- Xcode uses filesystem-synchronized source folders. Add or move files normally; no project generator is needed.

## Preserve

- Original MIT license, Interlap copyright, and upstream attribution.
- Only allowlisted service labels may change. Required compatibility services may only be enabled.
- Resolve exact UUID and device set before simulator mutations; never accept aliases such as `all`.
- Keep unmanaged offline overrides intact and verify the booted state rather than trusting the private plist format.
- Disk cleanup must retain confirmation, shut down before deleting, stay inside validated simulator data, reject symlink escapes, and protect durable content and shared runtimes.
- Clones must be independent of source paths and hard links. Restore source boot state and delete incomplete clones on preparation failure.
- Long operations must remain off the main actor and report useful progress.
- Report fixture, build, real-runtime, and visual verification separately.
- No Codex co-author trailers or generated footers in commits.
