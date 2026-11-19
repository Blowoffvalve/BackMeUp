# How BackMeUp works

A short tour for contributors. The full spec, with the reasons behind each decision, is [issue #1](https://github.com/Blowoffvalve/BackMeUp/issues/1). For building, testing and toolchain quirks see [agents/building.md](agents/building.md); for releases see [releasing.md](releasing.md).

## Shape

Two targets:

- **`BackMeUpCore`**: all the logic, and everything that talks to macOS. Testable.
- **`BackMeUp`**: the menu bar app. Thin AppKit (SwiftUI macros aren't available with the Command Line Tools). A 60-second timer ticks the scheduler, and the menu, checklist and Settings windows draw what it says. `AppUpdater` wraps Sparkle and is the only code that links it.

The `Scheduler` is the core. Everything outside the app goes through the **System port**, so the scheduler can run against a fake over simulated time.

## The scheduler

`Scheduler.tick()` runs once a minute. Each tick it:

1. reads Time Machine's status, the current network and, while a backup runs, its progress
2. on first run or the first launch after an update, adds BackMeUp to Login Items
3. re-reads the six checklist checks and asks for the checklist window if a check has newly stopped passing
4. asks once per network whether to allow a new network (see Networks)
5. holds or releases sleep prevention
6. starts a backup if one is due and none is running, BackMeUp's or Time Machine's own
7. checks alerts and updates the menu's lines

**When a backup is due:** the backup interval (hours, days or weeks) after the last success, or straight away if there's never been one. After a failure, skip or pause, no sooner than the retry interval (minimum 15 minutes) after that attempt. Two shortcuts skip the retry wait when a backup is already due by the interval: the Mac comes back to a chosen network after a network skip, or the checklist starts allowing backups after a setup skip.

**Running an attempt** (`runAttempt`), in order, each step able to end it as a skip:

1. the checklist gate (see below), which applies to Back Up Now too
2. the battery rule: on battery with battery backups off. Back Up Now ignores it
3. the disk: no disk set up, or a local disk that isn't mounted
4. the network rule, for network disks and for a disk whose kind can't be read, never for a local disk
5. then `tmutil startbackup --auto --block`, judged by the success rule

Skips never count as failures. Each attempt is recorded in `BackupHistory` with its outcome: succeeded, failed (with a reason), skipped (with a reason) or paused. History keeps the last 200 attempts, plus a running tally since the last success (`SinceLastSuccess`) so alert counts stay right however many attempts are dropped.

**Sleep prevention:** an IOKit assertion stops idle sleep only while BackMeUp's backup command runs on AC power. A power-source watcher releases it the moment the Mac is unplugged, without waiting for the next tick.

## The System port

`System.swift` is one protocol, `@MainActor`, covering: the clock; Time Machine status, progress, destination and preferences; starting a backup; network identity; power source and sleep prevention; notifications and notification permission; the login item; opening System Settings; the app version; ntfy; the log; the Keychain; and `UserDefaults` storage.

**The real adapter, `RealSystem`** (split across `RealSystem*.swift`):

- Runs `/usr/bin/tmutil status -X`, `tmutil destinationinfo -X`, `tmutil startbackup --auto --block` and `/usr/bin/defaults read /Library/Preferences/com.apple.TimeMachine` as subprocesses. `defaults` can read that file without Full Disk Access; reading the plist directly can't.
- Network identity: the first default route on a physical interface from `netstat -rn -f inet` (VPN and tunnel interfaces such as `utun` never count), then the router's hardware address from SystemConfiguration's `State:/Network/Service/*/IPv4`, falling back to `arp -an`. Nothing is sent on the network. The Wi-Fi name comes from CoreWLAN, only with Location permission, and is used only as a label.
- `UserNotifications` for Mac notifications, `SMAppService.mainApp` for the login item, `x-apple.systempreferences:` links for System Settings, `URLSession` for ntfy, the Keychain for the ntfy topic and token, and a plain-text log at `~/Library/Logs/BackMeUp/BackMeUp.log`.

The output parsers (`DestinationInfo`, `TimeMachinePreferences`, `TimeMachineStatus`, `BackupProgress`, `NetworkTables`) are pure. None of these formats is documented by Apple, so a missing or unexpected key reads as "can't tell", never as success.

**`UninstallableSystem`** wraps the port inside the scheduler. After Uninstall… it drops every save, backup start, notification and ntfy send, so nothing can undo the uninstall while the reminder shows. New save paths need no guard of their own.

**The fake and the harness** (`Tests/BackMeUpCoreTests/Support`): `FakeSystem` returns scripted states and records what it's asked to do (backups started, notifications, ntfy messages, log lines, Settings links opened). `SchedulerHarness` runs the real `Scheduler` against it, moving a simulated clock one tick at a time and applying scripted changes on the way. See [agents/building.md](agents/building.md) for how to use them.

## The success rule

A finished backup counts as a success only if all three hold (`BackupVerdict`):

1. `tmutil startbackup` exited 0
2. the destination's `RESULT` in Time Machine's preferences is 0
3. the destination's newest `SnapshotDates` entry is newer than it was before the backup started (or there was none before)

`tmutil` has been seen exiting 0 for a cancelled backup, and `RESULT` doesn't say which backup it belongs to, hence rule 3. Anything else is a failure with a reason: couldn't start, a non-zero exit code, a non-zero `RESULT`, an unreadable `RESULT`, or "couldn't tell whether Time Machine finished" (`RESULT` 0 but no new snapshot). If the preferences couldn't be read before the backup, it can't be confirmed either.

A non-zero `RESULT` gets a reason of its own only when its meaning has been seen. So far that's `RESULT` 26, which Time Machine's log names `BACKUP_FAILED_DISCONNECTED_NETWORK`: "the backup disk couldn't be reached" (`FailureReason.diskUnreachable`). It was seen with `tmutil startbackup` exiting 0 after about a second, having copied nothing, for a network share Time Machine held a stale mount record for; restarting the Mac fixed it. For a network disk, alerts add a hint to check the network and restart the Mac. Every other code stays "Time Machine reported error N".

## First-backup handling

Until the first success is recorded, a backup that stops without Time Machine reporting an error is **paused**, not failed: a non-zero exit code with no non-zero `RESULT`, an unreadable `RESULT`, or no new snapshot. A non-zero `RESULT`, or `tmutil` failing to run at all, is still a failure. Paused attempts never trigger the failure alert and retry at the retry interval. The menu says "First backup paused" and "Resumes: …".

The overdue alert still applies: before the first success, days are counted from when BackMeUp first ran (`monitoringSince`), and an overdue alert with only pauses says "First backup not finished".

After the first success, if ntfy is set up, a one-time "First backup finished" message goes to the phone. A failed send is retried after the next attempt.

## Alert rules

`AlertPolicy` decides from the history and the alert settings alone:

- **Failure alert:** failures since the last success reach `failuresInARow` (default 1). Skips and pauses neither count nor break the run.
- **Overdue alert:** no success for `daysWithoutBackup` days (default 3). It names the main reason: the most frequent skip reason since the last success (the most recent on a tie) with the day it started ("since Friday"), unless failures outnumber skips. Titles: "Backups skipped", "Backup failed" / "Backups failed", "First backup not finished" or "Backups overdue".
- **Repeats:** at most once every 24 hours while the problem lasts.
- **Working again:** the first success after an alert sends "Backups are working again" and clears the problem.

Every alert goes out as a Mac notification and, when a topic is set, an ntfy POST with `Title` and `Tags` headers and an optional bearer token. The menu bar icon shows a problem whenever the policy has one, whether or not an alert was just sent.

One extra notification, Mac only: when a network disk is mounted on a network that isn't chosen and other networks are, BackMeUp asks once per network, "Back up on this network?" (for a new router).

## Networks

Chosen networks are stored by router hardware address, with a label (the Wi-Fi name, or a name the user types). The address is never shown in the interface or written to the log. Recognising a router by its address is a convenience to keep backups off networks the user hasn't chosen, not a security measure. No physical default route counts as not on a chosen network; a route whose router address can't be read yet is "couldn't identify this network". "All networks" turns the rule off.

## The checklist gate

`Checklist` evaluates six checks in order: (1) a disk is set up, (2) Time Machine's automatic backups are off, (3) the disk is encrypted, (4) BackMeUp opens at login, (5) notifications are allowed, (6) for a network disk, a chosen network or "all networks". Each item has a state (passed, failed, warning, can't tell, or not needed), one plain sentence and a button.

Backups, including Back Up Now, run only while 1, 2 and 6 are passed or not needed. "Can't tell" counts as not passing, so if Time Machine's destination or preferences can't be read, backups wait. Check 3 is only ever a warning. A gated attempt is recorded as a skip ("no Time Machine disk set up" or "setup isn't finished").

The window opens on first launch, at any launch with 1, 2 or 6 not done, after an update that left BackMeUp out of Login Items, and whenever a check newly stops passing. If a System Settings link fails to open, the item shows plain-text directions instead.

## Testing

Tests check only what a user could see: which backups start, which alerts go out and what they say, and what the menu and checklist show. They never check the scheduler's internals. There are two test points:

1. **The System port.** Behaviour tests script `FakeSystem` and drive the real scheduler through `SchedulerHarness` over simulated time: scheduling and retries, network and battery rules, failure and skip counting, alert wording and limits, first-backup handling, checklist gating, the success rule, sleep prevention, updates, uninstall and the status lines.
2. **The output parsers.** Table tests against saved real command output in `Tests/BackMeUpCoreTests/Fixtures`, with personal values replaced. Its README says where each file came from, and which are reconstructed rather than captured.

Tests use Swift Testing and run with `scripts/test.sh`. They never send real HTTP requests, touch the real log or start a real backup. What can't be automated (login items across Sparkle updates, System Settings links, whether Time Machine's keys still mean what we think, the Open Anyway guide) is checked by hand on real installs, as listed in the spec.
