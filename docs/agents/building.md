# Building and testing

Everything builds with the Command Line Tools alone (`xcode-select --install`). Xcode isn't needed.

## Commands

- **Test:** `scripts/test.sh`. Extra arguments go to `swift test`, for example `scripts/test.sh --filter StatusLine`.
- **Build the app:** `scripts/build-app.sh`. It makes `build/BackMeUp.app`: a universal (arm64 and x86_64) release build for macOS 14+, ad-hoc signed, with no hardened runtime.
- **Check the live Time Machine reading:** `build/BackMeUp.app/Contents/MacOS/BackMeUp --print-status` prints the menu's two status lines and whether Time Machine's preferences could be read, then exits. It never starts a backup.
- **Make a release zip:** `scripts/release.sh 1.2.0` makes `build/release/BackMeUp-1.2.0.zip` with both version fields set to `1.2.0`. `scripts/build-app.sh 1.2.0` sets the version without zipping. `scripts/test-release.sh` tests the release script (slow: a full release build). Agents must never upload, push tags or publish releases; see `docs/releasing.md` for the maintainer's manual step.
- **Run it:** `open build/BackMeUp.app`. It's menu bar-only (`LSUIElement`), so look for the icon in the menu bar, not the Dock. **Running the app starts real Time Machine backups** (`tmutil startbackup`) whenever one is due, and straight away on first launch, so don't run it on a Mac where that isn't wanted.

## Layout

| Path | What's there |
|---|---|
| `Sources/BackMeUpCore` | Everything testable: the System port (`System.swift`), the real adapter (`RealSystem.swift`), output parsers and the `Scheduler` |
| `Sources/BackMeUp` | The menu bar app. Thin: it ticks the scheduler on a timer and draws what it says. The Settings window is plain AppKit |
| `Tests/BackMeUpCoreTests` | Swift Testing tests |
| `Tests/BackMeUpCoreTests/Support` | `FakeSystem` and `SchedulerHarness`, the main test point |
| `Tests/BackMeUpCoreTests/Fixtures` | Saved command output for parser tests. Its README says where each file came from |
| `Packaging/Info.plist` | The bundle's Info.plist, copied in by `build-app.sh`. Its version is a placeholder; releases set it |
| `scripts/` | `test.sh`, `build-app.sh`, `release.sh` and `test-release.sh` |

## Writing tests

- Use **Swift Testing** (`import Testing`, `@Test`, `#expect`). XCTest isn't available with the Command Line Tools.
- Test at two seams only, as the spec says. Behaviour goes through `SchedulerHarness`: script the outside world on its `FakeSystem`, with `harness.at(minutes:)` for changes later on, then `start()` and `advance(minutes:)`, and check what a user would see. Parsers get table tests against saved output in `Fixtures`.
- Backups: `FakeSystem.nextBackup` scripts how the next `startBackup` turns out (exit code, `RESULT`, duration). The fake moves its clock on by the duration, as the real command blocks. `system.startedBackups` lists when each one began. `harness.backUpNow()`, `harness.restart()` (same storage, new scheduler), `harness.quit()` and `harness.changeSettings { }` act as the user would.
- To look at the Mac mid-backup, script `FakeSystem.nextBackup = .lasting(minutes:)`: the backup keeps running while `advance(minutes:)` moves the clock, and the fake reports Time Machine running. `system.powerSource`, `system.backupProgress` and `system.isPreventingIdleSleep` cover power, progress and sleep prevention.
- The scheduler and the System port are `@MainActor`, so mark suites that use the harness `@MainActor`. Values used in `@Test(arguments:)` must then be `nonisolated static`.
- Saved output must contain nothing personal. Replace volume names, IDs, URLs, hostnames, hardware addresses and Wi-Fi names before committing (see `AGENTS.md`).

## Toolchain quirks

- Run tests with `scripts/test.sh`, not bare `swift test`. With the Command Line Tools, the compiler's in-process macro loader fails at random, about one build in four, with `plugin for module 'TestingMacros' not found` on every `@Test`, `@Suite` and `#expect`. The script loads the macros through the out-of-process `swift-plugin-server` instead. Bare `swift test` still works if you retry.
- `swift build --build-system native` can't find the `Testing` module. Use the default build system.
- `ld: warning: search path ... not found` lines during builds are harmless.
- SwiftUI's `@State` (and other SwiftUI macros) can't be used: the Command Line Tools ship no `SwiftUIMacros` plugin. Build windows with AppKit.
