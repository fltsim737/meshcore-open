# Navigation

## App Flow

The app follows this general flow:

```
Launch → Scanner Screen → [Connect via BLE/USB/TCP] → Channels Screen
```

After connecting, the three main screens (Contacts, Channels, Map) are accessible via a persistent bottom navigation bar called the **QuickSwitchBar**.

## Quick Switch Bar

The QuickSwitchBar is a Material 3 `NavigationBar` with a frosted-glass visual treatment (blur backdrop, transparent theme, rounded corners). It appears at the bottom of all four main screens.

| Index | Icon | Label | Screen |
|---|---|---|---|
| 0 | People | Contacts | ContactsScreen |
| 1 | Tag | Channels | ChannelsScreen |
| 2 | Map | Map | MapScreen |
| 3 | SOS (red) | Emergency | EmergencyScreen |

Tapping a tab replaces the current screen with a subtle fade + slight horizontal nudge transition (220ms forward, 200ms reverse). The back button is suppressed on all four main screens — navigation between them is flat, not stacked. All icons use outline variants (`people_outline`, `tag`, `map_outlined`) following Material 3 conventions, except the red `sos` icon. The Emergency tab shows a count badge while incoming SOS alerts are open, and a dot while your own SOS is active. See [Emergency SOS](emergency-sos.md).

## Disconnection

- The disconnect button (available in the overflow menu of each main screen) shows a confirmation dialog before disconnecting
- If the device disconnects unexpectedly, the app automatically navigates back to the Scanner screen (fires after the current frame completes via a post-frame callback)
- This auto-navigation behavior (`DisconnectNavigationMixin`) is shared across all main screens

## Theme and Locale

- **Theme mode** is user-configurable in App Settings (System / Light / Dark) — not locked to system
- **Language** can be overridden to one of 18 supported languages, or follow the system locale
- On web, if a non-Chromium browser is detected, the app shows a `ChromeRequiredScreen` instead of the Scanner (the web client needs Chrome for Web Serial USB)

## Full Navigation Graph

```
ScannerScreen (root, always on stack)
  ├─ [BLE connect] → push → ChannelsScreen
  ├─ [TCP icon button] → push → TcpScreen
  │     └─ [TCP connected] → pushReplacement → ChannelsScreen
  └─ [USB icon button] → push → UsbScreen
        └─ [USB connected] → pushReplacement → ChannelsScreen

ContactsScreen (selected=0)
  ├─ [quick-switch 1] → pushReplacement → ChannelsScreen
  ├─ [quick-switch 2] → pushReplacement → MapScreen
  ├─ [quick-switch 3] → pushReplacement → EmergencyScreen
  ├─ [tap contact] → push → ChatScreen
  ├─ [overflow > Settings] → push → SettingsScreen
  └─ [overflow > Discovered] → push → DiscoveryScreen

ChannelsScreen (selected=1)
  ├─ [quick-switch 0] → pushReplacement → ContactsScreen
  ├─ [quick-switch 2] → pushReplacement → MapScreen
  ├─ [quick-switch 3] → pushReplacement → EmergencyScreen
  ├─ [tap channel] → push → ChannelChatScreen
  └─ [overflow > Settings] → push → SettingsScreen

MapScreen (selected=2)
  ├─ [quick-switch 0] → pushReplacement → ContactsScreen
  ├─ [quick-switch 1] → pushReplacement → ChannelsScreen
  ├─ [quick-switch 3] → pushReplacement → EmergencyScreen
  ├─ [radar menu item] → enters in-map path trace mode (push → PathTraceMapScreen after path is built)
  ├─ [terrain menu item] → push → LineOfSightMapScreen
  └─ [long-press] → share marker sheet

EmergencyScreen (selected=3)
  ├─ [quick-switch 0/1/2] → pushReplacement → Contacts / Channels / Map
  └─ [alert Map button] → push → MapScreen (highlighting the SOS position)

SosWarningOverlay (drawn above every route while an incoming SOS is open;
  not a route, so only Send ACK or Dismiss removes it)

Settings (push from any main screen)
  └─ [App Settings] → push → AppSettingsScreen
        └─ [Offline Map Cache] → push → MapCacheScreen
```

Screens using disconnect navigation trigger `popUntil(route.isFirst)`, returning to the Scanner.

## Additional settings destinations

Settings → Regions opens [region management](regions.md). Settings → Radio stats opens [companion statistics](radio-statistics.md), including self-telemetry access. Settings → Telemetry opens telemetry for your own radio directly. App Settings contains image model setup and translation model controls. Contact QR scanning is available from Contacts; community QR scanning is available from Channels.
