# BackMeUp

BackMeUp is a free app for your Mac that makes sure your Time Machine backups actually happen.

It lives in the menu bar at the top of your screen. It starts Time Machine backups on a schedule you choose, only when you allow it, and tells you clearly when backups stop.

- You choose how often backups run: every few hours, days or weeks.
- You choose whether backups may run while your Mac is on battery.
- If your backup disk is on your network, backups run only on the networks you choose. They never start on a phone hotspot or in a café.
- If backups fail, or haven't happened for a few days, you get a Mac notification that says why. You can also get the alert on your phone.

BackMeUp never needs Terminal, a settings file or your admin password. It doesn't send anything about you or your Mac anywhere, apart from the phone alerts you set up and checks for updates.

## What you need

- A Mac with **macOS 14 Sonoma or later**.
- **A Time Machine backup disk.** This can be a USB disk you plug in, or a disk on your network. BackMeUp uses the disk you already have. If you don't have one set up yet, BackMeUp tells you how to add one.

## Download

1. Go to the [Releases page](https://github.com/Blowoffvalve/BackMeUp/releases/latest).
2. Under **Assets**, click the file called `BackMeUp-` followed by a version number and `.zip`.
3. Open your **Downloads** folder. If you see a zip file, double-click it to unzip it.
4. Drag **BackMeUp** into your **Applications** folder.

## Open BackMeUp for the first time

BackMeUp isn't sold through Apple, so the first time you open it, macOS stops it and asks you to confirm. You only do this once. You shouldn't need to do it again when BackMeUp updates itself.

### On macOS 15 Sequoia or later

**1. Open BackMeUp.** In your Applications folder, double-click **BackMeUp**.

![The Applications folder with BackMeUp selected](docs/images/open-anyway-1-open.png)

**2. Click Done.** macOS says it can't open BackMeUp. Click **Done**. Don't click Move to Trash.

![The warning that BackMeUp was not opened, with the Done button](docs/images/open-anyway-2-done.png)

**3. Open System Settings.** Click the Apple menu in the top-left corner of your screen, then click **System Settings…**.

![The Apple menu with System Settings highlighted](docs/images/open-anyway-3-system-settings.png)

**4. Go to Privacy & Security.** In the list on the left, click **Privacy & Security**. Scroll down to the **Security** section. You'll see a line saying BackMeUp was blocked.

![Privacy & Security, scrolled down to the line saying BackMeUp was blocked](docs/images/open-anyway-4-privacy-security.png)

**5. Click Open Anyway.** Click the **Open Anyway** button next to that line. If a box asks whether you want to open BackMeUp, click **Open Anyway** again.

The button only shows for about an hour after step 1. If you can't see it, go back to step 1.

![The Open Anyway button](docs/images/open-anyway-5-open-anyway.png)

**6. Enter your password.** Type the password you use to log in to your Mac, or use Touch ID, and click **OK**. BackMeUp opens.

![The password box](docs/images/open-anyway-6-password.png)

### On macOS 14 Sonoma

In your Applications folder, hold down the Control key and click **BackMeUp**. Choose **Open** from the menu, then click **Open** in the box that appears.

### Look for the icon

BackMeUp has no window in the Dock. Look for a small house icon in the menu bar at the top right of your screen. Click it to open the BackMeUp menu.

## The setup checklist

The first time BackMeUp opens, it shows a window called **Set Up BackMeUp**. It lists six checks. Each one has a button that takes you to the right place, usually **Open Settings**.

Backups start once checks 1, 2 and 6 are done. The others help backups keep running.

| Check | What it's about | Done when it says |
|---|---|---|
| 1 | You need a Time Machine disk. The button opens Time Machine settings, where you click **Add Backup Disk**. | "A Time Machine disk is set up." |
| 2 | Time Machine's own automatic backups must be off, so that BackMeUp's schedule is the one that runs. In Time Machine settings, click **Options** and set **Back up frequency** to **Manually**. | "Time Machine's automatic backups are off." |
| 3 | Whether your backup disk is encrypted. This is only a warning. It never stops backups. | "Your backup disk is encrypted." |
| 4 | BackMeUp should open when you log in, so backups keep running after a restart. It adds itself. If macOS asks you to approve it, the button opens Login Items. | "BackMeUp opens at login." |
| 5 | Notifications let BackMeUp tell you when backups stop. Click **Allow Notifications**. | "Notifications are allowed." |
| 6 | For a disk on your network: choose the networks backups may run on. While you're at home, open the BackMeUp menu and choose **Allow backups on this network**, or click **Allow Backups on This Network** in Settings. A USB disk doesn't need this. | "At least one network is chosen for backups." |

Each check has a mark next to it: ✓ done, ✗ not done, ! a warning, ? BackMeUp can't tell, and – doesn't apply to your Mac.

If BackMeUp can't tell whether check 1 or 2 is done, it waits, just as if the check wasn't done.

The checklist comes back by itself if something changes later, for example if automatic backups are turned back on. You can open it any time from the menu with **Setup Checklist…**.

### Your first backup

The first backup copies everything, so it can take hours. Do it with your Mac plugged in, and at home or with the USB disk attached.

While a backup runs on power, BackMeUp keeps your Mac awake. Closing the lid still puts it to sleep. If the first backup stops part-way, BackMeUp shows it as paused, not failed, and carries on at the next try.

## The menu

Click the house icon in the menu bar. From top to bottom, the menu shows:

- **How your backups are doing.** For example "Last backup: today 14:02", "Getting ready to back up" then "Backing up: 35.2% of 251.55 GB, about 3 hours left" (following the stage, percentage and total size Time Machine shows), "Last backup failed: …", "Waiting for a chosen network" or "Finish setting up: see the checklist".
- **When the next backup is.** For example "Next backup: tomorrow 14:02", "Next try: today 15:30" after a problem, or "Resumes: …" for a paused first backup.
- **The network you're on**, and whether backups may run on it. For example "Network: Home (backups allowed)" or "Network: Café (not chosen)".
- **Allow backups on this network.** Only shown when you're on a network you haven't chosen. If macOS asks to use your location, that's only so BackMeUp can show the Wi-Fi name. If you say no, BackMeUp asks you to type a name, such as Home.
- **Back Up Now.** Starts a backup straight away, even on battery, as long as checks 1, 2 and 6 are done.
- **Troubleshoot…**, or **How to Fix This…** when BackMeUp has found a problem. See [Troubleshooting](#troubleshooting).
- **Setup Checklist…**
- **Settings…**
- **Check for Updates…** (missing from copies that can't update themselves)
- **Show Log.** Opens a plain-text list of what BackMeUp has done. Useful if someone is helping you.
- **Uninstall…**
- **Quit BackMeUp**

When something's wrong, the arrow in the house icon turns into an exclamation mark.

## Troubleshooting

After every failed backup, and whenever you choose **Troubleshoot…** in the menu, BackMeUp checks:

1. **Network:** whether your Mac is on a network where backups are allowed.
2. **Backup server:** for a network disk, whether its server answers. BackMeUp only knocks on the server's file-sharing port; it doesn't log in.
3. **Time Machine:** whether Time Machine is stuck.

The Troubleshoot window lists each check with a tick or a cross, and puts the steps for the first problem at the top. **Copy Details** copies a short summary to send to whoever set up your backups. It names no server, network or address.

### When Time Machine is stuck

Sometimes Time Machine loses track of a network backup disk that's still there. Every backup then fails at once ("Time Machine is stuck"), and it doesn't fix itself. BackMeUp calls it stuck only when Time Machine gave up within seconds, the server answers, and Time Machine's own log shows it lost the disk.

Restarting your Mac fixes it. Save your work, choose Apple menu > Restart, and log in as usual. About 5 minutes after you log in, BackMeUp starts a backup (on an allowed network, and on power if you've turned off battery backups) and tells you "Fixed: backing up again". If it's still stuck, BackMeUp says so and doesn't ask you to restart again: use **Copy Details** and send them to whoever set up your backups.

BackMeUp never restarts your Mac for you.

## Settings

Choose **Settings…** from the menu. Changes save straight away.

- **Back up every** 1 day, or any number of hours, days or weeks. This is counted from the last successful backup.
- **If a backup can't run, try again every** 60 minutes. At least 15 minutes.
- **Allow backups on battery.** On to start with. When it's off, scheduled backups wait until you plug in. **Back Up Now** still works.
- **Alert me after** 1 **failed backups in a row**, **or after** 3 **days without a backup**.
- **Networks for backups to a network disk.** Your chosen networks, with **Rename…** and **Remove**. Turn on **Back up to a network disk on any network** if you don't want this rule.
- **Phone alerts (optional).** See below.
- **Updates.** See below.

## Alerts

BackMeUp sends a Mac notification when:

- a backup starts but doesn't finish ("Backup failed")
- there's been no successful backup for 3 days, whatever the reason ("Backups skipped", "Backups failed", "First backup not finished" or "Backups overdue")
- Time Machine is stuck and your Mac needs a restart ("Time Machine is stuck"). See [Troubleshooting](#troubleshooting).
- backups work again after a problem ("Backups are working again", or "Fixed: backing up again" after a restart)

Each alert says why. For example: "No backup for 3 days. Your Mac hasn't been on a chosen network since Friday."

If Time Machine couldn't reach the backup disk (its error 26), the alert and the menu say "The backup disk couldn't be reached." For a network disk they add: "Check you're on the right network. If it keeps happening, restarting your Mac usually fixes it." When BackMeUp can tell why, it says that instead: that the backup server isn't answering, or that Time Machine is stuck. Other Time Machine errors are shown by their number.

Backups that are skipped never count as failures. A backup is skipped when your Mac is on a network you haven't chosen, on battery with battery backups turned off, when the USB disk isn't plugged in, or when the network disk's server can't be reached at all (Time Machine's error 18, for example just after you log in, while a VPN such as Tailscale is still connecting). Skipped backups still count towards days without a backup.

While a problem lasts, every further failed backup sends another alert. If backups are only being skipped, the "no backup for N days" alert comes again each day the count goes up.

If your network disk can be reached on a network you haven't chosen, for example after you get a new router, BackMeUp asks once: "Back up on this network?" If it's yours, choose **Allow backups on this network** in the menu, or click **Allow Backups on This Network** in Settings.

### Alerts on your phone (optional)

BackMeUp can also send every alert to your phone through [ntfy](https://ntfy.sh), a free notification app.

1. Install the ntfy app on your phone.
2. In the app, subscribe to a topic. Pick a name that's hard to guess, because anyone who knows it can read your alerts.
3. In BackMeUp, open **Settings…** and find **Phone alerts (optional)**.
4. Leave **Server** as `https://ntfy.sh`, unless you run your own.
5. Type the same name into **Topic**.
6. Leave **Access token** empty, unless your topic needs one.
7. Click **Send test message**, and check that it arrives on your phone.

Your topic and access token are kept in your Mac's Keychain. Once your first backup finishes, your phone also gets a one-time "First backup finished" message.

## Updates

BackMeUp checks for updates once a day. When there's a new version, it asks before installing it.

To install updates without being asked, open **Settings…** and turn on **Install updates automatically**. To check straight away, choose **Check for Updates…** in the menu, or click **Check Now** in Settings.

## Uninstalling

1. Choose **Uninstall…** from the menu, then click **Uninstall**.
2. BackMeUp removes itself from Login Items and deletes its settings, its history, its log and its phone alert details.
3. BackMeUp reminds you to turn Time Machine's automatic backups back on. **This matters:** without BackMeUp, your Mac won't back up until you do. Click **Open Time Machine Settings**, click **Options**, and set **Back up frequency** to one of the **Automatically** options.
4. Drag **BackMeUp** from your Applications folder to the Trash.

Uninstalling never touches your backups or Time Machine's settings.

## For contributors

See [docs/design.md](docs/design.md) for how BackMeUp works inside, and [docs/agents/building.md](docs/agents/building.md) for building and testing. The full spec is [issue #1](https://github.com/Blowoffvalve/BackMeUp/issues/1).

## Licence

MIT. See [LICENSE](LICENSE).
