# Fixtures

Saved output of the commands BackMeUp runs, for parser tests. None of these formats is documented by Apple.

Personal values are replaced: destination IDs become `00000000-0000-0000-0000-00000000000N`, the network URL becomes `smb://backup-user@backup-server/TimeMachine`, volume names become `TimeMachine` or `Backup Disk`, the mounted backup volume becomes `Backups of Example Mac`, and dates become 2026-01-01.

In `defaults-timemachine-*.txt`, other UUIDs become `00000000-0000-0000-0000-0000000000NN` too, the network URL user, host and share are replaced as above, dates move into 2026-01-01 to 03 and the snapshot list is shortened. The `BackupAlias` data value keeps the shape `defaults` prints (first and last few bytes) but its bytes are zeroed.

| File | Command | Source |
|---|---|---|
| `status-idle.plist` | `tmutil status -X` | Real, macOS 27.2, no backup running |
| `status-running-mounting.plist` | `tmutil status -X` | Real, macOS 27.2, early in a backup to a network disk (`BackupPhase` `MountingDiskImage`, `Percent` -1) |
| `status-running-thinning-post-backup.plist` | `tmutil status -X` | Real, macOS 27.2, a network backup that has finished copying and is cleaning up old backups (`BackupPhase` `ThinningPostBackup`, `Percent` -1). Ran for over an hour; `tmutil startbackup` can't start a backup meanwhile |
| `status-running-copying.plist` | `tmutil status -X` | Real, macOS 27.2, a network backup in the Copying phase, with `Progress` and `FractionOfProgressBar`. Top-level `Percent` is absent here |
| `status-running-time-remaining.plist` | `tmutil status -X` | Real, macOS 27.2, a later capture of the same network backup in the Copying phase. `Progress` also has `TimeRemaining` (seconds) |
| `status-running-time-machine-shows-20.8.plist` | `tmutil status -X` | Real, macOS 27.2, a network backup in the Copying phase, captured while Time Machine's menu showed "20.8% done". `Percent` is 0.1197 and `FractionOfProgressBar` 0.9: Time Machine shows 10% + 0.9 × `Percent`. Destination, mount point and date replaced; `TimeRemaining` removed |
| `destinationinfo-network.plist` | `tmutil destinationinfo -X` | Real, macOS 27.2, one SMB network destination |
| `destinationinfo-local.plist` | `tmutil destinationinfo -X` | **Reconstructed**: one local (USB) disk. `Kind` `Local` and `MountPoint` are from memory of the format, not a capture |
| `destinationinfo-two-disks.plist` | `tmutil destinationinfo -X` | **Reconstructed** from the two files above: an unencrypted USB disk listed first and an encrypted network disk second, as when someone keeps an old disk after adding a new one. `LastDestination` is on the network disk |
| `destinationinfo-none.plist` | `tmutil destinationinfo -X` | **Reconstructed**: an empty `Destinations` array |
| `destinationinfo-none.txt` | `tmutil destinationinfo` | **Reconstructed**: the sentence `tmutil` prints when no disk is set up. Which of the two "none" forms `-X` really gives hasn't been checked |
| `defaults-timemachine-network.txt` | `defaults read /Library/Preferences/com.apple.TimeMachine` | Real, macOS 27.2, one encrypted SMB network destination, automatic backups off, `RESULT` 0. Old-style plist text, not XML |

## Network tables

`netstat-*.txt` and `arp-*.txt` keep the shape of real macOS 27.2 output, but every value is replaced: the router is `192.0.2.1` (a documentation address), other local hosts are `192.0.2.N`, VPN addresses are `100.64.0.N`, and hardware addresses are `2:0:0:0:0:N` style (written without leading zeros, as `arp` and `netstat` print them).

| File | Command | Source |
|---|---|---|
| `netstat-wifi-and-vpn.txt` | `netstat -rn -f inet` | Real, shortened: a Wi-Fi default route on `en0` with a Tailscale `utun` default route after it |
| `netstat-wifi.txt` | `netstat -rn -f inet` | The same capture with the VPN lines removed |
| `netstat-vpn-first.txt` | `netstat -rn -f inet` | **Reconstructed**: a VPN default route listed before an Ethernet one on `en7` |
| `netstat-vpn-only.txt` | `netstat -rn -f inet` | **Reconstructed**: only `utun` and `ipsec` default routes |
| `arp-gateway.txt` | `arp -an` | Real, shortened: the router's entry on `en0`, plus an `(incomplete)` entry |
| `arp-gateway-incomplete.txt` | `arp -an` | **Reconstructed** from it: the router's entry is `(incomplete)` |
| `arp-gateway-missing.txt` | `arp -an` | **Reconstructed** from it: no entry for the router |
| `arp-wifi-and-ethernet.txt` | `arp -an` | **Reconstructed**: the router's IP on both `en0` and `en7`, with different addresses, to check the route's interface is used |

The SystemConfiguration dictionaries in `NetworkParserTests.swift` copy the keys of a real `State:/Network/Service/<id>/IPv4` entry with the values replaced the same way.
