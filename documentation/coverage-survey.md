# Coverage Survey

Coverage survey maps where repeaters can hear you while you travel. It is meant for searchers deciding when to switch frequency, and for groups working out where an existing repeater network reaches.

## How to access

**Map → ⋮ → Coverage survey.** Tap **Start survey**. The survey keeps running while you use other screens. Stop it from the same screen.

## What a ping is

A ping is MeshCore's zero-hop discover request (`CMD_SEND_CONTROL_DATA`, `DISCOVER_REQ`, repeater type only), the same request as the nearby-node scan. Every repeater in direct radio range answers with its key and the SNR at which it heard the ping. The companion adds the SNR and RSSI at which it heard the answer. Nothing travels beyond one hop, and no change is needed on the radio or the repeaters. It needs companion firmware v1.12 or newer (ver code 8).

## When pings go

| Rule | Value |
|---|---|
| Minimum interval | 30 s |
| Distance between pings | 150 m |
| Standing still | every 2 min |
| Reply window | 12 s |
| Paused | while any SOS is active or open, without a radio, without a position |

Stock repeaters answer at most 4 discover requests per 2 minutes, counting everyone together (`discover_limiter(4, 120)` in `simple_repeater`). With several searchers pinging, an unanswered ping may mean the repeater was rate-limited.

**Ping now** sends a ping once 30 s have passed since the last one.

## The map

- **Hexagons:** a fixed worldwide grid on the Web Mercator plane, with a circumradius of 70 Mercator metres (about 100 m across at 35°). Surveys from different phones land in the same cells.
- **Colour:** the best link heard in the cell. A link's SNR is the weaker of the two directions. It is graded by its margin over the LoRa decode floor for the current spreading factor (SF7 −7.5 dB, falling 2.5 dB per step to SF12 −20 dB):

  | Grade | Margin | Colour |
  |---|---|---|
  | Strong | ≥ 10 dB | green |
  | Good | 5–10 dB | light green |
  | Weak | 0–5 dB | amber |
  | Unreliable | < 0 dB | red |
  | No reply | pinged, nobody answered | grey |

- **Radar lines:** these run from the latest ping to each repeater that answered and advertises a location. They fade out over 25 s.
- **Layers:** every radio setting (frequency, bandwidth, SF, CR) is a separate layer, chosen from the drop-down. The layer for the radio's current setting is shown first.
- **One repeater:** tap a repeater marker, or pick it from the list, to show only the cells where it answered.
- **Out of coverage:** after 3 pings in a row with no answer, the phone vibrates and shows a warning.

## Position

Pings use the phone's GPS. Fixes less accurate than 100 m are ignored, so a desktop's rough WiFi- or IP-based position never paints the map. On Windows, with location off, or without an accurate fix, the radio's own position is used if it has one, and the screen says so. On Android the screen stays on during a survey (`FLAG_KEEP_SCREEN_ON`), so position updates keep arriving.

## Storage, export and import

Pings are stored in one JSON file in the app support folder. The file is shared by every radio you connect and holds up to 10,000 pings, after which the oldest drop off. **Clear survey** deletes it.

| Export | Contents |
|---|---|
| Survey (`.json`, format `meshcore-coverage-survey` v1) | Every ping: time, position, accuracy, radio setting, the maker's radio name, and each reply's key, name, SNR both ways, RSSI and position. Imports back and merges; duplicate pings (same time and position) are skipped. |
| GeoJSON | Cells (polygons with grade, best SNR and repeaters), repeaters and pings, for each layer. |
| KML | Styled cells and repeaters in one folder per layer, for Google Earth. |

Source: `lib/services/coverage_survey_service.dart`, `lib/models/coverage_survey.dart`, `lib/helpers/coverage_grid.dart`, `lib/helpers/coverage_export.dart`, `lib/screens/coverage_survey_screen.dart`.
