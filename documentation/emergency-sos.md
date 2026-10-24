# Emergency SOS

The **Emergency** tab sends a repeating distress alert over the mesh and shows alerts from other nodes. It is built for remote areas and farms with no internet or mobile coverage, so everything runs over the radio. No firmware change is needed.

Because an SOS carries your position, it only reaches a chat history on the phones of the emergency contacts you chose; channel alerts never do. See [Privacy](#privacy).

> An SOS is best effort. LoRa delivery is never guaranteed, and an ACK only means someone received your alert, not that help is on the way. Keep using every other means of calling for help that you have.

## Setup

Open **Settings → App Settings → Emergency SOS**:

| Setting | What it does |
|---|---|
| **Stored emergency location** | A fixed position (for example the homestead) used when neither the phone nor the radio has a position. **Use current GPS** fills it in from the phone. Leave both fields empty to remove it. |
| **Emergency network** | The private, hidden channel your group's SOS alerts go out on. Set one up or join one with a code; see [Emergency network](#emergency-network). Without one, your SOS goes only to your emergency contacts by DM. |
| **Include favourite contacts** | Also send the SOS by direct message to every favourite chat contact (default on). |
| **Emergency contacts** | Chat contacts that always receive the SOS by direct message. |

These settings belong to the phone, not the radio, so they stay the same whichever radio you connect.

When you first open the Emergency tab, the app asks for location permission. It asks then rather than when you send, so the SOS is never held up by a permission dialog.

## Emergency network

An emergency network is a private channel for one group, such as a farm team. Nobody without one of its codes can read it.

**Set up (coordinator, once).** Settings → App Settings → Emergency SOS → **Emergency network** → **Set up a new network**, and give it a name. The app generates a random key and shows two codes, each as text and as a QR code:

| Code | Who it is for | What they get |
|---|---|---|
| **Member code** | People who can send an SOS but should not see alerts | The channel is hidden from them everywhere; their SOS goes into it; they still see ACKs for their own SOS |
| **Responder code** | People who receive alerts | The channel appears in their Channels list so they can chat on it, and SOS alerts on it raise the alarm |

The coordinator joins as a responder and can show the codes again at any time.

**Join (everyone else, once).** **Emergency network → Join with a code**, then scan the QR code or type the code (for example `SOS1-R-ABCD-…`; case, spaces and dashes do not matter). The app confirms the network name and role before joining.

**Sharing a code for an area.** A repeater operator can put a member code in the repeater's owner info (Settings → Owner Info), for example `Area SOS: SOS1-M-ABCD-…`. Anyone who logs in to the repeater as a guest can open **Operator info**, where the app picks out the code and offers **Join**. A code written this way carries no network name, so it joins as "Emergency". Only post a member code: owner info is readable by every guest.

**On the radio.** The app adds the network's channel to a free slot on the connected radio, and again on any other radio you connect later. If the radio has no free slot, the settings say so; remove a channel to make room. **Leave network** removes the channel from the radio and deletes alerts heard on it.

**What the roles do and do not protect.** Both codes contain the same channel key, because anyone who sends an SOS needs it to encrypt. The difference between member and responder is enforced by the app: a member using modified software could read alerts. Anyone given a code can send alerts. If a code leaks, set up a new network and share new codes. Other MeshCore apps connected to the same radio will list the network's channel.

## Sending an SOS

Press and hold the red **SOS** button for two seconds. A ring fills while you hold it, and letting go early cancels. With TalkBack or VoiceOver, double-tap and hold the button to send. Once sent, the tab shows:

- **SOS ACTIVE** and the alert ID (for example `#a1b2`)
- how many times it has been sent, and when the next broadcast is due
- the location source and coordinates used last time
- everyone who has acknowledged it
- each emergency contact's direct message status: *Waiting*, *Delivered* (their radio confirmed receipt), or *Acknowledged*

### Repeat schedule

| When | What is sent |
|---|---|
| Immediately | Alert on your emergency network and a direct message to each emergency contact |
| Every minute for the first 5 minutes | Repeated quickly, so anyone who missed the first copy soon hears another |
| Every 5 minutes after that | Repeated until you cancel, whether or not anyone has acknowledged |

So broadcasts go out at 0, 1, 2, 3, 4 and 5 minutes, then at 10, 15, 20 minutes and so on. An ACK does not slow the schedule: it proves someone received the alert, not that help is on the way. The SOS stays active until you press **Cancel SOS**.

### Cancelling

**Cancel SOS** (after a confirmation) stops everything at once:

- no further repeats, and a broadcast that is partway through sending stops before its remaining DMs;
- a cancellation notice goes out on the emergency network and by DM to every emergency contact and to every responder who acknowledged, even one who isn't an emergency contact.

A single copy is easily lost, so the notice goes out on the network three times, a minute apart, and each DM is sent again with it until that person's radio confirms delivery. If the radio is disconnected when you cancel, the notice is sent as soon as it reconnects, even after an app restart.

If an ACK for the SOS still arrives after you cancelled, that responder missed the notice, so the app sends it to them again (by DM when they are a contact, otherwise on the network), at most once a minute each.

Only the sender can cancel an SOS for everyone. A responder can't, because one person's mistaken guess would silence the alert for every other responder. A responder who is sure it's over can **Dismiss** it on their own phone.

Direct messages stop going to a contact once their radio confirms delivery or they reply ACK (on the channel or by DM). The channel alert always continues.

Each repeat is a new packet carrying the same ID. Repeaters forward every one, and receivers merge them into a single alert with the latest position.

### Location source

Each broadcast looks up a position, in this order:

1. **Phone GPS**: a recent last-known fix (under 2 minutes old) is used straight away. Otherwise the app waits up to 8 seconds for the first broadcast and 20 seconds for repeats. Windows skips this step: it has no GPS, and its network-based estimate can be kilometres out.
2. **Radio location**: the position the radio advertises, from its own GPS or one set under Settings → Location. A radio reporting 0, 0 counts as having no position.
3. **Stored emergency location**.
4. **None**: the SOS is still sent, without coordinates.

The source is included in the message.

## Message format

**On the emergency network channel** the SOS, ACK and cancellation travel as binary channel-data packets (type `0x5053`), not text. Packets on any other channel are ignored. No chat in MeshCore Open or any other MeshCore app shows or stores them; only MeshCore Open's Emergency tab reads them. The layout is in the [protocol reference](ble-protocol.md#emergency-sos-packets).

**Direct messages** to emergency contacts are text, so a contact using another MeshCore app still understands them:

```
*** EMERGENCY SOS *** #a1b2
Node: Farmhouse
Info: Lot 14, back gate   (optional)
Time: 10-21 14:32Z
Source: Phone GPS
Lat: -41.28646
Lon: 174.77624
Reply ACK #a1b2
```

The node name is shortened if needed to fit. `Source` is one of `Phone GPS`, `Radio location`, `Stored location` or `None`, and the `Lat`/`Lon` lines are left out when there is no position. Time is UTC. The longest form fits within the firmware's 160-byte text limit for every node name.

A cancellation is:

```
*** SOS CANCELLED *** #a1b2
Time: 10-21 14:32Z
The sender cancelled this SOS.
```

An acknowledgement is the text `ACK #a1b2`, which a contact on another MeshCore app can type by hand.

These texts are always sent uncompressed (Smaz and Cyr2Lat are skipped), so every client can read them.

## Privacy

An SOS carries your position, so MeshCore Open keeps it out of chat history everywhere except with the emergency contacts you chose:

- **Channel alerts are hidden data packets.** They never appear in a channel chat on any device, in MeshCore Open or other MeshCore apps.
- **SOS direct messages go only to people you chose.** The sending phone sends them straight to the radio without adding them to its own conversation. A receiving MeshCore Open raises the alarm from them and also keeps them in the chat with you, without a message notification, so the contact can read the text and any info line. They stay there like any message: you listed that person as an emergency contact, so they already have your trust.
- **Live alerts are short-lived.** An alert, with its position, leaves the Emergency tab when the sender cancels, when you dismiss it, or once no repeat has been heard for 60 minutes. Until then a responder who acknowledged keeps the position to navigate by.
- **The SOS history keeps a record of every alert** received or sent on this phone, positions included, until you delete it. See [SOS history](#sos-history).
- **Your own SOS** is cleared from the Emergency tab when you cancel it, and the alarm notification (which shows the position) is removed when an alert closes.

What the app cannot control:

- Anyone holding a network code and running modified software can capture its packets; see [what the roles protect](#emergency-network).
- An emergency contact keeps your SOS direct messages in their chat, in MeshCore Open or any other MeshCore app, until they delete them.

## Receiving an SOS

When an SOS arrives on your emergency network (responders only) or by direct message from someone who listed you as an emergency contact:

- A full-screen red **EMERGENCY SOS** warning covers the app, showing who sent it, its info line if it has one (such as a short address), the position and source, and when it was first and last heard. It cannot be navigated away from. It stays until you press **Send ACK** or **Dismiss**, or the sender cancels, and if several alerts are open they are shown one at a time, oldest first.
- A dedicated SOS notification replaces the ordinary message notification (see [platform behaviour](#platform-behaviour)).
- The alert is listed in the Emergency tab with **Send ACK**, **Dismiss**, **Map** and copy-coordinates actions. The Emergency tab icon shows a badge while any alert is open.

**Send ACK** replies with an ACK packet on the channel the alert arrived on, and also by direct message when the sender is one of your contacts. The alert stays in the Emergency tab, with its position, until the sender cancels or it expires. It is disabled while no radio is connected, so an alert is never marked answered when no ACK went out. Other responders' ACKs are shown on the alert ("Also acknowledged by …"), so a group can see who has already answered.

If an acknowledged alert goes quiet, with no repeat heard for 12 minutes (two missed repeats), the app sends the ACK again, then at most every 12 minutes until the alert closes. A sender who has cancelled answers with the cancellation this phone missed, and the alert closes. A sender who is still sending just hears the ACK again. Alerts you haven't acknowledged are never answered automatically.

When the sender cancels, the alert is deleted: the alarm and warning screen stop, and an "SOS from … cancelled" notification (without the position) replaces the alarm. Only a cancellation from the same sender does this.

**Dismiss** deletes the alert and its position from this phone without replying. If the sender is still broadcasting, the next repeat raises it again. Repeats of an acknowledged alert update its position and counts but don't sound again.

The same alert often arrives twice within a second or two: on the network and by direct message, when you are both a responder and one of the sender's emergency contacts. Both copies update the one alert, and the alarm sounds again only for a repeat heard 30 seconds or more after it last sounded. Sounding it again sooner would silence Android's looping alarm instead.

**Info line.** A sender's radio can add a line of text to the SOS, such as a short address, a gate code or how to find the house. The MeshCore SOS button firmware does this. It is shown on the warning screen, the alert in the Emergency tab and the notification. It travels after the public key in the channel packet and as an `Info:` line in the direct message, so older builds ignore it.

On the sending phone, each new responder's ACK raises an "SOS acknowledged by …" notification.

## Messaging each other

The SOS and each ACK on the emergency network carry the sender's full public key, so the two phones save each other as chat contacts without anyone swapping adverts first:

- A responder's radio saves whoever sent an SOS it heard.
- The sending radio saves each responder who acknowledged its SOS (ACKs for other people's alerts are not saved).

A **Message** button then appears on the alert (for the responder) and next to each responder in the active SOS card (for the sender), and opens an ordinary direct-message chat. New contacts are reached by flood until a route is learned. These messages are normal chat messages and stay in chat history. Received SOS direct messages appear there too; channel alerts never do. Alerts from builds without this, or from emergency contacts by DM, show the button only when the sender is already a contact.

The active SOS and live alerts survive an app restart; alerts that expired while the app was closed are deleted when it starts.

## Voice

While an SOS is live, the person who raised it and the responders can talk. On Android, a **Voice** panel appears in the active SOS card and in each alert a responder receives. It needs the emergency network: voice travels on its channel, like the alert itself.

- **Hold to talk** records while held and sends when released. Under half a second is treated as an accidental tap and not sent.
- **Hands-free** keeps the microphone open: each stretch of speech is sent when you pause for about a second, and a long speech goes out in pieces. Turning it on keeps the microphone available with the screen off (the background service adds the microphone type).
- Clips heard play aloud straight away, one after another. While one plays, hands-free ignores the microphone, so a reply is never picked up from the speaker and sent back out. Each clip can be played again from the list.
- **Low** quality (Codec2 at 700 bit/s) is the default and allows up to 20 s a clip; **Clear** (1300 bit/s) is easier to understand but allows up to 10 s and uses about twice the airtime.

Voice is not a live call. LoRa is far too slow to stream speech to a whole mesh, so speech is compressed with [Codec2](https://github.com/drowe67/codec2) and sent as a short clip of channel data packets, like an image. Each packet carries up to 1.7 s of speech in Low quality (0.9 s in Clear) and takes roughly 0.5–1 s to transmit, depending on the radio settings, at every hop. Expect a few seconds' delay, and keep clips short: every clip uses airtime that everyone on the mesh shares. A packet lost on the way leaves a gap in the clip; a clip whose last packet is lost is not played.

Voice packets use channel data type `0x5356` ("SV"). Layout (little-endian): `[version=1][quality][SOS id u16][sender key prefix x6][clip id u16][index][total][frame count]`, then the Codec2 frames bit-packed, most significant bit first. A clip has at most 12 packets of at most 163 bytes. Clients accept a clip only for their own active SOS or, as a responder, for an alert they hold, so voice stops when the SOS is cancelled.

## SOS history

Every SOS this phone receives or sends is recorded, so it can be passed on afterwards to paramedics, emergency services or an incident report. Open it from the **history** icon on the Emergency tab, or **Settings → App Settings → Emergency SOS → SOS history**, which also works with no radio connected.

Each record keeps:

- the alert ID, sender (name and public key) and info line;
- when it was first and last heard (or sent), how many times, and how (network, DM);
- every position heard, with its time and source;
- when this phone acknowledged, who else acknowledged and when, and, for your own SOS, whose radio confirmed the direct message;
- how it ended: cancelled by the sender, cancelled by you, dismissed, expired or left the network, and when.

Tap a record to see the full report. **Share** sends it as plain text (times in local time and UTC, positions and a map link) by SMS, email or any messaging app. Records are kept until you delete them: one at a time, or **Delete all finished**, which keeps records of alerts still in progress.

## Platform behaviour

| Platform | Phone GPS | Incoming alert sound | Repeats while in the background |
|---|---|---|---|
| Android | Yes | Alarm-volume two-tone sound that loops until you ACK or dismiss; the notification can't be swiped away | Yes, while the radio stays connected (foreground service) |
| iOS | Yes | Standard notification sound, again on each repeat the sender makes; follows silent mode and Focus | Best effort, see below |
| macOS | Yes | Standard notification sound | While the app is running |
| Windows, Linux | Yes, where a location service is present (Windows Location, GeoClue) | Desktop notification | While the app is running |
| Web | Browser location | No notifications; the warning screen is shown | While the tab is open |

**iOS limits.** iOS may suspend the app in the background, so a repeat can be late. A late repeat is sent as soon as the app returns to the foreground or the radio reconnects. Alerts do not break through silent mode or Focus: that needs Apple's Critical Alerts entitlement, which this app does not use.

**Disconnected radio.** If the radio disconnects, the Emergency tab returns to the scanner like the other main screens. An active SOS keeps its schedule: any broadcast that came due while disconnected is sent as soon as the radio reconnects. The warning screen for incoming alerts stays visible on every screen, including the scanner.

## Limitations

- **Spoofing.** Anyone with a network code can send a fake SOS or ACK, and sender names on channels are not verified.
- **Region scope.** The alert follows the network channel's region setting, like any other message on that channel (see [Regions](regions.md)).
- **Radio slots.** The network uses one of the radio's channel slots.
- **Airtime.** Repeats and direct messages use airtime; the six broadcasts in the first five minutes are the busiest stretch. The intervals are fixed in v1.
