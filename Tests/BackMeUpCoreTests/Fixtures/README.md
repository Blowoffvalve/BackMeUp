# Fixtures

Saved output of the commands BackMeUp runs, for parser tests. None of these formats is documented by Apple.

Personal values are replaced: destination IDs become `00000000-0000-0000-0000-00000000000N`, the network URL becomes `smb://backup-user@backup-server/TimeMachine`, volume names become `TimeMachine` or `Backup Disk`, the mounted backup volume becomes `Backups of Example Mac`, and dates become 2026-01-01.

In `defaults-timemachine-*.txt`, other UUIDs become `00000000-0000-0000-0000-0000000000NN` too, the network URL user, host and share are replaced as above, dates move into 2026-01-01 to 03 and the snapshot list is shortened. The `BackupAlias` data value keeps the shape `defaults` prints (first and last few bytes) but its bytes are zeroed.

| File | Command | Source |
|---|---|---|
| `status-idle.plist` | `tmutil status -X` | Real, macOS 27.2, no backup running |
| `status-running-mounting.plist` | `tmutil status -X` | Real, macOS 27.2, early in a backup to a network disk (`BackupPhase` `MountingDiskImage`, `Percent` -1) |
| `status-running-copying.plist` | `tmutil status -X` | Real, macOS 27.2, a network backup in the Copying phase, with `Progress` and `FractionOfProgressBar`. Top-level `Percent` is absent here |
| `status-running-time-remaining.plist` | `tmutil status -X` | Real, macOS 27.2, a later capture of the same network backup in the Copying phase. `Progress` also has `TimeRemaining` (seconds) |
| `destinationinfo-network.plist` | `tmutil destinationinfo -X` | Real, macOS 27.2, one SMB network destination |
| `destinationinfo-local.plist` | `tmutil destinationinfo -X` | **Reconstructed**: one local (USB) disk. `Kind` `Local` and `MountPoint` are from memory of the format, not a capture |
| `destinationinfo-none.plist` | `tmutil destinationinfo -X` | **Reconstructed**: an empty `Destinations` array |
| `destinationinfo-none.txt` | `tmutil destinationinfo` | **Reconstructed**: the sentence `tmutil` prints when no disk is set up. Which of the two "none" forms `-X` really gives hasn't been checked |
| `defaults-timemachine-network.txt` | `defaults read /Library/Preferences/com.apple.TimeMachine` | Real, macOS 27.2, one encrypted SMB network destination, automatic backups off, `RESULT` 0. Old-style plist text, not XML |
