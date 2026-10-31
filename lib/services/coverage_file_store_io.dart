import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'coverage_survey_store.dart';

/// The coverage survey, as one JSON file in the app's support folder. It is
/// global, not per radio: coverage belongs to the repeaters, and searchers
/// swap radios.
class CoverageFileStore implements CoverageSurveyStore {
  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/coverage_survey.json');
  }

  @override
  Future<String?> read() async {
    final file = await _file();
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  /// Writes through a temporary file so a crash never leaves half a survey.
  @override
  Future<void> write(String text) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
  }

  @override
  Future<void> delete() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}
