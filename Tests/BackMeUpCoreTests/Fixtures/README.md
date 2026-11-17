# Fixtures

Saved output of the commands BackMeUp runs, for parser tests. None of these formats is documented by Apple.

Personal values are replaced: destination IDs become `00000000-0000-0000-0000-00000000000N`, the network URL becomes `smb://backup-user@backup-server/TimeMachine`, volume names become `TimeMachine` or `Backup Disk`, the mounted backup volume becomes `Backups of Example Mac`, and dates become 2026-01-01.

| File | Command | Source |
|---|---|---|
| `status-idle.plist` | `tmutil status -X` | Real, macOS 27.2, no backup running |
| `status-running-mounting.plist` | `tmutil status -X` | Real, macOS 27.2, early in a backup to a network disk (`BackupPhase` `MountingDiskImage`, `Percent` -1) |
| `status-running-copying.plist` | `tmutil status -X` | Real, macOS 27.2, a network backup in the Copying phase, with `Progress` and `FractionOfProgressBar`. Top-level `Percent` is absent here |
| `destinationinfo-network.plist` | `tmutil destinationinfo -X` | Real, macOS 27.2, one SMB network destination |
| `destinationinfo-local.plist` | `tmutil destinationinfo -X` | **Reconstructed**: one local (USB) disk. `Kind` `Local` and `MountPoint` are from memory of the format, not a capture |
| `destinationinfo-none.plist` | `tmutil destinationinfo -X` | **Reconstructed**: an empty `Destinations` array |
| `destinationinfo-none.txt` | `tmutil destinationinfo` | **Reconstructed**: the sentence `tmutil` prints when no disk is set up. Which of the two "none" forms `-X` really gives hasn't been checked |
