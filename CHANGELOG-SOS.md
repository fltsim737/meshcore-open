# MeshCore Open SOS and SOS Voice changelog

Both apps share the SOS code, so each release applies to both: `sos-<version>` for MeshCore Open SOS and `sos-voice-<version>` for MeshCore Open SOS Voice.

## 9.5.9 (2026-10-27)

### Fixed

- **SOS messages to emergency contacts now always flood**, as the alert on the emergency network already did and as the MeshCore SOS radio firmware sends them. They used to follow the route the radio had stored for the contact, so a stale route could lose them. The same goes for cancellations and acknowledgements sent by direct message. The radio learns the contact's route again from their reply; a path you set by hand in the app is kept.

## 9.5.8 (2026-10-27)

### Changed

- **MeshCore Open SOS is now its own app, named MeshCore Open SOS.** Until now it shared the original MeshCore Open's name and app ID (`com.meshcore.meshcore_open`), so a phone or computer saw the two as one app: they couldn't both be installed, and the SOS app showed as plain "MeshCore Open" in the phone's settings. It now has its own ID, `com.meshcore.meshcore_open_sos` (Windows and Linux too), as SOS Voice already has (`com.meshcore.meshcore_open_voice`).
  - **Moving to 9.5.8 (MeshCore Open SOS only):** because the ID changed, 9.5.8 installs as a new app beside the old one rather than over it, and starts empty. Before installing it, open the old app and use **Settings → Backup and restore → Export config** (and write down your emergency network codes). Install 9.5.8, connect to your radio, use **Import config**, check everything is there, then uninstall the old "MeshCore Open" SOS app. A coordinator who imports the file keeps the same network, so its codes and QR codes, and every device already given them, keep working.
  - **SOS Voice** keeps its ID and updates over 9.5.7 as usual.
- On Android, the app's name in the recent-apps view now matches its name (MeshCore Open SOS / MeshCore Open SOS Voice).

### Added

- **Full-screen SOS alerts** (Settings → App Settings → Emergency SOS, and the red card on the Emergency tab) now also says what to do when Android's settings page doesn't show the app or won't keep a setting, as happens on some Samsung phones: close all apps, restart the phone, then try again.

## 9.5.7 (2026-10-26)

### Fixed

- **The red SOS alert now opens when the app isn't on screen** (Android). In 9.5.6 an incoming SOS still came through as an ordinary notification unless the app was open: Android only shows a notification full screen while the phone is locked, and Samsung phones and Android 14 can switch that off for an app installed from an APK. Now, with **Display over other apps** allowed, the app opens the red alert itself, whether the phone is locked or in use.
- **Settings → App Settings → Emergency SOS → Full-screen SOS alerts** says whether this works on the phone, and a tap opens the system page to allow what's missing. While it's missing, a red card on the Emergency tab says so.

## 9.5.6 (2026-10-26)

### Added

- **Backup and restore.** Settings → **Backup and restore** → **Export config** saves one file with the radio's identity (its private key), name, radio settings, auto-add settings, channels and contacts, and this app's emergency network, home location, emergency contacts and alarm sound. **Import config** puts it all back: on the same radio after an update or erase, or on a new radio taking over the old one's identity (it restarts with it; connect again). The file is the same one the MeshCore SOS radio's web page exports, so either opens in the other. The SOS radio's own WiFi and button settings are only put back by its web page. The file is as sensitive as the radio itself: keep it private, and never run one identity on two radios at once.
- **An incoming SOS wakes the screen** on Android and opens the alert over the lock screen, as a phone call does, instead of only a notification. The app shows over the lock screen only for that alert. On Android 14 and later the app checks, when it joins an emergency network, that it may do this and opens the system setting if it may not.

### Fixed

- **A message to the person in trouble now gets through more often.** Their radio can only read a message from a phone it knows, and it learns the responder's phone from the ACK sent on the emergency network. If that one ACK was lost, messages arrived but never showed. **Message** on an acknowledged alert now sends the network ACK again first (at most every 30 seconds).

## 9.5.5 (2026-10-26)

### Added

- **Choose the SOS alarm sound.** Settings → App Settings → Emergency SOS → **Alarm sound**: **SOS in Morse code** (the default since 9.5.3, which can't be mistaken for other emergency apps' alerts) or the **classic alert tone**, the two-tone alarm of earlier versions. Android plays each at alarm volume on its own notification channel; Linux plays the Morse alarm or the desktop's alarm sound; Windows plays the Morse alarm or Windows' looping alarm.

## 9.5.4 (2026-10-26)

### Added

- **Locate: finding the person in trouble, close in.** A responder on the emergency network can tap **Locate** on an incoming alert. Their radio asks the radio that sent the SOS for a short beacon every 5 seconds, for 10 minutes after the last request; the request repeats every 2 minutes while the Locate screen is open. Beacons go radio to radio only, never through a repeater, so one heard at all was heard directly and its strength says how near the sender is. The screen shows each beacon's strength (RSSI and SNR) on a gauge from *Faint* to *Very close*, whether the responder is getting **warmer** or **colder**, when the last beacon came and a graph of them all, and the phone vibrates with each beacon. **Last known position** opens the alert's position on the map. Beacons are encrypted like every SOS message and stop as soon as the SOS is cancelled. The sender needs 9.5.4, or a radio that supports Locate; older versions ignore the request.

## 9.5.3 (2026-10-25)

### Changed

- **The SOS alarm is now SOS in Morse code** (· · · – – – · · ·), repeating until you acknowledge or dismiss the alert. The old two-tone alarm was too close to the alert tones of other emergency apps, and a responder must never mistake one for the other. Android plays it at alarm volume as before, on a new **SOS alerts** notification channel (Android fixes a channel's sound when the channel is made, so the old one is removed at start: set any custom alert settings again). Linux and Windows play the same Morse alarm; on Windows the alarm notification stays silent so the two don't clash.

### Added

- **Connects to your radio by itself.** When the app starts it connects again to the radio it was last connected to, the same way: Bluetooth, USB or network. A bar says *Connecting to …* with **Cancel**; if the radio isn't there, the list is ready as before. Turn it off under Settings → App Settings → **Connect to the last radio**. A computer that starts the app hidden in the tray at login is now connected and listening without opening the window.
- **A warning when the radio's battery reaches 20%:** a notification with the ordinary warning sound (deliberately nothing like the SOS alarm), a red battery icon, and a red card at the top of the Emergency tab while it stays low. It warns once each time, and again only after the radio has been charged.
- **"Last heard" on contacts**, above the time on each contact, so it's clear the time is when your radio last heard from them.

## 9.5.2 (2026-10-24)

### Fixed

- **Responders no longer miss a cancelled SOS.** A cancellation used to go out once on the emergency network and once by direct message to the sender's emergency contacts. A responder who acknowledged but missed it, or who wasn't an emergency contact, kept a live alert for up to an hour. Now:
  - every responder who acknowledged gets the cancellation by direct message, even if they aren't an emergency contact;
  - it goes out on the network three times, a minute apart, and each direct message is sent again until that person's radio confirms delivery;
  - if an acknowledgement arrives after the SOS was cancelled, the sender's app sends that responder the cancellation again;
  - a responder whose acknowledged alert has gone quiet for 12 minutes (two missed repeats) sends the acknowledgement again, so the sender can answer with the cancellation. A sender still in trouble just hears the acknowledgement again. Alerts you haven't acknowledged are never answered automatically.

Only the sender can cancel an SOS for everyone; a responder can still **Dismiss** an alert on their own phone.

## 9.5.1 (2026-10-23)

### Fixed

- **The alarm no longer cuts out when the same alert arrives twice.** A responder who is also one of the sender's emergency contacts gets each SOS on the emergency network and by direct message, a second or two apart. The second copy re-sounded the alarm, which on Android silenced its looping sound after under a second. Now an open alert only sounds again if it hasn't sounded in the last 30 seconds; repeats a minute apart still sound.
- **Linux: USB radios that are listed but won't open.** On Kubuntu, Ubuntu and similar systems a new user may not open USB serial ports, and the app only said "Failed to open the selected USB device." It now checks why. When it's a permissions problem it offers **Allow access**, which asks for your password once, installs a udev rule that lets whoever is logged in at the desktop use USB serial radios (no logging out needed), and reconnects. It also says when the radio has disappeared, or when another program, such as a flasher or serial monitor, may be using the port. Linux only.
- **Received SOS direct messages now show in the chat.** They used to go only to the alarm, so on a responder's phone the message seemed never to arrive. They now also appear in the chat with the sender, without a message notification (whose sound would cut off the alarm). The same goes for cancellation and `ACK` messages.

### Added

- **SOS history.** Every SOS received or sent on this phone is recorded and kept until you delete it, so it can be passed on to paramedics, emergency services or an incident report afterwards. Each record has the sender and public key, every position heard with its time, the info line, when it was heard and how, who acknowledged and when, and how it ended. **Share** sends it as a plain-text report with times in local time and UTC and a map link. Open it from the history icon on the Emergency tab, or Settings → App Settings → Emergency SOS → SOS history, which works without a radio connected.
- **Info line.** An SOS can carry a line of text, such as a short address or a gate code, as well as its position. It is shown on the alarm screen, the alert in the Emergency tab, the notification and the SOS history. The MeshCore SOS button firmware sends it; older app versions ignore it.
- **SOS entries in the app debug log** (Settings → App Settings → Debug → App Debug Logging): each alert heard (by network or DM), whether the alarm sounded, and when and why it was cleared.

### Changed

- **Privacy.** Received SOS direct messages stay in the chat with the sender, who chose you as an emergency contact. The SOS history keeps positions on this phone until you delete them. Channel alerts still never appear in any chat. See the [privacy notes](documentation/emergency-sos.md#privacy).

## 9.5.0 (2026-10-22)

First releases of MeshCore Open SOS and MeshCore Open SOS Voice. See [README-SOS.md](README-SOS.md).
