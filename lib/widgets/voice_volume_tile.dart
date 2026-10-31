import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import '../services/sound_devices.dart';

/// How loud voice clips play (SOS Voice): each clip is levelled first, so
/// quiet ones are easy to hear, then this volume applies.
class VoiceVolumeTile extends StatefulWidget {
  const VoiceVolumeTile({super.key});

  @override
  State<VoiceVolumeTile> createState() => _VoiceVolumeTileState();
}

class _VoiceVolumeTileState extends State<VoiceVolumeTile> {
  late double _volume = SoundDevices.voiceVolume;

  @override
  Widget build(BuildContext context) {
    if (!SoundDevices.playsVoice) return const SizedBox.shrink();
    final l10n = context.l10n;
    return Column(
      children: [
        const Divider(height: 1, indent: 16),
        ListTile(
          contentPadding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          leading: const Icon(Icons.volume_up_outlined, size: 24),
          title: Text(l10n.sos_voiceVolume),
          subtitle: Text(l10n.sos_voiceVolumeHelp),
          trailing: Text('${(_volume * 100).round()}%'),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 8, 4),
          child: Slider(
            min: SoundDevices.minVoiceVolume,
            max: SoundDevices.maxVoiceVolume,
            divisions: 11,
            value: _volume,
            label: '${(_volume * 100).round()}%',
            onChanged: (v) => setState(() => _volume = v),
            onChangeEnd: SoundDevices.setVoiceVolume,
          ),
        ),
      ],
    );
  }
}
