# MeshCore Open SOS and SOS Voice changelog

Both apps share the SOS code, so each release applies to both: `sos-<version>` for MeshCore Open SOS and `sos-voice-<version>` for MeshCore Open SOS Voice.

## 10.1.1 (2026-10-31)

### Voice you can hear (SOS Voice)

- **Each voice clip is levelled before it plays.** Codec2 clips often come out quiet (a quiet microphone stays quiet), and turning the computer's or phone's volume up barely helped, so on PC speakers voice was hard to hear. Now each clip's peak is raised to 90% of full scale, by up to 8 times (so hiss and silence aren't blown up), on every platform.
- **Voice volume** in **Settings → App Settings → Emergency SOS**: 25% to 300%. Above 100% voice gets louder still, rounded off smoothly near full scale instead of clipping, for quiet speakers. Rest tones play as they are.

## 10.1.0 (2026-10-31)

### The emergency network goes only on radios you agree to

- **No more channels on the wrong radio.** Before, an app with an emergency network put the network's channel on any radio it connected to: a radio being tested on a computer, lent out, or meant for another network picked it up just by being plugged in. Now, connecting to a radio without the channel **asks first**: *Add “Farm” to this radio?* on the Emergency tab, with **Add to this radio** or **Not this radio**. The answer is remembered for that radio.
- Joining or setting up a network while connected counts as agreeing for that radio, and a radio that already has the channel is left as it is. With no network set, nothing is ever added. This applies to members and responders alike.
- **Remove from this radio** on the emergency network screen takes the channel off the connected radio and keeps it off; the app stays in the network for your other radios, and **Add to this radio** there puts it back.

### Push-to-talk clips can be deleted, and tidy themselves away (SOS Voice)

- Each clip has a **Delete** button, and **Clear** deletes all of a conversation's clips (after asking). A clip still being sent can't be deleted.
- Clips are only ever kept in memory, never saved on the device, but the app runs in the background for days, so they now go by themselves too: push-to-talk clips older than **24 hours** are dropped (checked every 10 minutes), and at most **100** are kept over every conversation together, the oldest going first. SOS clips still go when their SOS ends.

## 10.0.0 (2026-10-31)

A major release: everything since 9.8.3. The 9.8.4, 9.8.5 and 9.8.6 test builds are replaced by it.

### New: choose the speaker and microphone (Linux and Windows)

- **Settings → App Settings → Emergency SOS** chooses the sound devices this app uses, each on its own: **Speaker for alerts and notifications** (the SOS alarm, message chimes and warnings) and, in SOS Voice, **Speaker for voice** (SOS voice and push-to-talk clips) and **Microphone**. So a headset can carry the talking while the alarm still sounds out loud. Only the app's own sound goes there: the computer's default devices, and every other program, are left as they are. Before, the app used whatever the system default was, and on Linux its short-lived sounds couldn't be moved to another device from the desktop's sound settings.
- A speaker chosen in an earlier 9.8.6 test build (one speaker for everything) becomes the voice speaker; alerts go back to the system default.
- Choosing a speaker plays a short sound on it to try it. A chosen device that's unplugged is shown as *not connected*, and the system default is used until it's back, so the SOS alarm is never silenced by a missing headset.
- Linux plays on the chosen PulseAudio/PipeWire device (`paplay --device`, `pw-play --target`) and records from the chosen source. Windows plays through waveOut on the chosen speakers (voice clips on the voice speaker; the SOS alarm, Morse or classic, on the alerts speaker), and records from the chosen microphone; Windows' own toast sounds for ordinary messages still use the default speaker.

### New: push-to-talk on a Voice channel and in direct messages (SOS Voice only)

- **A public Voice channel, #voice.** SOS Voice adds this hashtag channel to the radio once (in its last free slot; removed, it stays removed). Everyone on the mesh with SOS Voice hears it. It is a channel of its own: push-to-talk never uses MeshCore's Public channel.
- **Hold to talk** in the #voice chat. Clips up to 10 seconds, with no wait between them, so a conversation can flow.
- **Push-to-talk in direct messages:** the mic button at the top of a chat. Clips go to that contact as encrypted direct messages along their route (lighter than flooding), and never appear in the chat. Other MeshCore apps can't play them, and may show them as odd text.
- **A clip heard raises a notification**, as a text message does (*🎙 Voice clip, 3.2 s* from the sender, or on #voice), and plays aloud on the voice speaker. In a chat, push-to-talk opens by itself when a clip arrives, and the microphone button shows a dot for clips not yet seen.
- Clips use the SOS voice format (Codec2, Low or Clear) with a version byte of their own, so older SOS Voice apps ignore them.

### Voice gives way: text and SOS come first

- **Not while someone else is talking** on #voice (*Someone is talking…*).
- **Text comes first.** Push-to-talk stands aside while the mesh carries text: for 15 seconds after any text message is heard or sent, and while 4 or more text messages went in the last minute (*The mesh is carrying text messages… Voice in 12 s*).
- **A rest after 3 minutes of talk.** Each conversation (#voice, or a direct message) counts its voice both ways. After 3 minutes in one session, the people who talked in it hear **two tones** and their push-to-talk stops everywhere for **5 minutes**, with a countdown, giving the airtime back to everyone else. People who only listened aren't stopped. A session ends after 5 minutes without voice, and a clip near the limit is cut short.
- **Any SOS on the emergency network pauses push-to-talk**: at once for anyone whose app can read the alert (the sender, responders, emergency contacts), and for 5 minutes after any SOS packet is heard on the network for everyone else, members included, though their code can't read the alert (nothing is learnt about who sent it or where). The SOS repeats, so voice stays paused while it lasts. A clip already going out stops at its next packet, recording is cancelled, queued clips are dropped, and clips heard wait to be played by hand. Text keeps working for everyone.
- **SOS voice is never limited** by any of this.
- The user guide has a new section, *What voice costs the mesh*: one 10-second clip takes as much airtime as 12 to 15 text messages, more when flooded through repeaters, and what continued voice does to everyone else's messages.

### New: first-time setup

- **A setup wizard** opens once on a new install: what the app is (and that an SOS is best effort), how you're starting (setting up a group, or joining with a code), alerts on this device (full-screen alerts, Do Not Disturb and battery on Android; start at login, alarm sound, speaker and microphone on Linux and Windows), the emergency network, the emergency location, then connecting a radio. An app already set up skips it. Run it again from **Settings → App Settings → Emergency SOS → Setup wizard**.

### Credits

- The licences and credits (the app's About box, README-SOS, the user guide, the firmware's third-party notices) now name **Liam Cottle**, a core developer of MeshCore beside its creator Scott Powell, and maker of the official MeshCore apps and meshcore.js.
- **New CREDITS.md** names every contributor to MeshCore (231) and to MeshCore Open (50), as recorded in their histories, and the software and data the apps include.

## 9.8.5 (test builds only: part of 10.0.0)

- **SOS radio connection.** A MeshCore SOS radio (firmware 1.8.3 or later) shows how it connects in **Settings** (Location group), and the app can change it: hotspot, home WiFi, Bluetooth or USB cable. The app says how to connect again after the radio restarts. Refused during an SOS.
- **Fixed: a MeshCore SOS radio on USB pressing its own button, or restarting (Linux, Windows).** On a Heltec V3 the USB chip's DTR and RTS lines drive the ESP32's PRG button and reset: one line on without the other presses PRG or resets the radio. The apps used to toggle DTR on opening the port, so the radio stepped through its pages and could change its connection, send an SOS or power off. Now, on USB-to-serial adapters (CP210x, CH340, FTDI, PL2303), Linux and macOS leave both lines exactly as the system sets them (together, as the port opens and closes), and Windows turns DTR off with RTS already off, so the radio is neither pressed nor restarted.
- **The desktop apps look like the phone app:** one phone-width column in the middle of the window, which opens phone-shaped; the map still uses the whole window.

## 9.8.4 (test builds only: part of 10.0.0)

- **Locate ends when the searchers stop.** Leaving the Locate screen tells the sender's radio or app (twice, a few seconds apart). When the last searcher has gone, or none has been heard from for 2.5 minutes, the beacons stop and go back to full power. Locate repeats its request every minute (it was every 2 minutes). Needs MeshCore SOS firmware 1.8.2 or later for an SOS from the radio.

## 9.8.3 (2026-10-29)

### New: an SOS across a bridge, and retuning to reach it

- **An SOS now says what radio settings it was sent on.** The alert card shows *Their radio: 915.075 MHz · BW 125 · SF9 · CR 4/5*. When that isn't what your radio is on, for instance because the SOS crossed a MeshCore bridge from another frequency, the card says so: Locate can't hear them from your frequency, and they may not hear you directly.
- **Retune to their frequency, when you choose.** Nothing retunes by itself: you keep your own mesh while you travel or work. When you know you're within coverage on their side, press **Retune to their frequency** on the alert (or on Locate) and confirm. Your app first tells the other responders on your mesh, then moves your radio to the sender's settings.
- **Other responders see "Joe has re-tuned to 915.075 MHz and may be unreachable"** on the alert, so nobody wonders why you've gone quiet. It clears when you come back.
- **While retuned, the Emergency tab says so**, with **Back to 916.575 MHz** (your own settings) to return. It stays until you go back, also if the app is closed and opened again.
- Older apps read these alerts as before and ignore the new parts. A MeshCore SOS radio sends its settings from firmware 1.7.0, which also shows them, and who re-tuned, on its web page; to make room, its message line is now up to 27 characters (it was 32).

### New: how an SOS reached you

- **The alert card shows the route each copy of the SOS took to your radio**: *Straight from their radio*, or *Via Scaramouche → Superstar*, with how many copies came each way. Repeaters you have as contacts are shown by name, others by their short hash.
- **Locate warns when the SOS has only come through repeaters.** Locate hears the sender's radio itself, radio to radio, so from where you are it can't hear anything yet. It says so, names the repeater nearest the sender on the way to you, and tells you to head there and to the last known position. If the SOS crossed a bridge to another frequency, such as a MeshCore bridge between two repeaters, Locate can't hear the sender at all until your radio is on their frequency. The warning goes once their radio is heard directly.

## 9.8.2 (2026-10-29, released as part of 9.8.3)

### Fixed: repeater management drops out

- **Logging in to a repeater or room server, and a repeater's status, neighbours, settings, owner info and CLI now wait long enough for the reply.** They used the timeout learned from chat messages, which is trained on small acknowledgements that come straight back. A repeater has to handle the request and send a full reply, so for a repeater in direct range the wait could be cut to half a second and the app reported "unreachable" or "request failed" while the reply was still on its way. Repeater requests now wait for the airtime the request and reply actually need, at least 8 seconds direct and 12 seconds by flood, with extra margin for busy channels and bridges.
- **Every repeater request is tried three times**, and a reply to any try counts. Status, neighbours and settings refreshes were tried only once. This applies to the Android app and the desktop builds alike. Commands that mustn't be sent twice (`region load`, `reboot`, `start ota`, `poweroff`, `erase`) are still sent once.
- **If a direct route goes unanswered, the last try floods**, and the route is reset so the reply teaches the radio the current one. A repeater that moved, changed frequency or now sits behind a bridge no longer fails every try on an old route. A route you set by hand is left alone.

## 9.8.1 (2026-10-29)

### Fixed: Dismiss no longer loses the SOS

- **Dismiss puts an alert aside instead of deleting it.** Until now, a responder who dismissed an alert (by accident, or after acknowledging it) lost it, with its position, until the sender's radio repeated the SOS, which after the first five minutes is only every 5 minutes. Now the alarm stops and the alert shrinks to a line on the Emergency tab, with **Show again** to bring it straight back as it was: position, your acknowledgement and Locate included. If you hadn't acknowledged it, the sender's next repeat still brings it back with the alarm; an acknowledged one stays put aside until you tap Show again. It's deleted when the sender cancels or after 60 minutes unheard, as before.
- On the MeshCore SOS radio's web page, the same from firmware 1.6.2, which also shows **Being located** on the SOS card while responders search for the radio.

## 9.8.0 (2026-10-29)

### New: a coordinated search with Locate

- **Searchers can turn the beacons down as they close in.** On the Locate screen, **Beacon power** shows the power the SOS radio's beacons go at and who last set it. Any searcher can choose Full, High (14 dBm), Medium (8), Low (2) or Very low (−9): agree it among yourselves over the radio first. At low power only searchers close by still hear the beacons, which narrows the search. Only the beacons change: the SOS itself, its repeats, ACKs and messages always go at full power, and the beacons go back to full power when the search ends. It needs the sender to be using a MeshCore SOS radio with current firmware; an SOS sent from a phone app keeps its beacons at full power.
- **Searchers share what they hear.** Every 30 seconds, each searcher's app shares its position and the latest beacon's strength with the other searchers (sealed on SOS2 networks, so only responders can read it).
- **Search map.** Each searcher's reading is a ring on the map: how far their signal strength puts the radio. Where the rings from two or more places meet, the shaded **search area** is where to look first. It's an estimate, not a pin: terrain, trees and bodies weaken the signal. It gets smaller as more readings come in and the power is turned down.
- **Find the direction:** a guide to using your own body to block the signal from behind and work out which way to go.

## 9.7.2 (2026-10-28)

### Changed: an SOS sounds when it matters

- **An incoming SOS now sounds through Do Not Disturb, silent mode and other apps' audio** (Android). The app plays the alarm itself, as alarm audio: silent and vibrate mode don't mute it, the alarm volume is turned up for the alert, and it takes the sound from other apps (music, videos, a Discord call), which pause or go quiet until the alert is dealt with. Everything is put back afterwards. It also vibrates SOS in Morse.
- **Do Not Disturb:** allow **SOS through Do Not Disturb** once (**Settings → App Settings → Emergency SOS**, or the warning on the Emergency tab) and an SOS breaks through it; if Do Not Disturb is set to silence alarms too, the app lets alarms through for the alert and puts your setting back afterwards.
- **During a phone call** Android only lets other sound play quietly, so the alarm plays quietly in the earpiece, the phone vibrates and the full-screen alert shows.

### Fixed

- **Removing a contact no longer puts it in Discovered nearby**, so there's nothing to clear. It's listed there again only if it sends a new advert.
- **"Last heard" is when you heard them.** It used the time inside the contact's advert, which is the other radio's clock: a repeater or radio with its clock wrong showed as heard months ago. It now uses when your radio or phone received it.
- **Messages from a radio with a wrong clock** show when they arrived, with a clock icon, instead of a time months out or in the future; the clock icon now covers clocks that are far behind as well as ahead. A message's time is otherwise the sender's, as before.

SOS alerts, acknowledgements and cancellations were already timed by your phone's clock, so a sender's wrong clock never affected them.

## 9.7.1 (2026-10-28)

### Changed: repeater settings save air time

- **Opening a repeater's Settings no longer reads every setting.** Logging in as admin and opening **Settings** used to send about 20 requests to the repeater straight away, one after another. Over several hops that congested the mesh and the reads failed. Now nothing is read until you ask: tap **⟳** next to the setting you want to see or change, and only that one is read. Each field stays greyed out until it has been read. The **⟳** at the top of the screen still reads everything, when you tap it.

## 9.7.0 (2026-10-27)

### Changed: sealed emergency networks

- **A member code can no longer read alerts.** New networks (codes starting `SOS2-`) are sealed. The responder code holds the network's secret key; the member code holds only its public key. Each SOS gets its own one-off key and is encrypted to the network's public key, so only responders can read it, even with modified software, and a member code can't be turned into a responder code. Acknowledgements, cancellations, Locate and (SOS Voice) voice clips for that SOS are sealed with that SOS's own keys, so members can't read them, and nobody without the keys can fake an acknowledgement or a cancellation. A member code posted on a repeater for travellers now lets people send an SOS without letting them read anyone's (anyone with a code can still send an SOS, real or not).
- **Older networks** (`SOS1-` codes) still work, so a group can move over at its own pace, but both of their codes hold the same key. **Emergency network** shows a warning on them: set up a new network and hand out the new codes. Everyone on a network needs 9.7.0 or later (or MeshCore SOS radio firmware 1.4.0 or later) to use an `SOS2-` network.
- The codes are longer (scan the QR code where you can). A coordinator's phone shows the member code and, only while it holds the network secret, the responder code.
- SOS Voice clips on a sealed network carry a little less audio per packet, so a 20-second clip takes up to 14 packets instead of 12.

## 9.6.1 (2026-10-27)

### Changed

- **Licence and disclaimer.** The MIT licence now names the SOS additions' author (fltsim737) beside MeshCore Open's (zjs81), so its "as is, without warranty" disclaimer and limitation of liability cover both, and the README has a plain-language disclaimer: not a certified or monitored alarm, best effort, not your only way of calling for help.
- **Settings → About** shows the app's own name, and its credits and licence: MeshCore Open © 2025 zjs81 and contributors, the SOS additions © 2026 fltsim737, under the MIT licence; not affiliated with the MeshCore project; provided as is, without warranty, and not a certified emergency alarm. It used to show the original MeshCore Open's name.
- **The app's own name everywhere.** The Scanner screen's title, notifications (including replying from one), the tray menu, the battery-optimisation hint, the Linux USB fix and the SOS history report now say MeshCore Open SOS (or MeshCore Open SOS Voice), in every language, instead of MeshCore Open. Mentions of the original MeshCore Open project, such as its network map, are unchanged.
- **SOS Voice:** **Settings → About → View licenses** now includes the full licence text of Codec2 (GNU LGPL 2.1), the voice codec built into SOS Voice.

## 9.6.0 (2026-10-27)

### Added

- **Heard repeats** on your active SOS (Emergency tab): how many copies of your SOS your radio has heard passed on by repeaters, and which repeaters (by name when they're in your contacts), with how many copies each. It shows your SOS is travelling across the mesh, though not that anyone has read it; the people who acknowledged are listed below it as before. Your radio only hears repeaters within its own range, so ones further along aren't counted.

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
