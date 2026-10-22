import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../helpers/sos_voice_packet.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/sos_voice_service.dart';

/// Push-to-talk, hands-free and the clips heard so far for one SOS.
class SosVoicePanel extends StatelessWidget {
  final String sosId;

  const SosVoicePanel({super.key, required this.sosId});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final voice = context.watch<SosVoiceService>();
    final block = voice.blockFor(sosId);
    if (block == SosVoiceBlock.unsupported || block == SosVoiceBlock.noSos) {
      return const SizedBox.shrink();
    }
    final textTheme = Theme.of(context).textTheme;
    final clips = voice.clipsFor(sosId);
    final handsFree = voice.isHandsFree(sosId);
    final talking = voice.isTalking(sosId);
    final enabled = block == null;

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(color: Colors.black87),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.record_voice_over, color: Colors.red.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.sosVoice_title,
                    style: textTheme.titleMedium?.copyWith(
                      color: Colors.black87,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                SegmentedButton<SosVoiceQuality>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    ButtonSegment(
                      value: SosVoiceQuality.low,
                      label: Text(l10n.sosVoice_qualityLow),
                    ),
                    ButtonSegment(
                      value: SosVoiceQuality.clear,
                      label: Text(l10n.sosVoice_qualityClear),
                    ),
                  ],
                  selected: {voice.quality},
                  onSelectionChanged: (s) => voice.quality = s.first,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.sosVoice_qualityHelp,
                style: textTheme.bodySmall?.copyWith(color: Colors.black54),
              ),
            ),
            if (block != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(switch (block) {
                  SosVoiceBlock.noNetwork => l10n.sosVoice_noNetwork,
                  _ => l10n.sosVoice_needsRadio,
                }),
              ),
            if (voice.micDenied)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.sosVoice_micDenied,
                  style: TextStyle(color: Colors.red.shade800),
                ),
              ),
            const SizedBox(height: 12),
            _TalkButton(sosId: sosId, enabled: enabled, talking: talking),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                l10n.sosVoice_handsFree,
                style: const TextStyle(color: Colors.black87),
              ),
              subtitle: Text(
                handsFree
                    ? (voice.isSpeaking
                          ? l10n.sosVoice_hearingYou
                          : l10n.sosVoice_listening)
                    : l10n.sosVoice_handsFreeHelp,
                style: const TextStyle(color: Colors.black54),
              ),
              value: handsFree,
              onChanged: enabled || handsFree
                  ? (on) => voice.setHandsFree(sosId, on)
                  : null,
            ),
            for (final clip in clips.reversed.take(6))
              _ClipRow(clip: clip, playing: identical(voice.playing, clip)),
          ],
        ),
      ),
    );
  }
}

class _TalkButton extends StatelessWidget {
  final String sosId;
  final bool enabled;
  final bool talking;

  const _TalkButton({
    required this.sosId,
    required this.enabled,
    required this.talking,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final voice = context.read<SosVoiceService>();
    final color = talking ? Colors.red.shade700 : Colors.red.shade50;
    final fg = talking ? Colors.white : Colors.red.shade900;
    return Semantics(
      button: true,
      label: l10n.sosVoice_holdToTalk,
      child: Listener(
        onPointerDown: enabled
            ? (_) {
                HapticFeedback.mediumImpact();
                voice.startTalking(sosId);
              }
            : null,
        onPointerUp: (_) => voice.stopTalking(),
        onPointerCancel: (_) => voice.stopTalking(cancel: true),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 64,
          decoration: BoxDecoration(
            color: enabled ? color : Colors.grey.shade200,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: enabled ? Colors.red.shade700 : Colors.grey,
              width: 2,
            ),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                talking ? Icons.mic : Icons.mic_none,
                color: enabled ? fg : Colors.grey,
              ),
              const SizedBox(width: 8),
              Text(
                talking
                    ? l10n.sosVoice_releaseToSend
                    : l10n.sosVoice_holdToTalk,
                style: TextStyle(
                  color: enabled ? fg : Colors.grey,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClipRow extends StatelessWidget {
  final VoiceClip clip;
  final bool playing;

  const _ClipRow({required this.clip, required this.playing});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final voice = context.read<SosVoiceService>();
    final who = clip.outgoing
        ? l10n.sosVoice_you
        : (clip.senderName ?? l10n.sos_unknownSender);
    final seconds = (clip.duration.inMilliseconds / 1000).toStringAsFixed(1);
    return Row(
      children: [
        Icon(
          clip.outgoing ? Icons.call_made : Icons.call_received,
          size: 18,
          color: Colors.black54,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$who · ${l10n.sosVoice_seconds(seconds)} · ${_status(l10n)}',
            style: const TextStyle(color: Colors.black87),
          ),
        ),
        IconButton(
          tooltip: playing ? l10n.sosVoice_stop : l10n.sosVoice_play,
          icon: Icon(playing ? Icons.stop : Icons.play_arrow),
          color: Colors.red.shade700,
          onPressed: playing ? voice.stopPlayback : () => voice.replay(clip),
        ),
      ],
    );
  }

  String _status(AppLocalizations l10n) => switch (clip.status) {
    VoiceClipStatus.queued => l10n.sosVoice_statusQueued,
    VoiceClipStatus.sending => l10n.sosVoice_statusSending(
      clip.sentChunks,
      clip.totalChunks,
    ),
    VoiceClipStatus.sent => l10n.sosVoice_statusSent,
    VoiceClipStatus.failed => l10n.sosVoice_statusFailed,
    VoiceClipStatus.received => l10n.sosVoice_statusReceived,
    VoiceClipStatus.partial => l10n.sosVoice_statusPartial(
      clip.sentChunks,
      clip.totalChunks,
    ),
  };
}
