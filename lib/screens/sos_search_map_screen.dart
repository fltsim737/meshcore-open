import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../helpers/sos_search.dart';
import '../l10n/l10n.dart';
import '../models/sos_alert.dart';
import '../services/map_tile_cache_service.dart';
import '../services/sos_service.dart';

/// Every searcher's latest reading as a ring (how far their signal strength
/// puts the radio), and where the rings agree: the area to search first.
/// Searchers share readings every 30 s, so it fills in as they move.
class SosSearchMapScreen extends StatefulWidget {
  final IncomingSos alert;

  const SosSearchMapScreen({super.key, required this.alert});

  @override
  State<SosSearchMapScreen> createState() => _SosSearchMapScreenState();
}

class _SosSearchMapScreenState extends State<SosSearchMapScreen> {
  final _map = MapController();
  bool _fitted = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // readings age out of the estimate on their own
    _tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static const _colours = [
    Color(0xFF2563EB),
    Color(0xFF16A34A),
    Color(0xFF9333EA),
    Color(0xFFEA580C),
    Color(0xFF0891B2),
    Color(0xFFCA8A04),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final service = context.watch<SosService>();
    final tileCache = context.read<MapTileCacheService>();
    final session = service.locator;
    final now = DateTime.now();
    final searchers =
        session?.searchers.values.toList() ?? const <SosSearcher>[];
    final estimate = session?.estimate(now: now);
    final fix = widget.alert.fix;
    final last = fix.hasPosition ? LatLng(fix.latitude!, fix.longitude!) : null;

    final points = <LatLng>[
      for (final s in searchers)
        if (s.latest case final r?) LatLng(r.latitude, r.longitude),
      ?last,
      if (estimate != null) LatLng(estimate.latitude, estimate.longitude),
    ];
    if (!_fitted && points.isNotEmpty) {
      _fitted = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (points.length == 1) {
          _map.move(points.single, 16);
        } else {
          _map.fitCamera(
            CameraFit.coordinates(
              coordinates: points,
              padding: const EdgeInsets.all(48),
              maxZoom: 18,
            ),
          );
        }
      });
    }

    final rings = <CircleMarker>[];
    final markers = <Marker>[];
    for (var i = 0; i < searchers.length; i++) {
      final s = searchers[i];
      final r = s.latest;
      if (r == null || now.difference(r.at) > SosSearch.maxAge) continue;
      final colour = s.mine
          ? const Color(0xFFDC2626)
          : _colours[i % _colours.length];
      final at = LatLng(r.latitude, r.longitude);
      final ring = SosSearch.ring(r.rssiDbm, r.beaconPower);
      final mid = SosSearch.rangeMetres(r.rssiDbm, r.beaconPower);
      // the band the radio is probably in, drawn as a thick ring at the likely range
      rings.add(
        CircleMarker(
          point: at,
          radius: mid,
          useRadiusInMeter: true,
          color: Colors.transparent,
          borderColor: colour.withValues(alpha: 0.75),
          borderStrokeWidth: 3,
        ),
      );
      rings.add(
        CircleMarker(
          point: at,
          radius: ring.outer,
          useRadiusInMeter: true,
          color: Colors.transparent,
          borderColor: colour.withValues(alpha: 0.25),
          borderStrokeWidth: 1.5,
        ),
      );
      markers.add(
        Marker(
          point: at,
          width: 120,
          height: 44,
          child: Column(
            children: [
              Icon(Icons.person_pin_circle, color: colour, size: 28),
              Text(
                s.mine ? l10n.sosSearchMap_you : s.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: colour,
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (last != null) {
      markers.add(
        Marker(
          point: last,
          width: 140,
          height: 44,
          child: Column(
            children: [
              const Icon(Icons.sos, color: Color(0xFFDC2626), size: 26),
              Text(
                l10n.sosSearchMap_lastPosition,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFDC2626),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final area = estimate == null
        ? const <CircleMarker>[]
        : [
            CircleMarker(
              point: LatLng(estimate.latitude, estimate.longitude),
              radius: estimate.radiusMetres,
              useRadiusInMeter: true,
              color: const Color(0xFFDC2626).withValues(alpha: 0.18),
              borderColor: const Color(0xFFDC2626),
              borderStrokeWidth: 2,
            ),
          ];

    final readings = session?.readings.length ?? 0;
    final status = estimate != null
        ? l10n.sosSearchMap_estimate(
            (estimate.radiusMetres * 2).round(),
            estimate.readings,
            estimate.places,
          )
        : readings == 0
        ? l10n.sosSearchMap_noReadings
        : l10n.sosSearchMap_needMore;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.sosSearchMap_title), centerTitle: true),
      body: Column(
        children: [
          Expanded(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: points.isNotEmpty
                    ? points.first
                    : const LatLng(0, 0),
                initialZoom: points.isNotEmpty ? 15 : 2,
              ),
              children: [
                tileCache.buildTileLayer(context),
                CircleLayer(circles: [...area, ...rings]),
                MarkerLayer(markers: markers),
              ],
            ),
          ),
          Material(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    status,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l10n.sosSearchMap_explain,
                    style: const TextStyle(fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
