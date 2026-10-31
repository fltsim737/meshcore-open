import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../connector/meshcore_connector.dart';
import '../helpers/sos_voice_packet.dart';
import '../models/channel.dart';
import '../models/contact.dart';
import '../utils/lora_airtime.dart';
import 'sos_service.dart';
import 'sound_devices.dart';
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

  /// Sends a clip's chunks; [stop] is asked before each one, and true stops
  /// the rest (an SOS needs the air).
  Future<bool> sendChunks(
    int channelIndex,
    List<Uint8List> blobs, {
    required Duration gap,
    void Function(int sent, int total)? onProgress,
    bool Function()? stop,
  });

  // Push-to-talk (10.0.0)

  bool get isConnected;
  List<Channel> get channels;
  int get maxChannels;

  /// The radio's channel list has loaded.
  bool get channelsReady;
  Future<void> setChannel(int index, String name, Uint8List psk);

  /// Called whenever the radio's state may have changed.
  set changeListener(VoidCallback? listener);

  set directListener(void Function(String senderKeyHex, String text)? value);

  Future<bool> sendDirect(
    Contact contact,
    List<String> texts, {
    required Duration gap,
    void Function(int sent, int total)? onProgress,
    bool Function()? stop,
  });

  /// When text messages were heard or sent in the last minute.
  List<DateTime> get recentTextTraffic;
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
    bool Function()? stop,
  }) => connector.sendSosVoiceChunks(
    channelIndex,
    blobs,
    gap: gap,
    onProgress: onProgress,
    stop: stop,
  );

  @override
  bool get isConnected => connector.isConnected;
  @override
  List<Channel> get channels => connector.allChannels;
  @override
  int get maxChannels => connector.maxChannels;
  @override
  bool get channelsReady =>
      connector.hasLoadedChannels && !connector.isLoadingChannels;
  @override
  Future<void> setChannel(int index, String name, Uint8List psk) =>
      connector.setChannel(index, name, psk);

  VoidCallback? _changeListener;
  @override
  set changeListener(VoidCallback? listener) {
    final old = _changeListener;
    if (old != null) connector.removeListener(old);
    _changeListener = listener;
    if (listener != null) connector.addListener(listener);
  }

  @override
  set directListener(void Function(String, String)? value) =>
      connector.pttDirectListener = value;

  @override
  List<DateTime> get recentTextTraffic => connector.recentTextTraffic;

  @override
  Future<bool> sendDirect(
    Contact contact,
    List<String> texts, {
    required Duration gap,
    void Function(int sent, int total)? onProgress,
    bool Function()? stop,
  }) => connector.sendPttDirectTexts(
    contact,
    texts,
    gap: gap,
    onProgress: onProgress,
    stop: stop,
  );
}

enum VoiceClipStatus { queued, sending, sent, failed, received, partial }

/// A voice clip sent or heard during an SOS, or by push-to-talk.
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

  /// Push-to-talk: an SOS is live, which comes first.
  sosLive,

  /// Push-to-talk: the Voice channel isn't on the radio.
  noChannel,

  /// Push-to-talk: someone else's clip is arriving on the Voice channel.
  busy,

  /// Push-to-talk: the mesh is carrying text messages, which come first.
  meshBusy,

  /// Push-to-talk: a voice session reached [SosVoiceService.pttSessionLimit],
  /// and the mesh rests from voice for [SosVoiceService.pttRest].
  talkLimit,
}

/// Voice clips between the person who raised an SOS and the responders,
/// over the emergency network channel, only while that SOS is live.
///
/// Push-to-talk (10.0.0) works the same way outside an SOS, in conversations
/// of its own: [pttChannelKey] on the public Voice channel ([pttChannelName],
/// which the app puts on the radio once), and [pttDirectKey] with one
/// contact, by direct message. To spare the mesh's airtime its clips are at
/// most [pttMaxClip], not while another clip is arriving on the channel, not
/// while the mesh is carrying text ([pttQuietAfterText], [pttBusyText]), at
/// most [pttSessionLimit] of voice in a session before everyone rests from it
/// for [pttRest] (two tones say so), and never while an
/// SOS is live. There's no wait between clips, so a conversation can flow;
/// the guide explains what each clip costs the mesh.
///
/// Push-to-talk records while held. Hands-free listens continuously and
/// sends each stretch of speech when the speaker pauses. Clips heard play
/// aloud straight away, and the microphone ignores them while they play so
/// they are never sent back out.
class SosVoiceService extends ChangeNotifier {
  /// Preference holding the chosen [SosVoiceQuality] name.
  static const String qualityPrefsKey = 'sos_voice_quality';
  static const int _maxClipsPerSos = 30;

  /// Push-to-talk clips are kept in memory only (never saved), and tidied
  /// away by themselves: those older than [pttClipKeep] go, and at most
  /// [pttMaxClips] are kept over every push-to-talk conversation together,
  /// the oldest going first. SOS clips go when their SOS ends.
  static const Duration pttClipKeep = Duration(hours: 24);
  static const int pttMaxClips = 100;

  /// The public push-to-talk channel: a hashtag channel, so its key comes
  /// from its name and every SOS Voice app shares it.
  static const String pttChannelName = '#voice';
  static final Uint8List pttChannelPsk = Channel.derivePskFromHashtag(
    pttChannelName,
  );
  static const String pttChannelKey = 'ptt:channel';
  static String pttDirectKey(String contactKeyHex) => 'ptt:dm:$contactKeyHex';
  static bool isPtt(String key) => key.startsWith('ptt:');

  static const Duration pttMaxClip = Duration(seconds: 10);

  /// A voice session: the voice in one conversation (#voice, or a direct
  /// message), both ways, until [pttSessionGap] goes by with none. Once it
  /// reaches [pttSessionLimit], the people who talked in it rest from
  /// push-to-talk for [pttRest], everywhere (two tones say so), giving the
  /// airtime back to everyone else. Someone who only listened isn't stopped:
  /// for them the session simply starts again.
  static const Duration pttSessionLimit = Duration(minutes: 3);
  static const Duration pttRest = Duration(minutes: 5);
  static const Duration pttSessionGap = Duration(minutes: 5);

  /// Push-to-talk waits this long after any text message heard or sent...
  static const Duration pttQuietAfterText = Duration(seconds: 15);

  /// ...and while this many text messages were heard or sent in the last
  /// minute.
  static const int pttBusyText = 4;

  /// Push-to-talk pauses this long after any SOS packet heard on the
  /// emergency network, even one this phone can't read: an SOS repeats
  /// every few minutes, so it stays paused while the SOS lasts.
  static const Duration pttSosHold = Duration(minutes: 5);

  /// The Voice channel counts as busy this long after a chunk of someone
  /// else's clip, unless the clip has finished.
  static const Duration pttBusyHold = Duration(seconds: 4);

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
  final bool Function(String radioKeyHex)? _pttChannelAddedBefore;
  final void Function(String radioKeyHex)? _rememberPttChannelAdded;

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

  /// Each conversation's voice session, and the end of this person's rest
  /// from push-to-talk, if one is on.
  final Map<String, _VoiceSession> _sessions = {};
  DateTime? _restUntil;
  Timer? _waitTimer;

  /// Tidies push-to-talk clips away now and then, so old ones go even when
  /// no new clip arrives ([pttClipKeep]).
  Timer? _tidyTimer;

  /// Push-to-talk conversations with a clip heard that the user hasn't
  /// looked at yet.
  final Set<String> _unheard = {};

  /// Called for each push-to-talk clip heard, for its notification.
  void Function(String conversation, VoiceClip clip)? onPttClipHeard;
  DateTime? _channelChunkAt;
  final Set<String> _pttOfferedThisRun = {};
  bool _addingPttChannel = false;
  int? _pttChannelIndex;

  SosVoiceService({
    required SosService sos,
    required SosVoiceTransport transport,
    required VoiceAudio audio,
    required VoiceCodec? codec,
    Future<void> Function(bool inUse)? setBackgroundMic,
    Future<String?> Function()? loadQuality,
    Future<void> Function(String value)? saveQuality,
    DateTime Function()? now,
    bool Function(String radioKeyHex)? pttChannelAddedBefore,
    void Function(String radioKeyHex)? rememberPttChannelAdded,
  }) : _sos = sos,
       _transport = transport,
       _audio = audio,
       _codec = codec,
       _setBackgroundMic = setBackgroundMic,
       _loadQuality = loadQuality,
       _saveQuality = saveQuality,
       _now = now ?? DateTime.now,
       _assembler = SosVoiceAssembler(now: now),
       _pttChannelAddedBefore = pttChannelAddedBefore,
       _rememberPttChannelAdded = rememberPttChannelAdded {
    _vox = _makeVox();
    _transport.voiceListener = handleInbound;
    _transport.directListener = handleDirect;
    _transport.changeListener = _onRadioChanged;
    _sos.addListener(_onSosChanged);
    _tidyTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      if (_tidyPttClips()) notifyListeners();
    });
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

  /// Null when voice can be used for [sosId] (an SOS, or a push-to-talk
  /// conversation), otherwise why not.
  SosVoiceBlock? blockFor(String sosId) {
    if (_codec == null) return SosVoiceBlock.unsupported;
    if (isPtt(sosId)) {
      final block = _pttSendBlock(sosId);
      if (block != null) return block;
      if (sosId == pttChannelKey && channelBusy) return SosVoiceBlock.busy;
      if (meshBusyWait > Duration.zero) return SosVoiceBlock.meshBusy;
      if (talkLimitWait > Duration.zero) return SosVoiceBlock.talkLimit;
      return null;
    }
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
  /// Push-to-talk conversations are always there.
  bool _isLive(String sosId) =>
      isPtt(sosId) ||
      _sos.active?.id == sosId ||
      (_sos.isResponder && _sos.incoming.any((a) => a.id == sosId));

  // ---------------------------------------------------------------------
  // Push-to-talk
  // ---------------------------------------------------------------------

  /// Any SOS is live: ours, or an alert heard, or an SOS packet heard on
  /// the network in the last [pttSosHold] (one a member can't read, or an
  /// acknowledgement or cancellation: they all mean the network is busy with
  /// an emergency).
  bool get sosLive =>
      _sos.active != null ||
      _sos.incoming.isNotEmpty ||
      sosHeardWait > Duration.zero;

  /// How long push-to-talk stays paused after the last SOS packet heard.
  Duration get sosHeardWait {
    final at = _sos.sosTrafficAt;
    if (at == null) return Duration.zero;
    return _waitUntil(at.add(pttSosHold), _now());
  }

  /// The public Voice channel on the connected radio, if it's there.
  Channel? get pttChannel => _transport.channels
      .where((c) => listEquals(c.psk, pttChannelPsk))
      .firstOrNull;

  /// Someone else's clip is arriving on the Voice channel.
  bool get channelBusy {
    final at = _channelChunkAt;
    return at != null && _now().difference(at) < pttBusyHold;
  }

  /// How long push-to-talk stands aside for text: until [pttQuietAfterText]
  /// after the last text message, and until fewer than [pttBusyText] were
  /// heard or sent in the last minute.
  Duration get meshBusyWait {
    final traffic = _transport.recentTextTraffic;
    if (traffic.isEmpty) return Duration.zero;
    final now = _now();
    var until = traffic.last.add(pttQuietAfterText);
    if (traffic.length >= pttBusyText) {
      // the oldest that must age out to bring it under the limit
      final drop = traffic[traffic.length - pttBusyText];
      final under = drop.add(const Duration(minutes: 1));
      if (under.isAfter(until)) until = under;
    }
    return _waitUntil(until, now);
  }

  /// [key]'s voice session, unless [pttSessionGap] has gone by without any.
  _VoiceSession? _session(String key) {
    final session = _sessions[key];
    if (session == null) return null;
    if (_now().difference(session.lastAt) >= pttSessionGap) {
      _sessions.remove(key);
      return null;
    }
    return session;
  }

  /// Voice in [key]'s current session, both ways.
  Duration sessionTalk(String key) => _session(key)?.talk ?? Duration.zero;

  /// How long this person's rest from voice has to go.
  Duration get talkLimitWait {
    final until = _restUntil;
    if (until == null) return Duration.zero;
    return _waitUntil(until, _now());
  }

  /// Counts a push-to-talk clip in [key], heard or [sent]. At the limit, a
  /// person who talked in the session rests, with two tones; one who only
  /// listened starts a new session.
  void _countVoice(String key, Duration length, {required bool sent}) {
    final now = _now();
    final session = _session(key) ?? (_sessions[key] = _VoiceSession(now));
    session
      ..talk += length
      ..lastAt = now
      ..talked |= sent;
    if (session.talk < pttSessionLimit - const Duration(seconds: 1)) return;
    _sessions.remove(key);
    if (!session.talked || talkLimitWait > Duration.zero) return;
    _restUntil = now.add(pttRest);
    _playQueue.add(
      VoiceClip(
        localId: _nextLocalId++,
        sosId: 'ptt:rest',
        outgoing: false,
        senderName: null,
        time: now,
        duration: const Duration(milliseconds: 800),
        quality: _quality,
        pcm: restTones(),
        status: VoiceClipStatus.received,
      ),
    );
    unawaited(_pumpPlay());
    notifyListeners();
  }

  /// Two falling tones: the mesh rests from voice.
  @visibleForTesting
  static Int16List restTones() {
    const rate = SosVoicePacket.sampleRate;
    final out = Int16List(rate * 800 ~/ 1000);
    void tone(int startMs, int lengthMs, double hz) {
      final start = rate * startMs ~/ 1000;
      final n = rate * lengthMs ~/ 1000;
      for (var i = 0; i < n; i++) {
        final fade = min(1.0, min(i, n - i) / (rate * 0.01)); // no clicks
        out[start + i] = (9000 * fade * sin(2 * pi * hz * i / rate)).round();
      }
    }

    tone(0, 300, 880);
    tone(420, 300, 660);
    return out;
  }

  Duration _waitUntil(DateTime until, DateTime now) {
    final left = until.difference(now);
    if (left <= Duration.zero) return Duration.zero;
    // a countdown on screen, once a second, until every wait is over
    _waitTimer ??= Timer.periodic(const Duration(seconds: 1), (timer) {
      final waiting =
          until.isAfter(_now()) ||
          meshBusyWait > Duration.zero ||
          talkLimitWait > Duration.zero ||
          sosHeardWait > Duration.zero;
      if (!waiting) {
        timer.cancel();
        if (identical(_waitTimer, timer)) _waitTimer = null;
      }
      notifyListeners();
    });
    return left;
  }

  /// A push-to-talk clip arrived in [key] that the user hasn't seen.
  bool hasUnheard(String key) => _unheard.contains(key);

  /// The user is looking at [key]'s clips.
  void markHeard(String key) {
    if (_unheard.remove(key)) notifyListeners();
  }

  /// What stops a push-to-talk clip going at all (not the waits).
  SosVoiceBlock? _pttSendBlock(String key) {
    if (_codec == null) return SosVoiceBlock.unsupported;
    if (sosLive) return SosVoiceBlock.sosLive;
    if (!_transport.isConnected) return SosVoiceBlock.radio;
    if (key == pttChannelKey) {
      if (!_sos.supportsChannelAlerts) return SosVoiceBlock.radio;
      if (pttChannel == null) return SosVoiceBlock.noChannel;
    } else if (_contactFor(key) == null) {
      return SosVoiceBlock.radio;
    }
    return null;
  }

  Contact? _contactFor(String key) {
    if (!key.startsWith('ptt:dm:')) return null;
    final hex = key.substring('ptt:dm:'.length);
    return _transport.contacts.where((c) => c.publicKeyHex == hex).firstOrNull;
  }

  /// A push-to-talk clip stops at [pttMaxClip], or sooner if the talk limit
  /// would be passed.
  int _maxFramesFor(String key) {
    if (!isPtt(key)) return _quality.maxFrames;
    final left = pttSessionLimit - sessionTalk(key);
    final most = left < pttMaxClip ? left : pttMaxClip;
    return max(
      0,
      min(_quality.maxFrames, most.inMilliseconds ~/ SosVoicePacket.frameMs),
    );
  }

  /// Puts the Voice channel on the radio, once per radio: if it's removed
  /// afterwards, it stays removed.
  void _onRadioChanged() {
    final index = pttChannel?.index;
    if (index != _pttChannelIndex) {
      _pttChannelIndex = index;
      notifyListeners();
    }
    if (_codec == null ||
        index != null ||
        _addingPttChannel ||
        !_transport.isConnected ||
        !_transport.channelsReady ||
        !_sos.supportsChannelAlerts) {
      return;
    }
    final self = _transport.selfPublicKey;
    if (self == null) return;
    final radio = self.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    if (_pttOfferedThisRun.contains(radio) ||
        (_pttChannelAddedBefore?.call(radio) ?? false)) {
      return;
    }
    final used = _transport.channels.map((c) => c.index).toSet();
    final free = [
      for (var i = 0; i < _transport.maxChannels; i++)
        if (!used.contains(i)) i,
    ];
    _pttOfferedThisRun.add(radio);
    if (free.isEmpty) return; // no room: the user can add it themselves
    _addingPttChannel = true;
    unawaited(() async {
      try {
        // the last free slot, leaving the first ones for the user's own
        await _transport.setChannel(free.last, pttChannelName, pttChannelPsk);
        _rememberPttChannelAdded?.call(radio);
      } catch (e) {
        debugPrint('Adding the Voice channel failed: $e');
      } finally {
        _addingPttChannel = false;
        notifyListeners();
      }
    }());
  }

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
    if (isPtt(sosId)) return false; // push-to-talk is held, never hands-free
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
    final talking = _pttSosId;
    if (talking != null) {
      if (_pttFrames.length < _maxFramesFor(talking)) _pttFrames.add(frame);
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
    if (isPtt(sosId)) {
      _countVoice(
        sosId,
        Duration(milliseconds: frames.length * SosVoicePacket.frameMs),
        sent: true,
      );
    }
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
    if (isPtt(clip.sosId)) return _sendPtt(clip);
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
      sealed: _sos.sealsNetwork,
    );
    final blobs = <Uint8List>[];
    for (final p in packets) {
      final blob = _sos.sealVoice(p.encode());
      if (blob == null) {
        clip.status = VoiceClipStatus.failed;
        notifyListeners();
        return;
      }
      blobs.add(blob);
    }
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

  Future<void> _sendPtt(VoiceClip clip) async {
    final codec = _codec;
    final self = _transport.selfPublicKey;
    if (codec == null || self == null || _pttSendBlock(clip.sosId) != null) {
      clip.status = VoiceClipStatus.failed;
      notifyListeners();
      return;
    }
    final direct = clip.sosId != pttChannelKey;
    final packets = SosVoicePacket.split(
      frames: codec.encode(_split(clip.pcm), clip.quality),
      quality: clip.quality,
      sosId: '0000',
      senderPrefix: self.sublist(0, SosVoicePacket.keyPrefixSize),
      clipId: _nextClipId++ & 0xFFFF,
      ptt: true,
      framesPerChunk: direct
          ? SosVoicePacket.directFramesPerChunk(clip.quality)
          : null,
    );
    clip
      ..status = VoiceClipStatus.sending
      ..totalChunks = packets.length;
    notifyListeners();
    void progress(int sent, int total) {
      clip.sentChunks = sent;
      notifyListeners();
    }

    var ok = false;
    try {
      if (direct) {
        ok = await _transport.sendDirect(
          _contactFor(clip.sosId)!,
          [for (final p in packets) p.toDirectText()],
          gap: _transport.chunkGap(SosVoicePacket.maxDirectText),
          onProgress: progress,
          stop: () => sosLive,
        );
      } else {
        ok = await _transport.sendChunks(
          pttChannel!.index,
          [for (final p in packets) p.encode()],
          gap: _transport.chunkGap(SosVoicePacket.maxBlobBytes),
          onProgress: progress,
          stop: () => sosLive,
        );
      }
    } catch (_) {
      ok = false;
    }
    clip.status = ok ? VoiceClipStatus.sent : VoiceClipStatus.failed;
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Listening
  // ---------------------------------------------------------------------

  /// A push-to-talk chunk heard, filed under [key].
  void _hearPtt(SosVoicePacket packet, String key) {
    final self = _transport.selfPublicKey;
    if (self != null &&
        listEquals(
          self.sublist(0, SosVoicePacket.keyPrefixSize),
          packet.senderPrefix,
        )) {
      return; // Our own clip, repeated back to us.
    }
    if (key == pttChannelKey) _channelChunkAt = _now();
    final done = _assembler.add(packet.withSosId(key));
    if (done != null) {
      if (key == pttChannelKey) _channelChunkAt = null;
      _deliver(done);
    }
    notifyListeners();
    _staleTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      checkStale();
    });
  }

  /// A direct message holding a push-to-talk chunk.
  @visibleForTesting
  void handleDirect(String senderKeyHex, String text) {
    if (_codec == null) return;
    final packet = SosVoicePacket.fromDirectText(text);
    if (packet == null) return;
    _hearPtt(packet, pttDirectKey(senderKeyHex));
  }

  /// A channel data packet of type [dataTypeSosVoice].
  @visibleForTesting
  void handleInbound(int channelIndex, Uint8List data) {
    final codec = _codec;
    if (codec == null) return;
    final ptt = pttChannel;
    if (ptt != null && ptt.index == channelIndex) {
      final packet = SosVoicePacket.decode(data);
      if (packet != null && packet.ptt) _hearPtt(packet, pttChannelKey);
      return;
    }
    if (_sos.sosChannel?.index != channelIndex) return;
    final plain = _sos.openVoice(data);
    if (plain == null) return;
    final packet = SosVoicePacket.decode(plain);
    if (packet == null || packet.ptt || !_isLive(packet.sosId)) return;
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
    final wasBusy = _channelChunkAt != null;
    for (final clip in _assembler.takeStale()) {
      _deliver(clip);
    }
    if (wasBusy && !channelBusy) {
      _channelChunkAt = null;
      notifyListeners(); // the channel is free again
    }
    if (!_assembler.hasPending && _channelChunkAt == null) {
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
    if (isPtt(frames.sosId)) {
      _countVoice(frames.sosId, frames.duration, sent: false);
      _unheard.add(frames.sosId);
      onPttClipHeard?.call(frames.sosId, clip);
    }
    _addClip(clip);
    // During an SOS, push-to-talk clips wait to be played by hand, so they
    // never talk over it.
    if (isPtt(frames.sosId) && sosLive) return;
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
        // levelled and at the chosen volume (rest tones as they are)
        await _audio.play(
          clip.sosId == 'ptt:rest'
              ? clip.pcm
              : SoundDevices.levelVoice(clip.pcm, SoundDevices.voiceVolume),
        );
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
    if (isPtt(clip.sosId)) _tidyPttClips();
    notifyListeners();
  }

  /// Drops push-to-talk clips past [pttClipKeep], then the oldest past
  /// [pttMaxClips]; true if any went.
  bool _tidyPttClips() {
    final cutoff = _now().subtract(pttClipKeep);
    var removed = false;
    for (final key in _clips.keys.where(isPtt).toList()) {
      final list = _clips[key]!;
      final before = list.length;
      list.removeWhere((c) => c.time.isBefore(cutoff) && !_inUse(c));
      if (list.length != before) removed = true;
      if (list.isEmpty) _clips.remove(key);
    }
    final all = [
      for (final e in _clips.entries)
        if (isPtt(e.key)) ...e.value,
    ]..sort((a, b) => a.time.compareTo(b.time));
    for (final clip in all.take(max(0, all.length - pttMaxClips))) {
      if (_inUse(clip)) continue;
      _clips[clip.sosId]?.remove(clip);
      if (_clips[clip.sosId]?.isEmpty ?? false) _clips.remove(clip.sosId);
      removed = true;
    }
    return removed;
  }

  /// A clip still being sent, or playing, isn't removed from under itself.
  bool _inUse(VoiceClip clip) =>
      identical(_playing, clip) ||
      clip.status == VoiceClipStatus.queued ||
      clip.status == VoiceClipStatus.sending;

  /// Deletes one clip, stopping it first if it's playing. A clip still being
  /// sent can't be deleted (false).
  Future<bool> deleteClip(VoiceClip clip) async {
    if (clip.status == VoiceClipStatus.queued ||
        clip.status == VoiceClipStatus.sending) {
      return false;
    }
    if (identical(_playing, clip)) await stopPlayback();
    _playQueue.remove(clip);
    final list = _clips[clip.sosId];
    if (list == null || !list.remove(clip)) return false;
    if (list.isEmpty) _clips.remove(clip.sosId);
    notifyListeners();
    return true;
  }

  /// Deletes every clip in [conversation] except any still being sent.
  Future<void> clearClips(String conversation) async {
    final list = _clips[conversation];
    if (list == null) return;
    if (_playing?.sosId == conversation) await stopPlayback();
    _playQueue.removeWhere((c) => c.sosId == conversation);
    list.removeWhere((c) => !_inUse(c));
    if (list.isEmpty) _clips.remove(conversation);
    notifyListeners();
  }

  /// Push-to-talk clips kept, over every conversation.
  int get pttClipCount => [
    for (final e in _clips.entries)
      if (isPtt(e.key)) ...e.value,
  ].length;

  /// Ends voice for any SOS that is over.
  void _onSosChanged() {
    final hf = _handsFreeSosId;
    if (hf != null && !_isLive(hf)) unawaited(setHandsFree(hf, false));
    final ptt = _pttSosId;
    if (ptt != null && (!_isLive(ptt) || (isPtt(ptt) && sosLive))) {
      unawaited(stopTalking(cancel: true));
    }
    if (sosLive) _sendQueue.removeWhere((c) => isPtt(c.sosId));
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
    _transport.directListener = null;
    _transport.changeListener = null;
    _staleTimer?.cancel();
    _waitTimer?.cancel();
    _tidyTimer?.cancel();
    unawaited(_micSub?.cancel());
    unawaited(_audio.dispose());
    super.dispose();
  }
}

/// One conversation's push-to-talk session: its voice so far, both ways,
/// when it last had any, and whether this person talked in it.
class _VoiceSession {
  Duration talk = Duration.zero;
  DateTime lastAt;
  bool talked = false;

  _VoiceSession(this.lastAt);
}
