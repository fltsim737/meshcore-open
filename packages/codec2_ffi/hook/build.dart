// Builds Codec2 for iOS as a native code asset (Flutter bundles it as
// codec2_ffi.framework). Android, Linux and Windows keep their CMake builds
// (see src/CMakeLists.txt), so this hook does nothing for them.
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS != OS.iOS) return;

    final srcDir = input.packageRoot.resolve('src/codec2/');
    final sources =
        Directory.fromUri(srcDir)
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.c'))
            .map((f) => 'src/codec2/${f.uri.pathSegments.last}')
            .toList()
          ..sort();

    await CBuilder.library(
      name: 'codec2_ffi',
      assetName: 'codec2_ffi.dart',
      sources: sources,
      includes: ['src/codec2', 'src/codec2/codec2'],
      flags: ['-w'],
      linkModePreference: LinkModePreference.dynamic,
    ).run(input: input, output: output);
  });
}
