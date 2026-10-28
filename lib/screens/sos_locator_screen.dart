import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart' show LatLng;
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../models/sos_alert.dart';
import '../helpers/sos_codec.dart';
import '../services/sos_service.dart';
import 'map_screen.dart';
import 'sos_search_map_screen.dart';

/// A responder closing in on the radio that sent an SOS. While this screen is
/// open the app asks that radio for a beacon every few seconds; beacons go
/// radio to radio only, never through a repeater, so each one heard was heard
/// directly and its strength says how near the radio is ("warmer, colder").
class SosLocatorScreen extends StatefulWidget {
  final IncomingSos alert;

  const SosLocatorScreen({super.key, required this.alert});

  @override
  State<SosLocatorScreen> createState() => _SosLocatorScreenState();
}

class _SosLocatorScreenState extends State<SosLocatorScreen> {
  late final SosService _service;
  Timer? _tick;
  int _heard = 0;

  /// A beacon not heard for this long: probably out of direct range.
  static const Duration _quiet = Duration(seconds: 16);

  @override
  void initState() {
    super.initState();
    _service = context.read<SosService>();
    _service.addListener(_onChange);
    // after the first frame: starting notifies listeners, not allowed mid-build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _service.startLocating(widget.alert);
    });
    // the "seconds ago" and next-request countdown move on their own
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _onChange() {
    final count = _service.locator?.samples.length ?? 0;
    if (count > _heard) {
      HapticFeedback.mediumImpact(); // feel each beacon while walking
    }
    _heard = count;
  }

  @override
  void dispose() {
    _tick?.cancel();
    _service.removeListener(_onChange);
    _service.stopLocating(notify: false); // the tree is being torn down
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final service = context.watch<SosService>();
    final session = service.locator;
    final latest = session?.latest;
    final now = DateTime.now();
    final since = latest == null ? null : now.difference(latest.at);
    final quiet = since == null || since > _quiet;
    final fix = widget.alert.fix;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.sosLocator_title(widget.alert.senderName)),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _Meter(sample: quiet ? null : latest),
          const SizedBox(height: 12),
          _TrendLine(session: session, quiet: quiet),
          const SizedBox(height: 4),
          Text(
            latest == null
                ? l10n.sosLocator_waiting
                : l10n.sosLocator_lastBeacon(
                    since!.inSeconds,
                    session!.samples.length,
                  ),
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          if (session != null && session.samples.length > 1)
            SizedBox(
              height: 90,
              child: CustomPaint(
                painter: _HistoryPainter(
                  session.samples,
                  scheme.primary,
                  scheme.outlineVariant,
                ),
              ),
            ),
          const SizedBox(height: 16),
          _PowerCard(session: session, service: service),
          const SizedBox(height: 8),
          FilledButton.icon(
            icon: const Icon(Icons.travel_explore),
            label: Text(l10n.sosLocator_mapButton),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SosSearchMapScreen(alert: widget.alert),
              ),
            ),
          ),
          if (session != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                l10n.sosLocator_sharing(session.searchers.length),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.sosLocator_directionTitle,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(l10n.sosLocator_direction),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.sosLocator_howTitle,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(l10n.sosLocator_how),
                  const SizedBox(height: 8),
                  Text(l10n.sosLocator_tip),
                ],
              ),
            ),
          ),
          if (fix.hasPosition) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.map_outlined),
              label: Text(l10n.sosLocator_lastPosition),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MapScreen(
                    highlightPosition: LatLng(fix.latitude!, fix.longitude!),
                    highlightLabel: widget.alert.senderName,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (session?.lastRequestAt case final asked?)
            Text(
              l10n.sosLocator_requests(
                session!.requests,
                math.max(
                  0,
                  (SosService.locateRepeat - now.difference(asked)).inSeconds,
                ),
              ),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

/// The beacons' power: what it is now and who set it, and the steps any
/// searcher can choose (agreed with the others over the radio).
class _PowerCard extends StatelessWidget {
  final SosLocatorSession? session;
  final SosService service;

  const _PowerCard({required this.session, required this.service});

  /// The steps offered, in dBm (null: the radio's own power).
  static const List<int?> steps = [null, 14, 8, 2, -9];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final s = session;
    final known = s?.beaconPower != null;
    final asked = s?.askedPower;
    String stepLabel(int? dbm) => switch (dbm) {
      null => l10n.sosLocator_powerFull,
      14 => l10n.sosLocator_powerHigh,
      8 => l10n.sosLocator_powerMedium,
      2 => l10n.sosLocator_powerLow,
      _ => l10n.sosLocator_powerVeryLow,
    };
    int? current;
    if (s != null && known) current = s.beaconFull ? null : s.beaconPower;
    final now = s == null || !known
        ? l10n.sosLocator_powerUnknown
        : s.beaconFull
        ? l10n.sosLocator_powerNowFull
        : l10n.sosLocator_powerNow(s.beaconPower!);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.sosLocator_powerTitle,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              [
                now,
                if (known && s!.setBy.isNotEmpty)
                  l10n.sosLocator_powerSetBy(s.setBy),
              ].join(' · '),
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: known ? scheme.primary : scheme.onSurfaceVariant,
              ),
            ),
            if (asked != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  l10n.sosLocator_powerAsking(
                    stepLabel(asked == SosPacket.powerFull ? null : asked),
                  ),
                  style: TextStyle(color: scheme.tertiary),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final step in steps)
                  ChoiceChip(
                    label: Text(
                      step == null
                          ? stepLabel(step)
                          : '${stepLabel(step)} · $step dBm',
                    ),
                    selected: known && current == step,
                    onSelected: known
                        ? (_) => service.setBeaconPower(step)
                        : null,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l10n.sosLocator_powerHelp,
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// How strong the latest beacon is, 0 to 1: RSSI from -125 dBm (barely
/// heard) to -60 dBm (right beside it), or SNR from -18 dB to +12 dB.
double strengthFraction(SosBeaconSample sample) {
  final rssi = sample.rssiDbm;
  final v = rssi != null ? (rssi + 125) / 65 : (sample.snrDb + 18) / 30;
  return v.clamp(0.0, 1.0);
}

class _Meter extends StatelessWidget {
  final SosBeaconSample? sample;

  const _Meter({required this.sample});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final s = sample;
    final fraction = s == null ? 0.0 : strengthFraction(s);
    final color = s == null
        ? Theme.of(context).colorScheme.outline
        : Color.lerp(
            const Color(0xFF2563EB), // cold: far
            const Color(0xFFDC2626), // hot: close
            fraction,
          )!;
    final label = s == null
        ? l10n.sosLocator_noSignal
        : fraction > 0.8
        ? l10n.sosLocator_veryClose
        : fraction > 0.55
        ? l10n.sosLocator_close
        : fraction > 0.3
        ? l10n.sosLocator_nearby
        : l10n.sosLocator_faint;
    return AspectRatio(
      aspectRatio: 1.6,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox.expand(
            child: CustomPaint(
              painter: _GaugePainter(
                fraction,
                color,
                Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 28),
              Text(
                label,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (s != null) ...[
                const SizedBox(height: 4),
                Text(
                  [
                    if (s.rssiDbm != null) '${s.rssiDbm} dBm',
                    'SNR ${s.snrDb.toStringAsFixed(1)} dB',
                  ].join('  ·  '),
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color track;

  _GaugePainter(this.fraction, this.color, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.07;
    final radius = math.min(size.width / 2, size.height) - stroke;
    final center = Offset(size.width / 2, size.height - stroke / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, base..color = track);
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        math.pi,
        math.pi * fraction,
        false,
        base..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.color != color;
}

class _TrendLine extends StatelessWidget {
  final SosLocatorSession? session;
  final bool quiet;

  const _TrendLine({required this.session, required this.quiet});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final trend = quiet ? null : session?.trend;
    final (IconData icon, Color color, String text) = switch (trend) {
      null when quiet && (session?.samples.isNotEmpty ?? false) => (
        Icons.signal_wifi_off,
        Colors.orange,
        l10n.sosLocator_lost,
      ),
      null => (Icons.more_horiz, Colors.grey, l10n.sosLocator_keepMoving),
      > 1.5 => (
        Icons.arrow_upward,
        const Color(0xFF16A34A),
        l10n.sosLocator_warmer,
      ),
      < -1.5 => (
        Icons.arrow_downward,
        const Color(0xFFDC2626),
        l10n.sosLocator_colder,
      ),
      _ => (Icons.arrow_forward, Colors.grey, l10n.sosLocator_steady),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 30),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

/// The strength of each beacon heard, oldest on the left.
class _HistoryPainter extends CustomPainter {
  final List<SosBeaconSample> samples;
  final Color line;
  final Color grid;

  _HistoryPainter(this.samples, this.line, this.grid);

  @override
  void paint(Canvas canvas, Size size) {
    final g = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = size.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), g);
    }
    final shown = samples.length > 60
        ? samples.sublist(samples.length - 60)
        : samples;
    final path = Path();
    for (var i = 0; i < shown.length; i++) {
      final x = shown.length == 1
          ? size.width
          : size.width * i / (shown.length - 1);
      final y = size.height * (1 - strengthFraction(shown[i]));
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_HistoryPainter old) => true;
}
