import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/app_settings_service.dart';

import 'sos_service_test.dart' show freshSettings;

void main() {
  test(
    'the SOS alarm is Morse by default, and can be the classic tone',
    () async {
      final settings = await freshSettings();
      expect(settings.sosAlarmTone, AppSettingsService.alarmToneMorse);
      var notified = 0;
      settings.addListener(() => notified++);
      await settings.setSosAlarmTone(AppSettingsService.alarmToneClassic);
      expect(settings.sosAlarmTone, AppSettingsService.alarmToneClassic);
      expect(
        AppSettingsService.sosAlarmToneSaved,
        AppSettingsService.alarmToneClassic,
      );
      expect(notified, 1);
      await settings.setSosAlarmTone(AppSettingsService.alarmToneMorse);
      expect(
        AppSettingsService.sosAlarmToneSaved,
        AppSettingsService.alarmToneMorse,
      );
    },
  );
}
