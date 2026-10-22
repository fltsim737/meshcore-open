import 'dart:convert';
import 'dart:typed_data';

/// A repeater's reply to `reqTypeGetOwnerInfo`: firmware version, node name
/// and the operator's free text, separated by newlines.
class RepeaterOwnerInfo {
  final String firmwareVersion;
  final String nodeName;
  final String ownerInfo;

  const RepeaterOwnerInfo({
    required this.firmwareVersion,
    required this.nodeName,
    required this.ownerInfo,
  });

  /// Parses the response data after the 4-byte tag; null if it is not one.
  static RepeaterOwnerInfo? parse(Uint8List data) {
    final end = data.indexOf(0);
    final text = utf8.decode(
      end >= 0 ? data.sublist(0, end) : data,
      allowMalformed: true,
    );
    final lines = text.split('\n');
    if (lines.length < 2) return null;
    return RepeaterOwnerInfo(
      firmwareVersion: lines[0].trim(),
      nodeName: lines[1].trim(),
      // The operator's text keeps its own line breaks.
      ownerInfo: lines.skip(2).join('\n').trim(),
    );
  }
}
