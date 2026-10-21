import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/login_autostart.dart';

/// A stand-in for `reg.exe` over one Run key.
class FakeRegistry {
  final Map<String, String> values = {};
  final List<List<String>> calls = [];

  Future<ProcessResult> run(String executable, List<String> args) async {
    expect(executable, 'reg');
    calls.add(args);
    final name = args[args.indexOf('/v') + 1];
    switch (args.first) {
      case 'query':
        final value = values[name];
        if (value == null) return ProcessResult(0, 1, '', 'not found');
        return ProcessResult(
          0,
          0,
          '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\'
              'CurrentVersion\\Run\r\n    $name    REG_SZ    $value\r\n\r\n',
          '',
        );
      case 'add':
        values[name] = args[args.indexOf('/d') + 1];
        return ProcessResult(0, 0, '', '');
      case 'delete':
        values.remove(name);
        return ProcessResult(0, 0, '', '');
    }
    fail('Unexpected reg ${args.first}');
  }
}

void main() {
  late FakeRegistry registry;

  setUp(() => registry = FakeRegistry());

  WindowsAutostart at(String exe) =>
      WindowsAutostart(executable: exe, run: registry.run);

  test('turning it on adds a hidden-start Run value; off removes it', () async {
    final autostart = at(r'C:\Program Files\MeshCore Open\meshcore_open.exe');
    expect(await autostart.enabled(), isFalse);

    await autostart.setEnabled(true);
    expect(await autostart.enabled(), isTrue);
    expect(
      registry.values[WindowsAutostart.valueName],
      r'"C:\Program Files\MeshCore Open\meshcore_open.exe" --hidden',
    );
    final add = registry.calls.firstWhere((c) => c.first == 'add');
    expect(
      add,
      contains(r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'),
    );

    await autostart.setEnabled(false);
    expect(await autostart.enabled(), isFalse);
    // Turning it off again does not touch the registry.
    registry.calls.clear();
    await autostart.setEnabled(false);
    expect(registry.calls.map((c) => c.first), ['query']);
  });

  test('refresh follows a moved install, only when turned on', () async {
    await at(r'C:\Old\meshcore_open.exe').setEnabled(true);
    await at(r'D:\New\meshcore_open.exe').refresh();
    expect(
      registry.values[WindowsAutostart.valueName],
      r'"D:\New\meshcore_open.exe" --hidden',
    );

    registry.values.clear();
    await at(r'E:\Newer\meshcore_open.exe').refresh();
    expect(registry.values, isEmpty);
  });
}
