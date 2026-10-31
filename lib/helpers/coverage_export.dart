import 'dart:convert';

import '../helpers/coverage_grid.dart';
import '../models/coverage_survey.dart';

/// File formats for a coverage survey: the app's own file (which imports back
/// and merges), GeoJSON and KML (for Google Earth and GIS tools).
class CoverageExport {
  CoverageExport._();

  static const String format = 'meshcore-coverage-survey';
  static const int version = 1;

  /// Imports bigger than this are refused before parsing.
  static const int maxImportBytes = 20 * 1024 * 1024;

  static String surveyFile(List<CoveragePing> pings, {String? by}) =>
      const JsonEncoder.withIndent(' ').convert({
        'format': format,
        'version': version,
        'exported': DateTime.now().toUtc().toIso8601String(),
        'by': ?by,
        'pings': [for (final p in pings) p.toJson()],
      });

  /// The pings in a survey file. Throws [FormatException] when it isn't one.
  static List<CoveragePing> parseSurveyFile(String text) {
    final body = text.startsWith('﻿') ? text.substring(1) : text;
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw const FormatException('not JSON');
    }
    if (json is! Map || json['format'] != format) {
      throw const FormatException('not a coverage survey');
    }
    final v = json['version'];
    if (v is! int || v > version) {
      throw const FormatException('newer survey version');
    }
    final raw = json['pings'];
    if (raw is! List) throw const FormatException('no pings');
    return [for (final p in raw) ?CoveragePing.fromJson(p)];
  }

  static String gradeName(CoverageGrade grade) => grade.name;

  /// Fill colours as #RRGGBB, matching the map.
  static const Map<CoverageGrade, String> gradeColours = {
    CoverageGrade.strong: '#16A34A',
    CoverageGrade.good: '#84CC16',
    CoverageGrade.weak: '#F59E0B',
    CoverageGrade.marginal: '#DC2626',
    CoverageGrade.none: '#6B7280',
  };

  static List<CoverageRadio> radiosOf(List<CoveragePing> pings) {
    final seen = <String, CoverageRadio>{};
    for (final p in pings) {
      seen.putIfAbsent(p.radio.key, () => p.radio);
    }
    return seen.values.toList();
  }

  static String _hexName(CoverageCellSummary s, CoverageMap map) {
    final names = [
      for (final key in s.repeaters.keys) map.repeaters[key]?.name ?? key,
    ];
    return names.join(', ');
  }

  static String geoJson(List<CoveragePing> pings) {
    final features = <Map<String, dynamic>>[];
    for (final radio in radiosOf(pings)) {
      final map = CoverageMap.build(pings, radio: radio);
      for (final s in map.cells.values) {
        final ring = [
          for (final c in s.cell.corners) [_r6(c.longitude), _r6(c.latitude)],
        ];
        ring.add(ring.first);
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [ring],
          },
          'properties': {
            'kind': 'cell',
            'radio': radio.label,
            'grade': gradeName(s.grade),
            'fill': gradeColours[s.grade],
            'fill-opacity': 0.45,
            'stroke-width': 0,
            'best_link_snr_db': s.bestLinkSnr,
            'pings': s.pings,
            'answered': s.answered,
            'repeaters': _hexName(s, map),
          },
        });
      }
      for (final r in map.repeaters.values) {
        if (!r.hasLocation) continue;
        features.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [_r6(r.longitude!), _r6(r.latitude!)],
          },
          'properties': {
            'kind': 'repeater',
            'radio': radio.label,
            'name': r.name,
            'key': r.keyHex,
            'best_link_snr_db': r.bestLinkSnr,
            'grade': gradeName(r.grade),
            'cells': r.cells,
            'marker-color': gradeColours[r.grade],
          },
        });
      }
    }
    for (final p in pings) {
      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [_r6(p.longitude), _r6(p.latitude)],
        },
        'properties': {
          'kind': 'ping',
          'time': p.at.toUtc().toIso8601String(),
          'radio': p.radio.label,
          'by': ?p.by,
          'replies': [
            for (final r in p.replies)
              {
                'name': r.name,
                'key': r.keyHex,
                'snr_db': r.snr,
                'remote_snr_db': r.remoteSnr,
                'rssi_dbm': r.rssi,
              },
          ],
        },
      });
    }
    return const JsonEncoder.withIndent(
      ' ',
    ).convert({'type': 'FeatureCollection', 'features': features});
  }

  static String kml(List<CoveragePing> pings, {required String title}) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2">')
      ..writeln('<Document>')
      ..writeln('<name>${_x(title)}</name>');
    for (final grade in CoverageGrade.values) {
      b
        ..writeln('<Style id="${grade.name}">')
        ..writeln(
          '<LineStyle><width>0</width></LineStyle>'
          '<PolyStyle><color>${_kmlColour(gradeColours[grade]!, 0x73)}</color>'
          '<outline>0</outline></PolyStyle>'
          '<IconStyle><color>${_kmlColour(gradeColours[grade]!, 0xFF)}</color>'
          '</IconStyle>',
        )
        ..writeln('</Style>');
    }
    for (final radio in radiosOf(pings)) {
      final map = CoverageMap.build(pings, radio: radio);
      b
        ..writeln('<Folder>')
        ..writeln('<name>${_x(radio.label)}</name>');
      b.writeln('<Folder><name>Coverage</name>');
      for (final s in map.cells.values) {
        final coords = [
          ...s.cell.corners,
          s.cell.corners.first,
        ].map((c) => '${_r6(c.longitude)},${_r6(c.latitude)},0').join(' ');
        final snr = s.bestLinkSnr == null
            ? 'no reply'
            : '${s.bestLinkSnr!.toStringAsFixed(1)} dB';
        b
          ..writeln('<Placemark>')
          ..writeln('<styleUrl>#${s.grade.name}</styleUrl>')
          ..writeln(
            '<description>${_x('$snr, ${s.answered}/${s.pings} pings answered'
            '${s.repeaters.isEmpty ? '' : ': ${_hexName(s, map)}'}')}'
            '</description>',
          )
          ..writeln(
            '<Polygon><outerBoundaryIs><LinearRing><coordinates>'
            '$coords</coordinates></LinearRing></outerBoundaryIs></Polygon>',
          )
          ..writeln('</Placemark>');
      }
      b.writeln('</Folder>');
      b.writeln('<Folder><name>Repeaters</name>');
      for (final r in map.repeaters.values) {
        if (!r.hasLocation) continue;
        b
          ..writeln('<Placemark>')
          ..writeln('<name>${_x(r.name)}</name>')
          ..writeln('<styleUrl>#${r.grade.name}</styleUrl>')
          ..writeln(
            '<description>${_x('Best link ${r.bestLinkSnr.toStringAsFixed(1)} dB, '
            'heard in ${r.cells} cells')}</description>',
          )
          ..writeln(
            '<Point><coordinates>${_r6(r.longitude!)},${_r6(r.latitude!)},0'
            '</coordinates></Point>',
          )
          ..writeln('</Placemark>');
      }
      b
        ..writeln('</Folder>')
        ..writeln('</Folder>');
    }
    b
      ..writeln('</Document>')
      ..writeln('</kml>');
    return b.toString();
  }

  static double _r6(double v) => (v * 1e6).round() / 1e6;

  /// KML colours are aabbggrr.
  static String _kmlColour(String rgb, int alpha) {
    final r = rgb.substring(1, 3), g = rgb.substring(3, 5);
    final bl = rgb.substring(5, 7);
    return '${alpha.toRadixString(16).padLeft(2, '0')}$bl$g$r'.toLowerCase();
  }

  static String _x(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
