/// Where the coverage survey is kept between runs.
abstract class CoverageSurveyStore {
  Future<String?> read();
  Future<void> write(String text);
  Future<void> delete();
}

/// Keeps the survey in memory only (web, and tests).
class MemoryCoverageStore implements CoverageSurveyStore {
  String? _text;

  @override
  Future<String?> read() async => _text;

  @override
  Future<void> write(String text) async => _text = text;

  @override
  Future<void> delete() async => _text = null;
}
