import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/radio_settings.dart';

RadioSettings _preset(String name) =>
    RadioSettings.presets.firstWhere((p) => p.$1 == name).$2;

void main() {
  test('Australia (Narrow) is 916.575 MHz, 62.5 kHz, SF7, CR 4/7, 22 dBm', () {
    final p = _preset('Australia (Narrow)');
    expect(p.frequencyHz, 916575);
    expect(p.bandwidth, LoRaBandwidth.bw62_5);
    expect(p.spreadingFactor, LoRaSpreadingFactor.sf7);
    expect(p.codingRate, LoRaCodingRate.cr4_7);
    expect(p.txPowerDbm, 22);
  });

  test('every Australian preset defaults to 22 dBm', () {
    final au = RadioSettings.presets.where((p) => p.$1.startsWith('Australia'));
    expect(au, hasLength(4));
    for (final p in au) {
      expect(p.$2.txPowerDbm, 22, reason: p.$1);
    }
  });
}
