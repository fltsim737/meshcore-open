import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/linux_sound_player.dart';
import '../services/sos_morse_sound.dart';
import '../services/sound_devices.dart';

/// Linux and Windows: the speaker for alerts and, in SOS Voice, the speaker
/// for voice and the microphone, chosen without changing the computer's own
/// default devices.
class SoundDevicesTiles extends StatefulWidget {
  const SoundDevicesTiles({super.key});

  @override
  State<SoundDevicesTiles> createState() => _SoundDevicesTilesState();
}

class _SoundDevicesTilesState extends State<SoundDevicesTiles> {
  @override
  Widget build(BuildContext context) {
    if (!SoundDevices.supported) return const SizedBox.shrink();
    final l10n = context.l10n;
    final roles = [
      if (SoundDevices.hasVoice) SoundRole.voice,
      SoundRole.alerts,
      if (SoundDevices.hasVoice) SoundRole.microphone,
    ];
    return Column(
      children: [
        for (final role in roles) ...[
          const Divider(height: 1, indent: 16),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: Icon(switch (role) {
              SoundRole.voice => Icons.headset_mic_outlined,
              SoundRole.alerts => Icons.speaker_outlined,
              SoundRole.microphone => Icons.mic_none,
            }, size: 24),
            title: Text(soundRoleTitle(l10n, role)),
            subtitle: Text(
              SoundDevices.labelFor(role) ?? l10n.sos_soundDefault,
            ),
            onTap: () => _choose(role),
          ),
        ],
      ],
    );
  }

  Future<void> _choose(SoundRole role) async {
    final picked = await chooseSoundDevice(context, role);
    if (picked == null || !mounted) return;
    setState(() {});
  }
}

String soundRoleTitle(AppLocalizations l10n, SoundRole role) => switch (role) {
  SoundRole.voice => l10n.sos_soundVoiceSpeaker,
  SoundRole.alerts => l10n.sos_soundAlertSpeaker,
  SoundRole.microphone => l10n.sos_soundMicrophone,
};

/// Lets the user pick the device for [role]; true once one was picked. A
/// speaker plays a short sound on it straight away, to try it.
Future<bool?> chooseSoundDevice(BuildContext context, SoundRole role) async {
  final l10n = context.l10n;
  final devices = role == SoundRole.microphone
      ? await SoundDevices.inputs()
      : await SoundDevices.outputs();
  if (!context.mounted) return null;
  final currentId = SoundDevices.idFor(role);
  final currentLabel = SoundDevices.labelFor(role);
  final missing = currentId != null && !devices.any((d) => d.id == currentId);

  // the default is null; "keep" (a device that isn't plugged in) is itself
  const keep = SoundDevice('', '');
  final picked = await showDialog<(SoundDevice?,)>(
    context: context,
    builder: (dialogContext) {
      Widget option(SoundDevice? device, String label, {String? detail}) {
        final selected = device == null
            ? currentId == null
            : device.id == currentId || (identical(device, keep) && missing);
        return ListTile(
          leading: Icon(
            selected
                ? Icons.radio_button_checked
                : Icons.radio_button_unchecked,
          ),
          title: Text(label),
          subtitle: detail == null ? null : Text(detail),
          onTap: () => Navigator.pop(dialogContext, (device,)),
        );
      }

      return SimpleDialog(
        title: Text(soundRoleTitle(l10n, role)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(l10n.sos_soundThisAppOnly),
          ),
          option(null, l10n.sos_soundDefault),
          for (final d in devices) option(d, d.label),
          if (missing)
            option(
              keep,
              currentLabel ?? currentId,
              detail: l10n.sos_soundNotConnected,
            ),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: Text(l10n.sos_soundNoDevices),
            ),
        ],
      );
    },
  );
  if (picked == null) return null;
  final device = picked.$1;
  if (!identical(device, keep)) await SoundDevices.setFor(role, device);
  if (role != SoundRole.microphone) await _testSpeaker(role);
  return true;
}

Future<void> _testSpeaker(SoundRole role) async {
  try {
    if (Platform.isLinux) {
      await LinuxSoundPlayer.playTest(role);
    } else if (Platform.isWindows) {
      await playWindowsSpeakerTest(role);
    }
  } catch (e) {
    debugPrint('Trying the speaker failed: $e');
  }
}
