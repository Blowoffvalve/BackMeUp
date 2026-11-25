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
7. checks alerts and updates the menu's lines, including the backup strip (`BackupStripText`): a dot per recent hour, day or week (the backup interval's unit) saying whether it was backed up, failed, was skipped or had nothing due, with a hover caption saying why, and how much a backup copied when BackMeUp watched it finish ("backed up 09:14, 3.2 GB copied")

**When a backup is due:** the backup interval (hours, days or weeks) after the last success, or straight away if there's never been one. After a failure, skip or pause, no sooner than the retry interval (minimum 15 minutes) after that attempt. Three shortcuts skip the retry wait when a backup is already due by the interval: the Mac comes back to a chosen network after a network skip, the checklist starts allowing backups after a setup skip, or another disk's backup ends after Back Up Now was skipped for it.

**Running an attempt** (`runAttempt`), in order, each step able to end it as a skip:

1. the checklist gate (see below), which applies to Back Up Now too
2. Time Machine backing up to another disk than the chosen one (only Back Up Now gets this far; scheduled backups wait for it)
3. the battery rule: on battery with battery backups off. Back Up Now ignores it
4. the disk: no disk set up, or a local disk that isn't mounted
5. the network rule, for network disks and for a disk whose kind can't be read, never for a local disk
6. then `tmutil startbackup --auto --block` (with `--destination <ID>` for a disk chosen from several), judged by the success rule. If Time Machine's `RESULT` is 18 (it couldn't reach the network disk, for example just after login while a VPN is still starting) and there's no new snapshot, the attempt is a skip ("network backup disk not reachable"), not a failure

Skips never count as failures. Each attempt is recorded in `BackupHistory` with its outcome: succeeded, failed (with a reason), skipped (with a reason) or paused. History keeps every attempt from the last 12 weeks (as far back as the backup strip goes), at most 3,000, plus a running tally since the last success (`SinceLastSuccess`) so alert counts stay right however many attempts are dropped.

**Backup sizes:** while a backup to the chosen disk is copying, whoever started it, the scheduler keeps the last total Time Machine gives (`totalBytes` in `tmutil status -X`; bytes copied aren't used, because Time Machine's percent isn't their ratio). When BackMeUp's own backup succeeds, the total is stored in `BackupHistory.sizes` twice: with the attempt's finish time and with the snapshot date Time Machine gave the new backup. Both times can be a dot's, and they can be hours apart: the snapshot date may be when the backup began (unconfirmed; the saved `defaults` fixture has its dates rewritten). When a backup Time Machine started itself ends and a newer backup has appeared on the chosen disk since the first checklist reading after BackMeUp saw it copying, it's stored with that backup's snapshot date; with none, it was stopped or failed and nothing is kept. Waiting for that reading matters when BackMeUp launches mid-backup: its first progress reading comes before it knows the disk's backups. A failed or paused attempt keeps nothing, so a resumed first backup shows only the finishing run's total. Nothing is noted for a backup Time Machine says went to another disk. Sizes are trimmed to 12 weeks like attempts. A backed-up dot shows the size noted at its time, within a second for rounding (`BackupStripText.sizeMatchWindow`). Because every time a dot can show has its own entry, matching doesn't depend on how far apart the two times are, and a backup with no size never takes a neighbour's. Dots with no size noted keep their plain caption.

**Several Time Machine disks:** `DestinationInfo` lists every disk. With two or more and none chosen, BackMeUp always asks: check 1 fails with a "Back up to" pop-up (also in Settings) and attempts skip with "setup isn't finished". The chosen disk's `ID` is saved as `BackupSettings.destinationID`, and checks 1, 3 and 6, the network rule, the success rule and the `--destination` all follow it. `DiskChoiceState` owns the rules for changing the choice; the scheduler applies each change and saves it.

- **A disk is added:** while there's one disk BackMeUp saves it as the last-used disk (`SetupState.lastUsedDiskID`) at each backup, so when a second disk appears, now or while BackMeUp was quit, that disk is kept as the choice, without an alert, and check 1 says "Time Machine has a new disk. BackMeUp still backs up to <name>." until the user chooses (saved, so it survives restarts). Versions before this never saved the last-used disk, so the first launch after that update with several disks and none chosen asks instead, with the alert below.
- **The chosen disk is removed:** the choice is cleared and logged, backups pause and check 1 asks ("The disk you chose is no longer in Time Machine…"), even with one disk left; it never falls back to an earlier disk. `SetupState.chosenDiskRemoved` keeps this across restarts. Choosing the one disk left still passes `--destination`. With no disk left, check 1 says "Set up a Time Machine disk" instead and no alert is sent.
- **Another disk's backup:** while Time Machine backs up to a disk other than the chosen one (started from its own menu), scheduled backups wait for it, its progress isn't shown and the menu says so, following its stage ("Time Machine is backing up to another disk" while copying; see the status line below). Back Up Now during it is skipped with that reason; a backup due by the interval starts as soon as it ends.
- **Already backing up to the disk:** when Time Machine is already backing up to the chosen disk (Back Up Now during it, or Time Machine starting its own backup just before BackMeUp's), BackMeUp starts nothing and records nothing: not a failure, a skip or a success. The log says "Backup not started: Time Machine is already backing up to the disk". `tmutil startbackup` gives up at once then, with exit code 3 ("Backup already in progress."), and Time Machine's `RESULT` is still the previous backup's, so it must not be read as this backup's result.

An unreadable `destinationinfo` changes nothing.

**Sleep prevention:** an IOKit assertion stops idle sleep only while BackMeUp's backup command runs on AC power. A power-source watcher releases it the moment the Mac is unplugged, without waiting for the next tick. Separately, Time Machine itself holds the Mac awake for the whole of any backup, on AC power and on battery, whoever started it; only closing the lid stops it. So while a backup runs, to the chosen disk or another, the menu shows a note under its first line saying the Mac will stay awake until the backup finishes and not to close the lid.

**Status line while backing up:** the menu's first line follows the stage Time Machine reports (`BackupPhase` in `tmutil status -X`), in BackMeUp's own words but never claiming more than Time Machine does. `TimeMachineStatus.stage` groups the stage name by how it starts:

| Stage | Chosen disk | First backup | Another disk |
|---|---|---|---|
| Getting ready: `Starting…`, `Mounting…`, `HealthCheck…`, `Calculating…`, `Finding…`, `Preparing…`; or a backup BackMeUp started, before Time Machine reports it running | Getting ready to back up | Getting ready for first backup | Time Machine is getting ready to back up to another disk |
| `Copying`, percent known | Backing up: 4.5% of 251.55 GB, about 3 hours left | First backup: 4.5% of 251.55 GB, about 3 hours left | Time Machine is backing up to another disk |
| `Copying`, no percent yet | Backing up | First backup | Time Machine is backing up to another disk |
| `Thinning…` | Time Machine is cleaning up old backups | same | Time Machine is cleaning up another disk |
| Running, with any other name or none (BackMeUp's own backups too) | Time Machine is working on a backup | Time Machine is working on the first backup | Time Machine is working on another disk |

"First backup" shows until a backup has succeeded. The percent, total and time left show only while copying, once Time Machine gives them; without a total the line is "Backing up: 4.5%, …". The total is in decimal units as Finder shows them. The current dot's caption shows the same figure: "Thu 1 Jan: backing up: 4.5% of 251.55 GB". Each change of stage name is logged as `Phase: <old> -> <new>` ("none" for no name), so names the table doesn't cover yet show up in the log.

## The System port

`System.swift` is one protocol, `@MainActor`, covering: the clock; Time Machine status, progress, destination and preferences; starting a backup; network identity; power source and sleep prevention; notifications and notification permission; the login item; opening System Settings; the app version; ntfy; the log; the Keychain; and `UserDefaults` storage.

**The real adapter, `RealSystem`** (split across `RealSystem*.swift`):

- Runs `/usr/bin/tmutil status -X`, `tmutil destinationinfo -X`, `tmutil startbackup --auto --block [--destination <ID>]` and `/usr/bin/defaults read /Library/Preferences/com.apple.TimeMachine` as subprocesses. `defaults` can read that file without Full Disk Access; reading the plist directly can't.
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
- **Repeats:** no time limit. While the problem lasts, the failure alert is sent again for every further failed backup, and the overdue alert each time its day count goes up. Ticks between attempts send nothing new, and neither does a restart.
- **Stuck Time Machine:** when the latest backup failed with `FailureReason.timeMachineStuck`, the alert is "Time Machine is stuck" (or "Restarting didn't fix Time Machine" after a restart), sent on the first one whatever `failuresInARow` says, since it doesn't clear by itself.
- **Troubleshoot's cause:** when Troubleshoot, run after the failure, finds the network or the server at fault, the failure alert and the status line give its sentence instead of the failure's own explanation.
- **Working again:** the first success after an alert sends "Backups are working again" and clears the problem; "Fixed: backing up again" when Time Machine had been stuck.

Every alert goes out as a Mac notification and, when a topic is set, an ntfy POST with `Title` and `Tags` headers and an optional bearer token. The menu bar icon shows a problem whenever the policy has one, whether or not an alert was just sent.

**Choose a backup disk** (`.chooseDisk`): a Mac notification and ntfy (warning tag), sent once when the chosen disk is removed with at least one disk left, and once at the first launch after an update when Time Machine has several disks and none is chosen. Not when a disk is added, and not when the disks can't be read. It isn't repeated: if backups stay paused, the overdue alert covers it.

One extra notification, Mac only: when a network disk is mounted on a network that isn't chosen and other networks are, BackMeUp asks once per network, "Back up on this network?" (for a new router).

## Troubleshoot

`Scheduler.troubleshoot()` runs three checks into a `TroubleshootReport`: the network rules (`NetworkSettings.skipReason`), whether the network disk's server answers on port 445 (`System.serverAnswers`, `nc -z -G 5`; the host comes from the `URL` in `tmutil destinationinfo -X`), and whether Time Machine is stuck (from `BackupHistory.stuck`). It runs after every failed backup and from the menu, and never starts a backup. The window shows the first failed check's steps, then every check. `troubleshootDetails` is the Copy Details text, which names no host, network or address.

**Stuck Time Machine.** Seen on macOS 27.2: `backupd` kept believing a network disk image was mounted after the SMB mount under it was gone, so every backup failed with `RESULT` 26 within milliseconds, without reconnecting, for over a day. `sudo killall backupd` didn't replace the process; a restart fixed it. A failed backup is `timeMachineStuck` when all of these hold: `RESULT` 26 on a network disk, `tmutil startbackup --block` returned within `stuckFailureSeconds` (10), the server answers, and `System.timeMachineLostItsMount` doesn't say no. That reads `backupd`'s lines in the unified log for the attempt (`log show`, as an ordinary user) for "no volume mounted at this path"; if the log can't be read, the other signs are enough.

`BackupHistory.stuck` (`StuckRecord`) holds when it started and the Mac's start-up time (`kern.boottime`, `System.bootTime`). At the first tick after launch, if the start-up time has changed, the next backup is set for 5 minutes later (`backupAfterRestartDelay`), under the usual rules, and nothing starts before then. A success clears the record and sends "Fixed: backing up again". Stuck again after a restart sets `restartDidNotHelp`, and the alert and the window ask for Copy Details instead of another restart. Reopening BackMeUp without a restart changes nothing.

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
