# MeshCore Open SOS and SOS Voice changelog

Both apps share the SOS code, so each release applies to both: `sos-<version>` for MeshCore Open SOS and `sos-voice-<version>` for MeshCore Open SOS Voice.

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
