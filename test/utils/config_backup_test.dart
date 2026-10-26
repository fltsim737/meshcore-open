import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/utils/config_backup.dart';

final _key = 'ab' * 64;
final _pub = '84' * 32;

/// The shape the SOS radio's web page exports.
Map<String, dynamic> _webFile() => {
  'format': 'meshcore-sos-backup',
  'format_version': 1,
  'made': '2026-10-26T07:00:00.000Z',
  'firmware': 'sos-1.2.4',
  'settings': {
    'name': 'MeshCore SOS 845B',
    'radio': {
      'freq': 915.8,
      'bw': 250.0,
      'sf': 11,
      'cr': 5,
      'tx': 22,
      'tx_max': 22,
      'hash': 0,
    },
    'network': {'set': true, 'role': 'R'},
    'home': {'lat': -30.98, 'lon': 151.6},
    'info': 'Back door key under the pot',
    'location': 'home',
    'trigger': {'mode': 'off'},
    'pin': 0,
    'autoadd': {'flags': 31, 'max_hops': 0},
    'tone': 'morse',
    'contacts': [],
  },
  'channels': [
    {'name': 'Public', 'secret': '8b3387e9c5cdea6ac9e5edbaa115cd72'},
  ],
  'secrets': {
    'public_key': _pub,
    'private_key': _key,
    'network_code': null,
    'wifi': {'ssid': 'Home', 'pwd': 'x', 'mode': 2, 'hotspot_pwd': ''},
    'contacts': [
      {'key': 'cd' * 32, 'type': 2, 'flags': 0, 'name': 'Walcha'},
      {'key': 'not hex', 'type': 1, 'flags': 0, 'name': 'Broken'},
    ],
  },
};

void main() {
  test('reads a config exported by the SOS radio web page', () {
    final backup = ConfigBackup.parse(jsonEncode(_webFile()));
    expect(backup, isNotNull);
    expect(backup!.name, 'MeshCore SOS 845B');
    expect(backup.publicKeyHex, _pub);
    expect(backup.channels, hasLength(1));
    // a contact without a full key is left out
    expect(backup.contacts.map((c) => c['name']), ['Walcha']);
    // WiFi and the button settings are for the web page to restore
    expect(backup.hasRadioOnlySettings, isTrue);
  });

  test('a byte order mark is ignored', () {
    expect(ConfigBackup.parse('﻿${jsonEncode(_webFile())}'), isNotNull);
  });

  test('refuses files that are not a config', () {
    expect(ConfigBackup.parse('not json'), isNull);
    expect(ConfigBackup.parse('[]'), isNull);
    expect(
      ConfigBackup.parse(jsonEncode({..._webFile(), 'format': 'other'})),
      isNull,
    );
    expect(
      ConfigBackup.parse(jsonEncode({..._webFile(), 'format_version': 2})),
      isNull,
    );
    final noKey = _webFile();
    (noKey['secrets'] as Map)['private_key'] = 'abcd';
    expect(ConfigBackup.parse(jsonEncode(noKey)), isNull);
  });

  test('an app-made config has no settings only the web page restores', () {
    final file = _webFile();
    final settings = file['settings'] as Map;
    for (final k in ConfigBackup.radioOnlyKeys) {
      settings.remove(k);
    }
    (file['secrets'] as Map).remove('wifi');
    final backup = ConfigBackup.parse(jsonEncode(file));
    expect(backup!.hasRadioOnlySettings, isFalse);
  });

  test('suggests the file name the web page uses', () {
    final backup = ConfigBackup.parse(jsonEncode(_webFile()))!;
    expect(
      backup.suggestedFileName,
      matches(
        r'^meshcore-sos-config-MeshCore-SOS-845B-\d{4}-\d{2}-\d{2}\.json$',
      ),
    );
  });
}
