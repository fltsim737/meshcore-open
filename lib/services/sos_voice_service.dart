import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/sos_voice_packet.dart';
import '../models/contact.dart';
import '../utils/lora_airtime.dart';
import 'sos_service.dart';
import 'voice_activity_detector.dart';
import 'voice_audio.dart';
import 'voice_codec.dart';

/// What the voice service needs from the radio.
abstract class SosVoiceTransport {
  Uint8List? get selfPublicKey;
  List<Contact> get contacts;

  set voiceListener(
    void Function(int channelIndex, Uint8List payload)? listener,
  );

  /// The pause to leave between two chunks of [bytes] each.
  Duration chunkGap(int bytes);

  Future<bool> sendChunks(
    int channelIndex,
    List<Uint8List> blobs, {
    required Duration gap,
    void Function(int sent, int total)? onProgress,
  });
}

class ConnectorSosVoiceTransport implements SosVoiceTransport {
  final MeshCoreConnector connector;

  ConnectorSosVoiceTransport(this.connector);

  @override
  Uint8List? get selfPublicKey => connector.selfPublicKey;
  @override
  List<Contact> get contacts => connector.contacts;
  @override
  set voiceListener(
    void Function(int channelIndex, Uint8List payload)? listener,
  ) => connector.sosVoiceListener = listener;

  @override
  Duration chunkGap(int bytes) {
    final sf = connector.currentSf;
    final bw = connector.currentBwHz;
    final cr = connector.currentCr == null
        ? null
        : normalizeCodingRate(connector.currentCr!);
    if (!areLoRaParamsValid(
      spreadingFactor: sf,
      bandwidthHz: bw,
      codingRate: cr,
    )) {
      return const Duration(seconds: 2);
    }
    return imageSendChunkGap(
      loraTimeOnAir(
        payloadBytes: bytes + kMeshCoreOnAirOverheadBytes,
        spreadingFactor: sf!,
        bandwidthHz: bw!,
        codingRate: cr!,
      ),
    );
  }

  @override
  Future<bool> sendChunks(
    int channelIndex,
    List<Uint8List> blobs, {
    required Duration gap,
    void Function(int sent, int total)? onProgress,
  }) => connector.sendSosVoiceChunks(
    channelIndex,
    blobs,
    gap: gap,
    onProgress: onProgress,
  );
}

enum VoiceClipStatus { queued, sending, sent, failed, received, partial }

/// A voice clip sent or heard during an SOS.
class VoiceClip {
  final int localId;
  final String sosId;
  final bool outgoing;

  /// The sender's name when known; null for an unknown sender.
  final String? senderName;
  final DateTime time;
  final Duration duration;
  final SosVoiceQuality quality;
  final Int16List pcm;
  VoiceClipStatus status;
  int sentChunks = 0;
  int totalChunks;

  VoiceClip({
    required this.localId,
    required this.sosId,
    required this.outgoing,
    required this.senderName,
    required this.time,
    required this.duration,
    required this.quality,
    required this.pcm,
    required this.status,
    this.totalChunks = 0,
  });
}

/// Why voice cannot be used for an SOS right now.
enum SosVoiceBlock {
  /// No active SOS of ours, and no live alert we may answer.
  noSos,

  /// Voice travels on the emergency network, which is not set up.
  noNetwork,

  /// The radio is disconnected or its firmware lacks channel data.
  radio,

  /// Codec2 is not available on this platform.
  unsupported,
}

/// Voice clips between the person who raised an SOS and the responders,
/// over the emergency network channel, only while that SOS is live.
///
/// Push-to-talk records while held. Hands-free listens continuously and
/// sends each stretch of speech when the speaker pauses. Clips heard play
/// aloud straight away, and the microphone ignores them while they play so
/// they are never sent back out.
class SosVoiceService extends ChangeNotifier {
  /// Preference holding the chosen [SosVoiceQuality] name.
  static const String qualityPrefsKey = 'sos_voice_quality';
  static const int _maxClipsPerSos = 30;

  /// Microphone audio after a clip finishes playing that is still ignored,
  /// so the end of the clip is not picked up and sent.
  static const Duration playbackTail = Duration(milliseconds: 400);

  final SosService _sos;
  final SosVoiceTransport _transport;
  final VoiceAudio _audio;
  final VoiceCodec? _codec;
  final Future<void> Function(bool inUse)? _setBackgroundMic;
  final Future<String?> Function()? _loadQuality;
  final Future<void> Function(String value)? _saveQuality;
  final DateTime Function() _now;
  final SosVoiceAssembler _assembler;

  SosVoiceQuality _quality = SosVoiceQuality.low;
  String? _handsFreeSosId;
  String? _pttSosId;
  final List<Int16List> _pttFrames = [];
  bool _speaking = false;
  bool _micDenied = false;
  StreamSubscription<Int16List>? _micSub;
  bool _micOn = false;
  late VoiceActivityDetector _vox;

  final Map<String, List<VoiceClip>> _clips = {};
  final List<VoiceClip> _sendQueue = [];
  bool _sendingNow = false;
  final List<VoiceClip> _playQueue = [];
  VoiceClip? _playing;
  DateTime _ignoreMicUntil = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _staleTimer;
  int _nextLocalId = 1;
  int _nextClipId = Random().nextInt(0x10000);

  SosVoiceService({
    required SosService sos,
    required SosVoiceTransport transport,
    required VoiceAudio audio,
    required VoiceCodec? codec,
    Future<void> Function(bool inUse)? setBackgroundMic,
    Future<String?> Function()? loadQuality,
    Future<void> Function(String value)? saveQuality,
    DateTime Function()? now,
  }) : _sos = sos,
       _transport = transport,
       _audio = audio,
       _codec = codec,
       _setBackgroundMic = setBackgroundMic,
       _loadQuality = loadQuality,
       _saveQuality = saveQuality,
       _now = now ?? DateTime.now,
       _assembler = SosVoiceAssembler(now: now) {
    _vox = _makeVox();
    _transport.voiceListener = handleInbound;
    _sos.addListener(_onSosChanged);
    unawaited(_restoreQuality());
  }

  Future<void> _restoreQuality() async {
    final saved = await _loadQuality?.call();
    final match = SosVoiceQuality.values.where((q) => q.name == saved);
    if (match.isEmpty) return;
    _quality = match.first;
    _vox = _makeVox();
    notifyListeners();
  }

  VoiceActivityDetector _makeVox() => VoiceActivityDetector(
    maxFrames: _quality.maxFrames,
    onClip: _onVoxClip,
    onSpeakingChanged: (speaking) {
      _speaking = speaking;
      notifyListeners();
    },
  );

  SosVoiceQuality get quality => _quality;

  set quality(SosVoiceQuality value) {
    if (value == _quality) return;
    _vox.flush();
    _quality = value;
    _vox = _makeVox();
    unawaited(_saveQuality?.call(value.name));
    notifyListeners();
  }

  bool get micDenied => _micDenied;
  bool get isSpeaking => _speaking;
  bool isHandsFree(String sosId) => _handsFreeSosId == sosId;
  bool isTalking(String sosId) => _pttSosId == sosId;
  VoiceClip? get playing => _playing;

  List<VoiceClip> clipsFor(String sosId) =>
      List.unmodifiable(_clips[sosId] ?? const []);

  /// Null when voice can be used for [sosId], otherwise why not.
  SosVoiceBlock? blockFor(String sosId) {
    if (_codec == null) return SosVoiceBlock.unsupported;
    if (!_isLive(sosId)) return SosVoiceBlock.noSos;
    if (_sos.network == null) return SosVoiceBlock.noNetwork;
    if (!_sos.isConnected ||
        !_sos.supportsChannelAlerts ||
        _sos.sosChannel == null) {
      return SosVoiceBlock.radio;
    }
    return null;
  }

  /// Our own active SOS, or a live alert we can answer as a responder.
  bool _isLive(String sosId) =>
      _sos.active?.id == sosId ||
      (_sos.isResponder && _sos.incoming.any((a) => a.id == sosId));

  // ---------------------------------------------------------------------
  // Talking
  // ---------------------------------------------------------------------

  Future<bool> setHandsFree(String sosId, bool on) async {
    if (!on) {
      if (_handsFreeSosId != sosId) return true;
      _vox.flush();
      _handsFreeSosId = null;
      _speaking = false;
      await _syncMic();
      notifyListeners();
      return true;
    }
    if (blockFor(sosId) != null) return false;
    if (!await _ensurePermission()) return false;
    _vox.reset();
    _handsFreeSosId = sosId;
    await _syncMic();
    notifyListeners();
    return true;
  }

  /// Push-to-talk pressed.
  Future<bool> startTalking(String sosId) async {
    if (blockFor(sosId) != null) return false;
    if (!await _ensurePermission()) return false;
    await stopPlayback();
    _vox.reset();
    _pttFrames.clear();
    _pttSosId = sosId;
    await _syncMic();
    notifyListeners();
    return true;
  }

  /// Push-to-talk released: sends what was said, unless [cancel].
  Future<void> stopTalking({bool cancel = false}) async {
    final sosId = _pttSosId;
    if (sosId == null) return;
    _pttSosId = null;
    final frames = List.of(_pttFrames);
    _pttFrames.clear();
    await _syncMic();
    // Under half a second is almost certainly an accidental tap.
    if (!cancel && frames.length >= 12) _queueOutgoing(sosId, frames);
    notifyListeners();
  }

  Future<bool> _ensurePermission() async {
    final granted = await _audio.ensureMicPermission();
    _micDenied = !granted;
    if (!granted) notifyListeners();
    return granted;
  }

  Future<void> _syncMic() async {
    final want = _handsFreeSosId != null || _pttSosId != null;
    if (want == _micOn) return;
    _micOn = want;
    if (want) {
      final frames = await _audio.startMic();
      _micSub = frames.listen(_onMicFrame);
    } else {
      await _micSub?.cancel();
      _micSub = null;
      await _audio.stopMic();
    }
    await _setBackgroundMic?.call(_handsFreeSosId != null);
  }

  void _onMicFrame(Int16List frame) {
    if (_pttSosId != null) {
      if (_pttFrames.length < _quality.maxFrames) _pttFrames.add(frame);
      return;
    }
    if (_handsFreeSosId == null) return;
    // Never pick up a received clip from the speaker and send it back out.
    if (_playing != null || _now().isBefore(_ignoreMicUntil)) return;
    _vox.addFrame(frame);
  }

  void _onVoxClip(List<Int16List> frames) {
    final sosId = _handsFreeSosId;
    if (sosId != null) _queueOutgoing(sosId, frames);
  }

  void _queueOutgoing(String sosId, List<Int16List> frames) {
    final clip = VoiceClip(
      localId: _nextLocalId++,
      sosId: sosId,
      outgoing: true,
      senderName: null,
      time: _now(),
      duration: Duration(milliseconds: frames.length * SosVoicePacket.frameMs),
      quality: _quality,
      pcm: _concat(frames),
      status: VoiceClipStatus.queued,
    );
    _addClip(clip);
    _sendQueue.add(clip);
    unawaited(_pumpSend());
  }

  Future<void> _pumpSend() async {
    if (_sendingNow) return;
    _sendingNow = true;
    try {
      while (_sendQueue.isNotEmpty) {
        final clip = _sendQueue.removeAt(0);
        await _send(clip);
      }
    } finally {
      _sendingNow = false;
    }
  }

  Future<void> _send(VoiceClip clip) async {
    final codec = _codec;
    final channel = _sos.sosChannel;
    final self = _transport.selfPublicKey;
    if (codec == null ||
        channel == null ||
        self == null ||
        blockFor(clip.sosId) != null) {
      clip.status = VoiceClipStatus.failed;
      notifyListeners();
      return;
    }
    final frames = codec.encode(_split(clip.pcm), clip.quality);
    final packets = SosVoicePacket.split(
      frames: frames,
      quality: clip.quality,
      sosId: clip.sosId,
      senderPrefix: self.sublist(0, SosVoicePacket.keyPrefixSize),
      clipId: _nextClipId++ & 0xFFFF,
    );
    final blobs = [for (final p in packets) p.encode()];
    clip
      ..status = VoiceClipStatus.sending
      ..totalChunks = blobs.length;
    notifyListeners();
    var ok = false;
    try {
      ok = await _transport.sendChunks(
        channel.index,
        blobs,
        gap: _transport.chunkGap(SosVoicePacket.maxBlobBytes),
        onProgress: (sent, total) {
          clip.sentChunks = sent;
          notifyListeners();
        },
      );
    } catch (_) {
      ok = false;
    }
    clip.status = ok ? VoiceClipStatus.sent : VoiceClipStatus.failed;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Listening
  // ---------------------------------------------------------------------

  /// A channel data packet of type [dataTypeSosVoice].
  @visibleForTesting
  void handleInbound(int channelIndex, Uint8List data) {
    final codec = _codec;
    if (codec == null || _sos.sosChannel?.index != channelIndex) return;
    final packet = SosVoicePacket.decode(data);
    if (packet == null || !_isLive(packet.sosId)) return;
    final self = _transport.selfPublicKey;
    if (self != null &&
        listEquals(
          self.sublist(0, SosVoicePacket.keyPrefixSize),
          packet.senderPrefix,
        )) {
      return; // Our own clip, repeated back to us.
    }
    final done = _assembler.add(packet);
    if (done != null) _deliver(done);
    _staleTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      checkStale();
    });
  }

  /// Plays clips whose remaining chunks were lost.
  @visibleForTesting
  void checkStale() {
    for (final clip in _assembler.takeStale()) {
      _deliver(clip);
    }
    if (!_assembler.hasPending) {
      _staleTimer?.cancel();
      _staleTimer = null;
    }
  }

  void _deliver(SosVoiceClipFrames frames) {
    if (!_isLive(frames.sosId)) return;
    final clip = VoiceClip(
      localId: _nextLocalId++,
      sosId: frames.sosId,
      outgoing: false,
      senderName: _nameFor(frames.senderPrefix, frames.sosId),
      time: _now(),
      duration: frames.duration,
      quality: frames.quality,
      pcm: _codec!.decode(frames.frames, frames.quality),
      status: frames.isComplete
          ? VoiceClipStatus.received
          : VoiceClipStatus.partial,
      totalChunks: frames.chunks.length,
    )..sentChunks = frames.received;
    _addClip(clip);
    _playQueue.add(clip);
    unawaited(_pumpPlay());
  }

  String? _nameFor(Uint8List prefix, String sosId) {
    bool matches(Uint8List key) =>
        key.length >= prefix.length &&
        listEquals(key.sublist(0, prefix.length), prefix);
    final contact = _transport.contacts
        .where((c) => matches(c.publicKey))
        .firstOrNull;
    if (contact != null) return contact.name;
    final hex = prefix.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final alert = _sos.incoming
        .where(
          (a) => a.id == sosId && (a.senderKeyHex?.startsWith(hex) ?? false),
        )
        .firstOrNull;
    return alert?.senderName;
  }

  /// Plays a clip again.
  void replay(VoiceClip clip) {
    _playQueue.add(clip);
    unawaited(_pumpPlay());
  }

  Future<void> stopPlayback() async {
    _playQueue.clear();
    await _audio.stopPlayback();
  }

  Future<void> _pumpPlay() async {
    if (_playing != null) return;
    while (_playQueue.isNotEmpty) {
      final clip = _playQueue.removeAt(0);
      _playing = clip;
      _vox.reset();
      notifyListeners();
      try {
        await _audio.play(clip.pcm);
      } catch (_) {
        // A failed playback must not stop the queue.
      }
      _ignoreMicUntil = _now().add(playbackTail);
      _playing = null;
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------------

  void _addClip(VoiceClip clip) {
    final list = _clips.putIfAbsent(clip.sosId, () => []);
    list.add(clip);
    if (list.length > _maxClipsPerSos) list.removeAt(0);
    notifyListeners();
  }

  /// Ends voice for any SOS that is over.
  void _onSosChanged() {
    final hf = _handsFreeSosId;
    if (hf != null && !_isLive(hf)) unawaited(setHandsFree(hf, false));
    final ptt = _pttSosId;
    if (ptt != null && !_isLive(ptt)) unawaited(stopTalking(cancel: true));
    final before = _clips.length;
    _clips.removeWhere((sosId, _) => !_isLive(sosId));
    if (_clips.length != before) notifyListeners();
  }

  static Int16List _concat(List<Int16List> frames) {
    final out = Int16List(frames.length * SosVoicePacket.samplesPerFrame);
    for (var i = 0; i < frames.length; i++) {
      out.setAll(i * SosVoicePacket.samplesPerFrame, frames[i]);
    }
    return out;
  }

  static List<Int16List> _split(Int16List pcm) {
    const n = SosVoicePacket.samplesPerFrame;
    return [
      for (var i = 0; i + n <= pcm.length; i += n)
        Int16List.sublistView(pcm, i, i + n),
    ];
  }

  @override
  void dispose() {
    _sos.removeListener(_onSosChanged);
    _transport.voiceListener = null;
    _staleTimer?.cancel();
    unawaited(_micSub?.cancel());
    unawaited(_audio.dispose());
    super.dispose();
  }
}
