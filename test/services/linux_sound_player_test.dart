import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/linux_sound_player.dart';

const _repeat = Duration(milliseconds: 40);

void main() {
  late List<String> played;
  late LinuxSoundPlayer sound;

  setUp(() {
    played = [];
    sound = LinuxSoundPlayer(
      alarmRepeat: _repeat,
      play: (name) async => played.add(name),
    );
  });

  tearDown(() => sound.stopAll());

  Future<void> wait(int repeats) =>
      Future<void>.delayed(_repeat * repeats + _repeat ~/ 2);

  test('messages and events play once', () {
    sound.playMessage();
    sound.playEvent();
    expect(played, ['message-new-instant', 'complete']);
  });

  test('the alarm repeats until every SOS is cleared', () async {
    sound.startAlarm(1);
    sound.startAlarm(2);
    // A repeat of an alert already sounding does not start a second loop.
    sound.startAlarm(1);
    played.clear();
    await wait(2);
    expect(played.length, inInclusiveRange(1, 3));
    expect(played.toSet(), {'alarm-clock-elapsed'});

    // Still sounding while another alert is open.
    sound.stopAlarm(1);
    played.clear();
    await wait(1);
    expect(played, isNotEmpty);

    sound.stopAlarm(2);
    played.clear();
    await wait(3);
    expect(played, isEmpty);
  });

  test('stopAll silences everything', () async {
    sound.startAlarm(1);
    sound.stopAll();
    played.clear();
    await wait(2);
    expect(played, isEmpty);
  });

  test(
    'the alarm plays the Morse file once it is set, and warnings differ',
    () async {
      sound.alarmSound = '/tmp/meshcore_sos_morse.wav';
      sound.startAlarm(1);
      sound.playWarning();
      expect(played, ['/tmp/meshcore_sos_morse.wav', 'dialog-warning']);
      sound.stopAll();
    },
  );
}
