# MeshCore Open SOS and MeshCore Open SOS Voice

Two builds of [MeshCore Open](README.md) that add emergency calling over a MeshCore LoRa mesh. They are for places with no mobile coverage and no internet: farms, stations, national parks, back roads, bushfire and flood country.

| | **MeshCore Open SOS** | **MeshCore Open SOS Voice** |
|---|---|---|
| What it adds | Emergency SOS alerts, acknowledgements, emergency networks, and messaging between the sender and responders | Everything in MeshCore Open SOS, plus short voice clips between the sender and responders during a live SOS |
| Platforms | Android, Linux (AppImage), Windows | Android, Linux (AppImage), Windows |
| Branch | `feat/emergency-sos` | `feat/sos-voice` (built on `feat/emergency-sos`) |
| Android package | `com.meshcore.meshcore_open_sos` (from 9.5.8) | `com.meshcore.meshcore_open_voice` |
| Status | Tested between two radios on Android, Linux and Windows | Tested between two radios on Android and Linux. Windows build is new |

The two apps can be installed side by side, and each keeps its own settings and messages. Only one of them can be connected to a radio at a time.

**Neither build needs a firmware change.** They run on any standard MeshCore companion radio and work alongside people using other MeshCore apps.

**About the MeshCore SOS radio.** The changelog mentions the *MeshCore SOS radio*, a stand-alone SOS radio that sends and understands the same alerts. Its firmware is a separate, proprietary product that is still being tested: it isn't part of this repository, isn't covered by its licence, and isn't publicly released. The apps don't need it.

> **An SOS is best effort.** LoRa delivery is never guaranteed. An acknowledgement means someone received your alert, not that help is on the way. Keep using every other way of calling for help that you have: a PLB, satellite messenger, UHF radio or phone.

---

## Contents

- [Why this exists](#why-this-exists)
- [How it works](#how-it-works)
- [Installing](#installing)
- [User guide](#user-guide)
- [Voice (SOS Voice only)](#voice-sos-voice-only)
- [Privacy and security](#privacy-and-security)
- [Limitations](#limitations)
- [Why it should be included, used and developed further](#why-it-should-be-included-used-and-developed-further)
- [Roadmap and help wanted](#roadmap-and-help-wanted)
- [Building from source](#building-from-source)
- [Licences, credits and disclaimer](#licences-credits-and-disclaimer)

---

## Why this exists

A large share of rural and remote land has no mobile signal. The people working there are often working alone: a farmhand checking water on a far paddock, a ranger on a fire trail, a contractor fencing on a back block. When something goes wrong, such as a rollover, a snake bite, a fall or a medical event, the first problem is telling anyone at all.

The current options all have gaps:

- **Personal locator beacons** reach emergency services by satellite, but the people nearby who could get there first don't hear them.
- **Satellite messengers** need a subscription for each person and a clear view of the sky.
- **UHF/CB radio** needs someone listening on the right channel at that moment, and doesn't send a position.

MeshCore already gives communities cheap, solar-powered repeaters and pocket radios that pass messages across tens of kilometres with no infrastructure. What it lacked was a dependable way to say "I need help, here is where I am" and keep saying it until someone answers. MeshCore Open SOS adds that, and SOS Voice adds the ability to talk once someone has answered.

---

## How it works

### The emergency network

A group, such as a farm team, a station, a volunteer brigade or a park crew, shares a private, hidden channel called an **emergency network**. The coordinator creates it once, and the app makes the network's keys and two codes, each shown as text and as a QR code:

- A **member code** (`SOS2-M-…`) is for people who may need to *send* an SOS. It can send alerts but can't read anyone's, and the channel stays hidden.
- A **responder code** (`SOS2-R-…`) is for people who *receive* alerts. It holds the network's secret key, which reads them. The channel shows in their channel list, and an SOS on it raises the alarm.

Networks made since 9.7.0 are **sealed**. Each SOS gets its own one-off key and is encrypted to the network's public key, which the member code holds, so only a responder code can read it, even with modified software. Acknowledgements, cancellations, Locate and voice for that SOS are sealed with that SOS's keys, so members can't read them, and nobody without the keys can fake them. A member code can't be turned into a responder code.

Networks made before 9.7.0 (`SOS1-` codes) still work, but both of their codes hold the same key, so anyone with a member code could read alerts with modified software. The app warns about them: set up a new network and hand out the new codes. Everyone on an `SOS2-` network needs 9.7.0 or later.

Repeater operators can also put a member code in the repeater's **owner info**. A traveller who logs in to that repeater as a guest sees **Operator info**, and the app offers to join the area's network. A visitor can join a local emergency network without ever meeting the people who run it.

### Sending

Holding the red **SOS** button for two seconds sends an alert that carries:

- an alert ID (for example `#a1b2`);
- the sender's node name and full public key;
- a position and where it came from: phone GPS first, then the radio's own location, then a stored location such as the homestead, or none.

The alert goes out as a binary data packet on the emergency network, and as a plain-text direct message to each chosen emergency contact. The text DM means a contact using any other MeshCore app can still read it and reply `ACK #a1b2`.

The alert **repeats every minute for the first five minutes, then every five minutes until the sender cancels**. Repeats carry the latest position, so a moving sender can still be followed. An acknowledgement does not slow the repeats, because it doesn't mean help has arrived.

### Receiving

A responder's phone shows a full-screen red **EMERGENCY SOS** warning with the sender, any info line the sender added (such as a short address), position, position source and the times the alert was first and last heard. The alarm is **SOS in Morse code** (· · · – – – · · ·) by default, so it can't be mistaken for other emergency apps' alerts (the classic two-tone alert can be chosen instead in the SOS settings); on Android the app plays it as alarm audio, so silent and vibrate mode don't mute it: it turns the alarm volume up, takes the sound from other apps (music, videos, a call in Discord), vibrates SOS in Morse and loops until the responder acknowledges or dismisses it, then puts everything back. With **SOS through Do Not Disturb** allowed it also breaks through Do Not Disturb. During a phone call Android only lets it play quietly, so it vibrates and shows full screen as well. **Send ACK** answers on the mesh; **Message** opens a chat with the sender (sending the ACK again first, so their radio knows the responder). On Android the alert wakes the screen and shows over the lock screen. Every responder can see who else has acknowledged, so a group knows who is already responding. **Map** shows where to go.

**Locate** helps responders close in on the sender once near: the sender's radio sends a short beacon every few seconds, radio to radio only, and each responder's screen shows how strong each one is and whether they're getting warmer or colder. Several searchers can work together: any of them can turn the beacons' power down as they close in (from a MeshCore SOS radio), so only those near still hear them, and each searcher's app shares its position and what it hears every 30 seconds. The **Search map** shows each reading as a ring, how far that signal puts the radio, and shades the area where the rings agree. It's an estimate to search, not a pin.

Each SOS and ACK carries the sender's public key, so the two phones save each other as contacts automatically. A **Message** button then opens an ordinary direct chat, with no exchange of adverts beforehand.

When the sender cancels, a cancellation goes out on the network and by direct message to every emergency contact and every responder who acknowledged. It is repeated, and direct copies are re-sent until delivered. A responder whose acknowledged alert goes quiet checks back with the sender, so a missed cancellation still arrives. Each responder's alarm stops and the live alert closes. A record of it, with its positions, acknowledgements and outcome, stays in the **SOS history** until the user deletes it, ready to share as a text report.

### Voice (SOS Voice)

Once an SOS is live, a **Voice** panel appears on the sender's SOS card and on each responder's alert. Speech is compressed with [Codec2](https://github.com/drowe67/codec2), an open-source codec built for HF and low-bitrate radio, at 700 or 1300 bit/s. It is sent as a short clip of up to 12 packets on the emergency network channel, the same way MeshCore Open sends images. Clips play aloud as they arrive. This is like walkie-talkie messages, not a live call: LoRa is far too slow to stream speech across a mesh. Voice works only while an SOS is live, so it can't become a general-purpose voice chat that floods the network.

### On the wire

| Packet | Carried as | Who can read it |
|---|---|---|
| SOS, ACK, cancel | Channel data type `0x5053` on the emergency network | MeshCore Open SOS / SOS Voice holders of the network code |
| Locate request, locator beacon, searcher's reading | Channel data type `0x5053`; beacons are sent zero hop | MeshCore Open SOS / SOS Voice holders of the network code (responders only, on sealed networks) |
| Voice clip | Channel data type `0x5356` (SV) on the emergency network | SOS Voice holders of the network code |
| SOS DM to emergency contacts | Plain text, under 160 bytes | Any MeshCore app |
| Repeater owner info | Existing `GET_OWNER_INFO` request (`0x07`) | Any guest of the repeater |

Full layouts are in [documentation/emergency-sos.md](documentation/emergency-sos.md) and the [protocol reference](documentation/ble-protocol.md#emergency-sos-packets).

---

## Installing

Download the installer for your platform from the [Releases](https://github.com/fltsim737/meshcore-open/releases) page. What changed in each version is in the [changelog](CHANGELOG-SOS.md). Pick **SOS** or **SOS Voice**; both can be installed together. Each release also has a short walkthrough video.

| Platform | MeshCore Open SOS | MeshCore Open SOS Voice |
|---|---|---|
| Android (ARM64) | `meshcore-open-sos.apk` | `meshcore-open-sos-voice.apk` |
| Linux x86-64 | `MeshCore_Open_SOS-x86_64.AppImage` | `MeshCore_Open_SOS_Voice-x86_64.AppImage` |
| Windows x64 | `MeshCore-Open-Setup.exe` (installs as "MeshCore Open") | `MeshCore-Open-SOS-Voice-Setup.exe` |

### Android

1. Copy the APK to the phone and open it. Allow "install unknown apps" for your file manager if asked.
2. On first launch, allow Bluetooth, location and notifications. SOS Voice also asks for the microphone the first time you talk.
3. To keep alerts arriving with the screen off, allow the app to run in the background when asked (battery optimisation off). A notification shows while it is listening.
4. So an SOS opens the red alert even when the app isn't open, check **Settings → App Settings → Emergency SOS → Full-screen SOS alerts** and tap it to allow what it asks for: **Display over other apps**, and on Samsung and Android 14 or later, **full-screen notifications**. If the settings page doesn't show the app, or a setting won't stay on (seen on Samsung phones), close all apps, restart the phone and try again. Tap **SOS through Do Not Disturb** in the same place and allow Do Not Disturb access, so Do Not Disturb can't silence an SOS. Then also set the app's **Battery** to **Unrestricted** (long-press the app icon → App info → Battery).
5. MeshCore Open SOS and MeshCore Open SOS Voice are separate apps from the original MeshCore Open and can be installed beside it (from 9.5.8; earlier MeshCore Open SOS builds replaced it).

### Linux

1. Make the AppImage executable and run it:
   ```bash
   chmod +x MeshCore_Open_SOS_Voice-x86_64.AppImage
   ./MeshCore_Open_SOS_Voice-x86_64.AppImage
   ```
2. On first run it adds itself to the applications menu and installs an uninstaller. Deleting the AppImage removes the menu entry automatically.
3. Closing the window leaves the app running in the system tray, still listening for alerts. Use the tray menu's **Quit** to stop it. The tray libraries are bundled, so nothing else needs installing.
4. To have it start hidden in the tray at login, turn on **Settings → App Settings → Start when you log in**.

### Windows

1. Run the setup program. It installs for the current user and doesn't need administrator rights. The installer isn't signed yet, so Windows may show "Windows protected your PC": click **More info**, then **Run anyway**.
2. Choose whether to start it at sign-in. It then runs hidden in the tray, listening for alerts.
3. For SOS Voice, allow the microphone: **Settings → Privacy & security → Microphone**, with both "Microphone access" and "Let desktop apps access your microphone" turned on.
4. Windows PCs have no GPS, so a desktop SOS uses the radio's location or the stored emergency location.

---

## User guide

### 1. Set up a network (coordinator, once)

1. **Settings → App Settings → Emergency SOS → Emergency network → Set up a new network**, and give it a name, for example "Station SOS".
2. The app shows a **member code** and a **responder code**. Give the responder code to the people who should get the alarm, and the member code to everyone else who might need to send.
3. The codes can be shown again from the same screen whenever someone new joins.

### 2. Join a network (everyone else, once)

**Emergency network → Join with a code**, then scan the QR code or type the code. Case, spaces and dashes don't matter. The app shows the network's name and your role before you confirm.

While travelling: log in to a local repeater as a guest and open **Operator info**. If the operator has posted an area code, tap **Join**.

### 3. Fill in your emergency settings

| Setting | What to put |
|---|---|
| Stored emergency location | Your base, used when neither phone nor radio has a position. **Use current GPS** fills it in. |
| Emergency contacts | People who always get the SOS by direct message, even if they use another MeshCore app. |
| Include favourite contacts | On by default: favourites get the DM too. |

Open the **Emergency** tab once so the app can ask for location permission ahead of time.

### 4. Sending an SOS

1. Open the **Emergency** tab.
2. **Press and hold the red SOS button for two seconds.** Letting go early cancels.
3. The card shows **SOS ACTIVE**, how many times it has been sent, when it will next be sent, the position used, who has acknowledged, and the delivery status of each emergency contact's DM.
4. When you're safe, press **Cancel SOS** and confirm. Everyone is told it is over.

If the radio disconnects, the SOS keeps its schedule and sends whatever came due as soon as the radio reconnects, even after an app restart.

### 5. Responding to an SOS

1. The red warning appears over whatever you're doing.
2. Press **Send ACK** so the sender knows they've been heard. Other responders see that you've acknowledged.
3. Use **Map** or copy the coordinates to navigate.
4. Press **Message** to chat with the sender directly.
5. Near the sender but can't find them? Press **Locate** and follow the signal: walk a little, stop, and wait for the next beacon. Stronger means closer. With other searchers, open **Search map** to see everyone's readings and the area to search, and agree among yourselves when to turn the **Beacon power** down.
6. **Dismiss** puts it aside without replying: the alarm stops and it shrinks to a line on the Emergency tab, with **Show again** to pick it up at once (its position, your acknowledgement and Locate are kept). If you hadn't acknowledged it, the sender's next repeat brings it back with the alarm; an acknowledged one stays put aside until you tap Show again.

### 6. Talking (SOS Voice only)

See [Voice](#voice-sos-voice-only) below.

### Backing up your radio

**Settings → Backup and restore → Export config** saves the radio's identity (its private key), name, radio settings, channels and contacts, with this app's emergency network, home location and emergency contacts, in one file. **Import config** puts it back after a firmware update or erase, or onto a new radio that takes over the old one's identity. A MeshCore SOS radio's web page reads and writes the same file; its WiFi and button settings come back only through that page. Keep the file private: anyone with it can pretend to be your radio.

### Managing a repeater

Log in to a repeater as admin and open **Settings**: nothing is read from the repeater until you ask, to save air time. Tap **⟳** next to the setting you want to see or change, and only that one is read; its field stays greyed out until then. The **⟳** at the top reads everything, which over several hops is slow and loads the mesh, so use it sparingly. (Since 9.7.1.)

### Practising

Agree on a time with your group, then send a test SOS, acknowledge it and cancel it. Make sure everyone's phone actually sounds, and that background running is allowed on each Android phone. To explore the screens without a radio, use review mode: on the Connect screen, long-press the app's name at the top ("MeshCore Open SOS" or "MeshCore Open SOS Voice") and tap **Enter**.

---

## Voice (SOS Voice only)

The **Voice** panel sits in the active SOS card for the sender and in each alert for responders.

| Control | What it does |
|---|---|
| **Hold to talk** | Records while held and sends when you let go. Anything under half a second counts as an accidental tap. |
| **Hands-free** | Keeps the microphone open. Each stretch of speech is sent when you pause for about a second, which helps when your hands are busy or you're injured. Works with the screen off on Android. |
| **Low / Clear** | Low (700 bit/s) is the default and allows clips of up to 20 s. Clear (1300 bit/s) is easier to understand but limited to 10 s, and uses about twice the airtime. |
| Clip list | Shows who spoke, how long, and Sending… / Sent / Received status. Play any clip again. |

Clips play aloud as they arrive, one after another. While a clip is playing, hands-free ignores the microphone so it never sends the speaker's sound back out.

**Tips**

- Keep it short: "Alex, rolled the quad at the north dam, leg's hurt, can't walk." Every clip uses airtime that the whole mesh shares.
- Expect a delay of a few seconds per hop. Wait for a reply before talking again.
- If a packet is lost, the clip has a gap. If the last packet is lost, the clip isn't played: say it again or send a text.
- Voice stops working when the SOS is cancelled.

---

## Privacy and security

An SOS carries your position, so the apps keep it out of anything that can be scrolled back through later, except with the emergency contacts you chose:

- Channel alerts are hidden data packets and never appear in a channel chat, in this app or any other MeshCore app.
- SOS DMs go only to your chosen emergency contacts. The sending app keeps them out of its own chat history; a receiving MeshCore Open raises the alarm and also keeps the message in the chat with you, so the contact can read it.
- A live alert leaves the Emergency tab when the sender cancels, or after 60 minutes with no repeat. A dismissed one stays as a line with **Show again** until then.
- The **SOS history** keeps a record of every alert received or sent, positions included, until you delete it, so it can be handed to paramedics or emergency services afterwards.
- Voice clips are kept in memory for the live SOS only.

What it can't protect against:

- **Keep responder codes private.** On a sealed (`SOS2-`) network a responder code reads every alert; a member code reads none. If a responder code leaks, set up a new network.
- **Anyone with a code can send an alert**, including a fake one, and a sender's name isn't verified. A member code posted on a repeater lets anyone send alerts to that network's responders, so an area network for travellers should be separate from a family's or team's own.
- **Older (`SOS1-`) networks** hold the same key in both codes, so their members could read alerts with modified software, and fake acknowledgements. Set up a new network.
- **How it's sealed:** X25519 between each SOS's one-off key and the network key; AES-128-CTR and an 8-byte HMAC-SHA256 tag, inside MeshCore's own channel encryption. Repeaters and radios outside the network see only MeshCore's encrypted channel packets.

---

## Limitations

- Delivery over LoRa is best effort. Hills, distance and busy airtime all cost packets. The repeat schedule exists because of this.
- The network uses one of the radio's channel slots.
- **iOS** may suspend the app in the background, so repeats can be late, and alerts don't break through silent mode or Focus (that needs Apple's Critical Alerts entitlement). The SOS builds have not been packaged for iOS.
- **Windows** has no phone GPS. Use a radio with GPS or set a stored location.
- **Voice** has been tested between two radios on Android and Linux. It still needs testing across several repeater hops and with more people on one network. The Windows voice build is new, and its microphone and playback still need confirming on more PCs.
- The repeat intervals are fixed in this version.

---

## Why it should be included, used and developed further

**1. It answers the most important question a mesh can answer.** Off-grid messaging is useful every day. Being able to get help when you're hurt and alone is the reason many people would put a radio in their pocket in the first place. A dependable SOS turns MeshCore from a hobby network into safety equipment that farms, councils, parks and volunteer services can justify buying and deploying.

**2. It costs the network almost nothing.** No firmware change, no new packet types in the firmware, no servers. It uses the channel-data and direct-message features MeshCore already has. Existing repeaters forward it, and other MeshCore apps can read the text DM and reply. Anyone running a stock radio can take part today.

**3. It is designed for how emergencies actually go.** It repeats until cancelled, not until the first ACK. Position falls back from phone GPS to radio GPS to a stored location. The alarm can't be swiped away. Responders can see each other's ACKs so they coordinate instead of all driving out. The sender and responders become contacts automatically. A disconnected radio catches up when it reconnects. These choices come from thinking about a person who is injured, panicked, or has a flat phone battery.

**4. It treats location as sensitive, and keeps a record.** Positions only reach the chats of the emergency contacts the sender chose, and live alerts close when the emergency ends. A record of each alert stays in the SOS history, on that phone only, until the user deletes it, so it can be passed on to paramedics or emergency services. This matters for people who are rightly wary of broadcasting where they live and work.

**5. It grows the mesh.** Emergency networks give communities a concrete reason to put up repeaters, and the owner-info code lets travellers join the local network. Every repeater that goes up for safety also carries everyday traffic.

**6. Voice is used carefully.** Codec2 at 700 bit/s fits a usable spoken message into a dozen LoRa packets. Limiting voice to a live SOS gives an injured person who can't type a way to be understood, without opening the network to general voice traffic that would swamp it. It is also groundwork: the same chunked-clip transport could later carry voice to a single contact if the community wants that.

**7. It is ready for review.** Both builds pass the project's analyzer and tests (over 1,000 tests on each branch), the strings are translated into all 18 locales, the behaviour is documented, and there are installers for Android, Linux and Windows. The changes are on their own branches and can be reviewed and merged in pieces.

**8. Separate builds keep the risk low.** SOS and SOS Voice are separate apps with separate IDs, so voice can be field-tested without risking the stable SOS build that people may already depend on.

---

## Roadmap and help wanted

- **Wider field testing**: more radios, more people and several repeater hops, especially for voice. Reports of delivery rates and clip quality at different radio settings are the most useful contribution right now.
- iOS and macOS packaging, and Critical Alerts on iOS.
- Signed Windows installer.
- Configurable repeat intervals, and an automatic SOS on fall or crash detection.
- Optional signatures on SOS and ACK, so alerts can't be spoofed.
- Voice to a single contact outside an SOS, if it can be kept from crowding the airtime.
- Upstreaming into MeshCore Open, in reviewable steps, if the maintainers want it.

Discussion and issues are welcome. Please target `dev` and discuss larger changes first, as described in [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Building from source

Requires Flutter 3.47 or later; Android needs Java 17.

```bash
git checkout feat/emergency-sos      # MeshCore Open SOS
git checkout feat/sos-voice          # MeshCore Open SOS Voice

flutter pub get
flutter test
flutter build apk --release          # Android

flutter build linux --release        # Linux, then package it:
linux/appimage/build-appimage.sh /path/to/appimagetool-x86_64.AppImage
```

The AppImage is written to `build/appimage/`. Building it needs `libayatana-appindicator3-1` and `sound-theme-freedesktop` on the build machine.

Windows (in PowerShell, with Visual Studio 2022, Git and Inno Setup 6 installed):

```powershell
powershell -ExecutionPolicy Bypass -File windows\installer\build-windows.ps1
```

The installer is written to `build\windows\installer\`.

SOS Voice builds Codec2 from source as part of the app (`packages/codec2_ffi`), so no extra libraries are needed.

---

## Licences, credits and disclaimer

**MeshCore Open** is © 2025 zjs81 and contributors, under the MIT licence: see [LICENSE](LICENSE). MeshCore Open SOS and MeshCore Open SOS Voice build on it.

**The SOS and SOS Voice additions** are © 2026 fltsim737 and released under the same MIT licence.

**Codec2** (SOS Voice only): SOS Voice includes the speech subset of Codec2 1.2.0, © David Rowe and contributors, under the **GNU Lesser General Public License 2.1**. It's built as a separate library that the app loads, and its full source, licence text (`src/codec2/COPYING`) and the changes made to it (variable-length arrays replaced so it builds with MSVC) are in [packages/codec2_ffi](packages/codec2_ffi), and in each release's Windows source zip. You may replace it with your own modified build of Codec2.

**flserial** (USB serial on Windows and Linux), in [third_party/flserial](third_party/flserial), is © 2024 Grzegorz Leśniak, under the MIT licence.

**Other Flutter and Dart packages** used by the apps keep their own licences (mostly BSD, MIT and Apache 2.0). The app lists them all under **Settings → About → View licenses**.

**Not affiliated.** MeshCore Open SOS and SOS Voice are independent community builds. They aren't made, endorsed or supported by the MeshCore project, rippleradios.com or the MeshCore Open maintainers; "MeshCore" is used only to say what they work with. The separate MeshCore SOS radio firmware is proprietary and isn't covered by this repository's licence.

**Disclaimer.** The apps are provided "as is", without warranty of any kind, as the MIT licence says; that licence's disclaimer and limitation of liability cover all their authors and copyright holders, zjs81 and contributors and fltsim737 alike. In plain words:
- they **aren't a certified emergency, medical or personal alarm**, and nobody monitors them;
- an SOS sent over a LoRa mesh is **best effort**: it can be late or not arrive at all, and an acknowledgement means someone received it, not that help is coming;
- **don't rely on them as your only way of calling for help**: keep using 000, a registered PLB, a satellite messenger or a phone;
- to the maximum extent the law allows, the authors aren't liable for any loss, damage, injury or death arising from using them or from them not working. Nothing here excludes rights you have under the Australian Consumer Law, or similar laws, that can't be excluded.
