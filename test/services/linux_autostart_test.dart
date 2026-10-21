import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/linux_autostart.dart';

void main() {
  late Directory config;

  setUp(() => config = Directory.systemTemp.createTempSync('autostart'));
  tearDown(() => config.deleteSync(recursive: true));

  File entry() => File('${config.path}/autostart/meshcore-open.desktop');

  test('turning it on writes a hidden-start entry; off removes it', () async {
    final autostart = LinuxAutostart(
      configHome: config.path,
      launchPath: '/home/sam/MeshCore_Open_SOS-x86_64.AppImage',
    );
    expect(autostart.isEnabled, isFalse);

    await autostart.setEnabled(true);
    expect(autostart.isEnabled, isTrue);
    final text = entry().readAsStringSync();
    expect(
      text,
      contains('Exec="/home/sam/MeshCore_Open_SOS-x86_64.AppImage" --hidden\n'),
    );
    expect(text, startsWith('[Desktop Entry]\n'));
    // Skipped at login if the AppImage has gone.
    expect(
      text,
      contains('TryExec=/home/sam/MeshCore_Open_SOS-x86_64.AppImage\n'),
    );

    await autostart.setEnabled(false);
    expect(autostart.isEnabled, isFalse);
    expect(entry().existsSync(), isFalse);
    // Turning it off again is harmless.
    await autostart.setEnabled(false);
  });

  test('refresh follows a moved AppImage, only when turned on', () async {
    await LinuxAutostart(
      configHome: config.path,
      launchPath: '/old/app.AppImage',
    ).setEnabled(true);

    await LinuxAutostart(
      configHome: config.path,
      launchPath: '/new/app.AppImage',
    ).refresh();
    expect(entry().readAsStringSync(), contains('Exec="/new/app.AppImage"'));

    entry().deleteSync();
    await LinuxAutostart(
      configHome: config.path,
      launchPath: '/newer/app.AppImage',
    ).refresh();
    expect(entry().existsSync(), isFalse);
  });

  test('quotes awkward paths for the Exec line', () async {
    final autostart = LinuxAutostart(
      configHome: config.path,
      launchPath: r'/home/sam/My Apps/50% "SOS"/$app',
    );
    await autostart.setEnabled(true);
    expect(
      entry().readAsStringSync(),
      contains(r'Exec="/home/sam/My Apps/50%% \\"SOS\\"/\\$app" --hidden'),
    );
  });
}
