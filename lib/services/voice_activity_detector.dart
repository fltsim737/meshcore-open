import 'dart:math';
import 'dart:typed_data';

/// Hands-free (VOX) clip detection on 40 ms frames of 16-bit audio.
///
/// Speech starts when [startFrames] frames in a row are loud enough above
/// the tracked background noise, and ends after [hangFrames] quiet frames.
/// Each clip keeps [preRollFrames] from before the start, so the first
/// syllable is not cut off, and is closed early at [maxFrames] so a long
/// speech goes out in pieces instead of waiting until it ends.
class VoiceActivityDetector {
  final int startFrames;
  final int hangFrames;
  final int preRollFrames;
  final int minSpeechFrames;
  final int maxFrames;

  /// How far above the noise floor a frame must be to count as speech.
  final double marginDb;

  /// Frames quieter than this never count as speech.
  final double floorDb;

  final void Function(List<Int16List> frames) onClip;

  /// Called when speech starts or stops, for the UI.
  final void Function(bool speaking)? onSpeakingChanged;

  double _noiseDb = -60;
  int _loudRun = 0;
  int _quietRun = 0;
  int _speechFrames = 0;
  bool _speaking = false;
  final List<Int16List> _preRoll = [];
  final List<Int16List> _clip = [];

  VoiceActivityDetector({
    required this.onClip,
    required this.maxFrames,
    this.onSpeakingChanged,
    this.startFrames = 3,
    this.hangFrames = 30,
    this.preRollFrames = 8,
    this.minSpeechFrames = 12,
    this.marginDb = 12,
    this.floorDb = -50,
  });

  bool get isSpeaking => _speaking;

  /// Loudness of a frame in dB relative to full scale.
  static double levelDb(Int16List frame) {
    if (frame.isEmpty) return -120;
    var sum = 0.0;
    for (final s in frame) {
      sum += s * s;
    }
    final rms = sqrt(sum / frame.length) / 32768.0;
    return rms <= 0 ? -120 : 20 * log(rms) / ln10;
  }

  void addFrame(Int16List frame) {
    final db = levelDb(frame);
    final loud = db > max(_noiseDb + marginDb, floorDb);
    if (!loud) {
      // Follow quiet levels quickly and loud ones slowly, so speech itself
      // does not raise the floor.
      _noiseDb = db < _noiseDb ? db : _noiseDb + (db - _noiseDb) * 0.02;
    }

    if (!_speaking) {
      _preRoll.add(frame);
      if (_preRoll.length > preRollFrames + startFrames) _preRoll.removeAt(0);
      _loudRun = loud ? _loudRun + 1 : 0;
      if (_loudRun >= startFrames) {
        _speaking = true;
        _clip
          ..clear()
          ..addAll(_preRoll);
        _preRoll.clear();
        _speechFrames = _loudRun;
        _quietRun = 0;
        onSpeakingChanged?.call(true);
      }
      return;
    }

    _clip.add(frame);
    if (loud) {
      _speechFrames++;
      _quietRun = 0;
    } else {
      _quietRun++;
    }
    if (_quietRun >= hangFrames) {
      _finish(trimTail: true);
    } else if (_clip.length >= maxFrames) {
      // Keep listening: the speaker is still going.
      _emit(List.of(_clip));
      _clip.clear();
      _speechFrames = 0;
    }
  }

  /// Ends any clip in progress, as when hands-free is turned off.
  void flush() {
    if (_speaking) _finish(trimTail: false);
  }

  /// Drops any clip in progress, as while a received clip plays aloud.
  void reset() {
    final was = _speaking;
    _speaking = false;
    _loudRun = 0;
    _quietRun = 0;
    _speechFrames = 0;
    _clip.clear();
    _preRoll.clear();
    if (was) onSpeakingChanged?.call(false);
  }

  void _finish({required bool trimTail}) {
    final frames = List.of(_clip);
    if (trimTail) {
      // Keep a short tail of the trailing silence.
      final drop = max(0, _quietRun - 6);
      frames.removeRange(
        frames.length - min(drop, frames.length),
        frames.length,
      );
    }
    final enough = _speechFrames >= minSpeechFrames;
    reset();
    if (enough && frames.isNotEmpty) _emit(frames);
  }

  void _emit(List<Int16List> frames) => onClip(frames);
}
