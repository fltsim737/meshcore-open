import 'dart:convert';
import 'dart:typed_data';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../helpers/sos_network_code.dart';
import '../services/app_settings_service.dart';
import '../services/sos_service.dart';

/// Export config / Import config: one file with the radio's identity
/// (private key), name, radio settings, auto-add settings, channels and
/// contacts, plus this app's emergency network and SOS settings.
///
/// The format is the one the MeshCore SOS radio's web page uses
/// (`meshcore-sos-backup` version 1), so a file from either opens in the
/// other. The SOS radio's own settings (WiFi, hotspot, switch and PRG
/// button, screen times, battery cutoff, info line) are only in a file
/// exported from its web page, and only the web page puts them back.
class ConfigBackup {
  static const String format = 'meshcore-sos-backup';
  static const int formatVersion = 1;
  static const int maxFileBytes = 2 * 1024 * 1024;

  /// Settings only the SOS radio's web page can restore.
  static const List<String> radioOnlyKeys = [
    'trigger',
    'prg',
    'cutoff',
    'screen',
    'linkscreen',
    'info',
    'location',
    'pin',
  ];

  final Map<String, dynamic> json;
  ConfigBackup._(this.json);

  Map<String, dynamic> get settings =>
      (json['settings'] as Map).cast<String, dynamic>();
  Map<String, dynamic> get secrets =>
      (json['secrets'] as Map).cast<String, dynamic>();
  String get name => (settings['name'] as String?) ?? '';
  String get publicKeyHex => (secrets['public_key'] as String?) ?? '';
  String get privateKeyHex => secrets['private_key'] as String;
  List<Map<String, dynamic>> get channels => [
    for (final c in (json['channels'] as List?) ?? const [])
      if (c is Map) c.cast<String, dynamic>(),
  ];
  List<Map<String, dynamic>> get contacts => [
    for (final c in (secrets['contacts'] as List?) ?? const [])
      if (c is Map && _isHex(c['key'], 64)) c.cast<String, dynamic>(),
  ];

  /// Made by the radio's web page, so it holds settings the app can't
  /// put back (WiFi and the SOS button's own settings).
  bool get hasRadioOnlySettings =>
      secrets['wifi'] != null || radioOnlyKeys.any((k) => settings[k] != null);

  String toJsonString() => const JsonEncoder.withIndent(' ').convert(json);

  /// The file name the web page also uses.
  String get suggestedFileName {
    var safe = name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]+'), '')
        .trim()
        .replaceAll(RegExp(r'\s+'), '-');
    if (safe.isEmpty) safe = 'radio';
    final day = DateTime.now().toIso8601String().substring(0, 10);
    return 'meshcore-sos-config-$safe-$day.json';
  }

  /// Null when [text] isn't a config file this version can read.
  static ConfigBackup? parse(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text.startsWith('﻿') ? text.substring(1) : text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final json = decoded.cast<String, dynamic>();
    if (json['format'] != format ||
        (json['format_version'] as num? ?? 0) > formatVersion ||
        json['settings'] is! Map ||
        json['secrets'] is! Map) {
      return null;
    }
    final backup = ConfigBackup._(json);
    if (!_isHex(backup.secrets['private_key'], 128)) return null;
    return backup;
  }

  /// Reads the connected radio and this app's emergency settings.
  static Future<ConfigBackup> read({
    required MeshCoreConnector connector,
    required AppSettingsService settingsService,
    required String appVersion,
  }) async {
    final privateKey = await connector.exportPrivateKey();
    final app = settingsService.settings;
    final net = app.sosNetwork;
    final freq = connector.currentFreqHz;
    final bw = connector.currentBwHz;
    final settings = <String, dynamic>{
      'name': connector.selfName ?? '',
      if (freq != null && bw != null)
        'radio': {
          'freq': freq / 1000.0, // MHz, as the web page keeps it
          'bw': bw / 1000.0, // kHz
          'sf': connector.currentSf,
          'cr': connector.currentCr,
          'tx': connector.currentTxPower,
          'tx_max': connector.maxTxPower,
          'hash': connector.pathHashByteWidth - 1,
        },
      'network': {
        'set': net != null,
        'role': net == null ? '-' : net.role.letter,
      },
      'home': app.sosLatitude != null && app.sosLongitude != null
          ? {'lat': app.sosLatitude, 'lon': app.sosLongitude}
          : null,
      if (connector.autoAddUsers != null)
        'autoadd': {
          'flags': _autoAddFlags(connector),
          'max_hops': connector.autoAddMaxHops ?? 0,
        },
      'tone': settingsService.sosAlarmTone,
      'contacts': [
        for (final key in app.sosContactKeys)
          {
            'key': key,
            'name': connector.getContactByPubKeyHex(key)?.name ?? '',
          },
      ],
      'app': {
        'network_name': net?.name,
        'coordinator': app.sosNetworkCoordinator,
        'include_favourites': app.sosIncludeFavourites,
        if (connector.selfLatitude != null && connector.selfLongitude != null)
          'advert_location': {
            'lat': connector.selfLatitude,
            'lon': connector.selfLongitude,
          },
      },
    };
    return ConfigBackup._({
      'format': format,
      'format_version': formatVersion,
      'made': DateTime.now().toUtc().toIso8601String(),
      'firmware': connector.firmwareVersionString ?? '',
      'app': appVersion,
      'settings': settings,
      'channels': [
        for (final c in connector.allChannels)
          if (!c.isEmpty) {'name': c.name, 'secret': c.pskHex},
      ],
      'secrets': {
        'public_key': connector.selfPublicKeyHex,
        'private_key': _hex(privateKey),
        'network_code': net?.text,
        'contacts': [
          for (final c in connector.contacts)
            {
              'key': c.publicKeyHex,
              'type': c.type,
              'flags': c.flags,
              'name': c.name,
            },
        ],
      },
    });
  }

  /// Puts the backup on the connected radio and in this app. Steps that
  /// fail are listed in the result rather than stopping the import.
  Future<ConfigRestoreResult> restore({
    required MeshCoreConnector connector,
    required AppSettingsService settingsService,
    required SosService sosService,
    void Function(String step)? onStep,
  }) async {
    final problems = <String>[];
    Future<void> step(String label, Future<void> Function() run) async {
      onStep?.call(label);
      try {
        await run();
      } catch (e) {
        problems.add('$label: ${e is StateError ? e.message : e}');
      }
    }

    // The identity first: the radio reloads its contacts when it changes,
    // which would drop any added before it.
    var identityChanged = false;
    if (publicKeyHex.toLowerCase() !=
        connector.selfPublicKeyHex.toLowerCase()) {
      try {
        onStep?.call('Identity');
        await connector.importPrivateKey(_bytes(privateKeyHex));
        identityChanged = true;
      } catch (e) {
        // Without the identity the rest would go onto the wrong radio's
        // identity, which is not what an import promises.
        return ConfigRestoreResult(
          failed: 'identity: ${e is StateError ? e.message : e}',
        );
      }
    }

    final s = settings;
    if (name.isNotEmpty) {
      await step('Name', () => connector.setNodeName(name));
    }
    final radio = s['radio'];
    if (radio is Map) {
      await step('Radio settings', () async {
        final ok = await connector.setRadioParams(
          ((radio['freq'] as num) * 1000).round(),
          ((radio['bw'] as num) * 1000).round(),
          (radio['sf'] as num).toInt(),
          (radio['cr'] as num).toInt(),
        );
        if (!ok) throw StateError('the radio refused them');
        final tx = radio['tx'];
        if (tx is num) {
          final max = connector.maxTxPower;
          final power = max != null && tx > max ? max : tx.toInt();
          await connector.sendFrame(buildSetRadioTxPowerFrame(power));
        }
      });
      final hash = radio['hash'];
      if (hash is num && (connector.firmwareVerCode ?? 0) >= 10) {
        await step(
          'Path hash size',
          () => connector.setPathHashMode(hash.toInt()),
        );
      }
    }
    final autoadd = s['autoadd'];
    if (autoadd is Map && connector.supportsAutoAddConfig) {
      await step('Auto-add', () async {
        final flags = (autoadd['flags'] as num).toInt();
        await connector.sendFrame(
          buildSetAutoAddConfigFrame(
            autoAddChat: flags & autoAddChatFlag != 0,
            autoAddRepeater: flags & autoAddRepeaterFlag != 0,
            autoAddRoomServer: flags & autoAddRoomServerFlag != 0,
            autoAddSensor: flags & autoAddSensorFlag != 0,
            overwriteOldest: flags & autoAddOverwriteOldestFlag != 0,
            maxHops: (autoadd['max_hops'] as num?)?.toInt(),
          ),
        );
        await connector.sendFrame(buildGetAutoAddFlagsFrame());
      });
    }
    final app = s['app'];
    final advertLoc = app is Map ? app['advert_location'] : null;
    if (advertLoc is Map) {
      await step(
        'Advert location',
        () => connector.setNodeLocation(
          lat: (advertLoc['lat'] as num).toDouble(),
          lon: (advertLoc['lon'] as num).toDouble(),
        ),
      );
    }

    // Channels it doesn't have yet, into free slots. The emergency
    // network's channel is left to joining the network below.
    final code = secrets['network_code'] is String
        ? SosNetworkCode.parse(secrets['network_code'] as String)
        : null;
    final networkKeyHex = code == null ? null : _hex(code.key);
    var channelsAdded = 0;
    await step('Channels', () async {
      final have = <String>{
        for (final c in connector.allChannels)
          if (!c.isEmpty) c.pskHex.toLowerCase(),
      };
      final used = <int>{
        for (final c in connector.allChannels)
          if (!c.isEmpty) c.index,
      };
      var slot = 0;
      for (final c in channels) {
        final secret = (c['secret'] as String? ?? '').toLowerCase();
        if (!_isHex(secret, 32) || have.contains(secret)) continue;
        if (secret == networkKeyHex) continue;
        while (used.contains(slot)) {
          slot++;
        }
        if (slot >= connector.maxChannels) {
          throw StateError('no free channel slot for "${c['name']}"');
        }
        await connector.sendFrame(
          buildSetChannelFrame(
            slot,
            c['name'] as String? ?? '',
            _bytes(secret),
          ),
          waitForGenericAck: true,
        );
        used.add(slot);
        have.add(secret);
        channelsAdded++;
      }
    });
    if (channelsAdded > 0) {
      await step('Channels', () => connector.getChannels(force: true));
    }

    var contactsAdded = 0;
    var contactsFailed = 0;
    final selfKey = publicKeyHex.toLowerCase();
    final known = {
      for (final c in connector.contacts) c.publicKeyHex.toLowerCase(),
    };
    final toAdd = contacts.where((c) {
      final key = (c['key'] as String).toLowerCase();
      return key != selfKey && !known.contains(key);
    }).toList();
    for (var i = 0; i < toAdd.length; i++) {
      if (i % 10 == 0) onStep?.call('Contacts ${i + 1} of ${toAdd.length}');
      final c = toAdd[i];
      try {
        await connector.sendFrame(
          // No path yet: routed by flood until one is learned.
          buildUpdateContactPathFrame(
            _bytes(c['key'] as String),
            Uint8List(0),
            -1,
            type: (c['type'] as num?)?.toInt() ?? advTypeChat,
            flags: (c['flags'] as num?)?.toInt() ?? 0,
            name: c['name'] as String? ?? '',
          ),
          waitForGenericAck: true,
        );
        contactsAdded++;
      } catch (_) {
        contactsFailed++;
      }
    }
    if (contactsFailed > 0) {
      problems.add('$contactsFailed contacts not added (the list may be full)');
    }
    if (contactsAdded > 0) {
      await step('Contacts', () => connector.getContacts());
    }

    // This app's emergency settings, where the file has them: what it
    // leaves out (no network, no home location) is left as it is here.
    if (code != null) {
      await step('Emergency network', () async {
        final appName = app is Map ? app['network_name'] as String? : null;
        await sosService.joinNetwork(
          SosNetworkCode(role: code.role, key: code.key, name: appName),
          coordinator: app is Map && app['coordinator'] == true,
        );
      });
    }
    final home = s['home'];
    if (home is Map) {
      await step(
        'Home location',
        () => settingsService.setSosLocation(
          (home['lat'] as num).toDouble(),
          (home['lon'] as num).toDouble(),
        ),
      );
    }
    final sosContacts = s['contacts'];
    if (sosContacts is List) {
      await step('Emergency contacts', () async {
        for (final c in sosContacts) {
          if (c is Map && _isHex(c['key'], 64)) {
            await settingsService.setSosContact(
              (c['key'] as String).toLowerCase(),
              true,
            );
          }
        }
      });
    }
    if (app is Map && app['include_favourites'] is bool) {
      await step(
        'Emergency contacts',
        () => settingsService.setSosIncludeFavourites(
          app['include_favourites'] as bool,
        ),
      );
    }
    final tone = s['tone'];
    if (tone == AppSettingsService.alarmToneMorse ||
        tone == AppSettingsService.alarmToneClassic) {
      await step(
        'Alarm sound',
        () => settingsService.setSosAlarmTone(tone as String),
      );
    }

    // A restart saves the contacts and lets the app load the new identity
    // from the start.
    if (identityChanged) {
      await step('Restart', () => connector.rebootDevice());
    }
    return ConfigRestoreResult(
      contactsAdded: contactsAdded,
      channelsAdded: channelsAdded,
      identityChanged: identityChanged,
      radioOnlySkipped: hasRadioOnlySettings,
      problems: problems,
    );
  }

  static int _autoAddFlags(MeshCoreConnector c) {
    var flags = 0;
    if (c.autoAddOverwriteOldest == true) flags |= autoAddOverwriteOldestFlag;
    if (c.autoAddUsers == true) flags |= autoAddChatFlag;
    if (c.autoAddRepeaters == true) flags |= autoAddRepeaterFlag;
    if (c.autoAddRoomServers == true) flags |= autoAddRoomServerFlag;
    if (c.autoAddSensors == true) flags |= autoAddSensorFlag;
    return flags;
  }

  static bool _isHex(Object? value, int length) =>
      value is String &&
      value.length == length &&
      RegExp(r'^[0-9a-fA-F]+$').hasMatch(value);

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _bytes(String hex) => Uint8List.fromList([
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

class ConfigRestoreResult {
  /// Set when nothing was changed because the identity couldn't be set.
  final String? failed;
  final int contactsAdded;
  final int channelsAdded;
  final bool identityChanged;

  /// The file had WiFi or SOS radio settings, which only the radio's web
  /// page puts back.
  final bool radioOnlySkipped;
  final List<String> problems;

  const ConfigRestoreResult({
    this.failed,
    this.contactsAdded = 0,
    this.channelsAdded = 0,
    this.identityChanged = false,
    this.radioOnlySkipped = false,
    this.problems = const [],
  });
}
