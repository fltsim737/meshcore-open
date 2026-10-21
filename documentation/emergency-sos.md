# Emergency SOS

The **Emergency** tab sends a repeating distress alert over the mesh and shows alerts from other nodes. It is built for remote areas and farms with no internet or mobile coverage, so everything runs over the radio with ordinary MeshCore text messages. No firmware change is needed, and nodes running other MeshCore clients can still read the alert as plain text.

> An SOS is best effort. LoRa delivery is never guaranteed, and an ACK only means someone received your alert, not that help is on the way. Keep using every other means of calling for help that you have.

## Setup

Open **Settings → App Settings → Emergency SOS**:

| Setting | What it does |
|---|---|
| **Stored emergency location** | A fixed position (for example the homestead) used when neither the phone nor the radio has a position. **Use current GPS** fills it in from the phone. Leave both fields empty to remove it. |
| **SOS channel** | The channel the SOS is broadcast on. Defaults to the first channel (normally Public); choose a private emergency channel if your group has one. If the chosen slot no longer exists on the radio, the first channel is used. |
| **Include favourite contacts** | Also send the SOS by direct message to every favourite chat contact (default on). |
| **Emergency contacts** | Chat contacts that always receive the SOS by direct message. |

These settings belong to the phone, not the radio, so they stay the same whichever radio you connect.

When you first open the Emergency tab, the app asks for location permission. It asks then rather than when you send, so the SOS is never held up by a permission dialog.

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
| Immediately | Channel broadcast and a direct message to each emergency contact |
| Every minute for the first 5 minutes | Repeated quickly, so anyone who missed the first copy soon hears another |
| Every 5 minutes after that | Repeated until you cancel, whether or not anyone has acknowledged |

So broadcasts go out at 0, 1, 2, 3, 4 and 5 minutes, then at 10, 15, 20 minutes and so on. An ACK does not slow the schedule: it proves someone received the alert, not that help is on the way. The SOS stays active until you press **Cancel SOS**.

### Cancelling

**Cancel SOS** (after a confirmation) stops everything at once:

- no further repeats, and a broadcast that is partway through sending stops before its remaining DMs;
- SOS direct messages still queued or being retried are withdrawn and shown as failed in the chat;
- a cancellation notice goes out on the SOS channel and by DM to every emergency contact, including those who already acknowledged.

If the radio is disconnected when you cancel, the notice is sent as soon as it reconnects, even after an app restart.

Direct messages stop going to a contact once their radio confirms delivery or they reply ACK (on the channel or by DM). A new DM is not queued while the previous one is still being retried. The channel broadcast always continues.

Each repeat is a new packet carrying the same ID. Repeaters forward every one, and receivers merge them into a single alert with the latest position.

### Location source

Each broadcast looks up a position, in this order:

1. **Phone GPS**: a recent last-known fix (under 2 minutes old) is used straight away. Otherwise the app waits up to 8 seconds for the first broadcast and 20 seconds for repeats.
2. **Radio location**: the position the radio advertises, from its own GPS or one set under Settings → Location. A radio reporting 0, 0 counts as having no position.
3. **Stored emergency location**.
4. **None**: the SOS is still sent, without coordinates.

The source is included in the message.

## Message format

Channel broadcast. The radio adds `<node name>: ` in front automatically:

```
*** EMERGENCY SOS *** #a1b2
Time: 10-21 14:32Z
Source: Phone GPS
Lat: -41.28646
Lon: 174.77624
Reply ACK #a1b2
```

Direct messages add a `Node: <name>` line after the first line, shortening the name if that is needed to fit. `Source` is one of `Phone GPS`, `Radio location`, `Stored location` or `None`, and the `Lat`/`Lon` lines are left out when there is no position. Time is UTC. The longest form fits within the firmware's 160-byte text limit on every channel and node name.

A cancellation is:

```
*** SOS CANCELLED *** #a1b2
Time: 10-21 14:32Z
The sender cancelled this SOS.
```

An acknowledgement is the text `ACK #a1b2`. Anyone can type it by hand, so responders on other MeshCore clients can answer too.

SOS, cancellation and ACK texts are always sent uncompressed. Smaz and Cyr2Lat are skipped for them, so every client can read them.

## Receiving an SOS

When an SOS arrives on any channel or by direct message:

- A full-screen red **EMERGENCY SOS** warning covers the app, showing who sent it, the position and source, and when it was first and last heard. It cannot be navigated away from. It stays until you press **Send ACK** or **Dismiss**, and if several alerts are open they are shown one at a time, oldest first.
- A dedicated SOS notification replaces the ordinary message notification (see [platform behaviour](#platform-behaviour)).
- The alert is listed in the Emergency tab with **Send ACK**, **Dismiss**, **Map** and copy-coordinates actions. The Emergency tab icon shows a badge while any alert is open.

**Send ACK** replies `ACK #id` on the channel the alert arrived on, and also by direct message when the sender is one of your contacts. It is disabled while no radio is connected, so an alert is never marked answered when no ACK went out. Other responders' ACKs are shown on the alert ("Also acknowledged by …"), so a group can see who has already answered.

When the sender cancels, the alert closes on its own: the alarm and warning screen stop, the alert is marked **Cancelled by sender**, and an "SOS from … cancelled" notification replaces the alarm. Only a cancellation from the same sender closes an alert; a late repeat of a cancelled SOS does not reopen it.

**Dismiss** silences the alert on this phone without replying. Repeats of an acknowledged or dismissed alert still update its position and counts, but they don't sound again.

On the sending phone, each new responder's ACK raises an "SOS acknowledged by …" notification.

Alerts and the active SOS are saved, so they survive an app restart. Up to 50 resolved alerts are kept, and open alerts are never removed.

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

- **Spoofing.** Anyone with the channel key can send a fake SOS or ACK, and sender names on channels are not verified. The Public channel key is widely known, so use a private channel when trust matters.
- **Region scope.** The broadcast follows the SOS channel's region setting, like any other message on that channel (see [Regions](regions.md)).
- **Airtime.** Repeats and direct messages use airtime; the six broadcasts in the first five minutes are the busiest stretch. The intervals are fixed in v1.
- **Chat history.** SOS and ACK texts also appear as ordinary messages in the channel or contact chat.
