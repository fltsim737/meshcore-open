import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../helpers/sos_voice_packet.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../services/sos_voice_service.dart';

/// Push-to-talk in a conversation: the public Voice channel
/// ([SosVoiceService.pttChannelKey]) or a direct message
/// ([SosVoiceService.pttDirectKey]). Hold to talk; the clips heard play
/// straight away and stay listed to play again.
class PttPanel extends StatelessWidget {
  final String conversation;

  /// Who a direct-message clip goes to, for the help line; null on the
  /// channel.
  final String? contactName;

  const PttPanel({super.key, required this.conversation, this.contactName});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final voice = context.watch<SosVoiceService>();
    final block = voice.blockFor(conversation);
    if (block == SosVoiceBlock.unsupported) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final clips = voice.clipsFor(conversation);
    final talking = voice.isTalking(conversation);
    if (voice.hasUnheard(conversation)) {
      // on screen now: seen
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => voice.markHeard(conversation),
      );
    }
    final note = _blockText(l10n, voice, block);

    return Material(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final clip in clips.reversed.take(3).toList().reversed)
              _ClipRow(clip: clip, playing: identical(voice.playing, clip)),
            Row(
              children: [
                Expanded(
                  child: _TalkButton(
                    conversation: conversation,
                    enabled: block == null,
                    talking: talking,
                  ),
                ),
                const SizedBox(width: 8),
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
                note ??
                    (contactName == null
                        ? l10n.ptt_channelHelp
                        : l10n.ptt_directHelp(contactName!)),
                style: textTheme.bodySmall?.copyWith(
                  color: note == null ? scheme.onSurfaceVariant : scheme.error,
                ),
              ),
            ),
            if (voice.micDenied)
              Text(
                l10n.sosVoice_micDenied,
                style: textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
          ],
        ),
      ),
    );
  }

  String? _blockText(
    AppLocalizations l10n,
    SosVoiceService voice,
    SosVoiceBlock? block,
  ) => switch (block) {
    null => null,
    SosVoiceBlock.sosLive => l10n.ptt_sosLive,
    SosVoiceBlock.noChannel => l10n.ptt_noChannel,
    SosVoiceBlock.busy => l10n.ptt_busy,
    SosVoiceBlock.meshBusy => l10n.ptt_meshBusy(
      voice.meshBusyWait.inSeconds + 1,
    ),
    SosVoiceBlock.talkLimit => l10n.ptt_talkLimit(
      _minutesSeconds(voice.talkLimitWait),
    ),
    _ => l10n.sosVoice_needsRadio,
  };
}

class _TalkButton extends StatelessWidget {
  final String conversation;
  final bool enabled;
  final bool talking;

  const _TalkButton({
    required this.conversation,
    required this.enabled,
    required this.talking,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final voice = context.read<SosVoiceService>();
    final scheme = Theme.of(context).colorScheme;
    final bg = talking ? scheme.primary : scheme.primaryContainer;
    final fg = talking ? scheme.onPrimary : scheme.onPrimaryContainer;
    return Semantics(
      button: true,
      label: l10n.sosVoice_holdToTalk,
      child: Listener(
        onPointerDown: enabled
            ? (_) {
                HapticFeedback.mediumImpact();
                voice.startTalking(conversation);
              }
            : null,
        onPointerUp: (_) => voice.stopTalking(),
        onPointerCancel: (_) => voice.stopTalking(cancel: true),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 48,
          decoration: BoxDecoration(
            color: enabled || talking ? bg : scheme.surfaceContainer,
            borderRadius: BorderRadius.circular(24),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                talking ? Icons.mic : Icons.mic_none,
                color: enabled || talking ? fg : scheme.outline,
              ),
              const SizedBox(width: 8),
              Text(
                talking
                    ? l10n.sosVoice_releaseToSend
                    : l10n.sosVoice_holdToTalk,
                style: TextStyle(
                  color: enabled || talking ? fg : scheme.outline,
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
        Icon(clip.outgoing ? Icons.call_made : Icons.call_received, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$who · ${l10n.sosVoice_seconds(seconds)} · ${_status(l10n)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: playing ? l10n.sosVoice_stop : l10n.sosVoice_play,
          icon: Icon(playing ? Icons.stop : Icons.play_arrow),
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

/// A wait as minutes and seconds, such as 6:05.
String _minutesSeconds(Duration d) {
  final total = d.inSeconds + 1;
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}
