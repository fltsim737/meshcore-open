import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../services/sos_location_service.dart';
import '../services/sos_service.dart';
import '../screens/sos_network_screen.dart';
import 'mesh_nav_tile.dart';

/// Stored emergency location, emergency network and emergency contacts.
class SosSettingsSection extends StatelessWidget {
  const SosSettingsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settingsService = context.watch<AppSettingsService>();
    final settings = settingsService.settings;
    final lat = settings.sosLatitude;
    final lon = settings.sosLongitude;
    final sos = context.watch<SosService>();
    final network = sos.network;

    return Column(
      children: [
        MeshNavTile(
          icon: Icons.home_work_outlined,
          title: l10n.sos_storedLocation,
          subtitle: lat != null && lon != null
              ? '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
              : l10n.sos_storedLocationUnset,
          onTap: () => _editLocation(context, settingsService),
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.shield_outlined,
          title: l10n.sos_network,
          subtitle: network == null
              ? l10n.sos_networkNoneSubtitle
              : '${l10n.sos_networkSummary(network.name, sosRoleLabel(l10n, network.role))}\n'
                    '${sosNetworkStatusLabel(l10n, sos.networkStatus)}',
          subtitleMaxLines: 3,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SosNetworkScreen()),
          ),
        ),
        const Divider(height: 1, indent: 16),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          secondary: const Icon(Icons.star_outline, size: 24),
          title: Text(l10n.sos_includeFavourites),
          subtitle: Text(l10n.sos_includeFavouritesSubtitle),
          value: settings.sosIncludeFavourites,
          onChanged: settingsService.setSosIncludeFavourites,
        ),
        const Divider(height: 1, indent: 16),
        MeshNavTile(
          icon: Icons.contact_emergency_outlined,
          title: l10n.sos_contacts,
          subtitle: l10n.sos_contactsSubtitle(settings.sosContactKeys.length),
          onTap: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (_) => const _SosContactsSheet(),
          ),
        ),
      ],
    );
  }

  Future<void> _editLocation(
    BuildContext context,
    AppSettingsService settingsService,
  ) async {
    final result = await showDialog<(double?, double?)>(
      context: context,
      builder: (_) => SosLocationDialog(
        initialLatitude: settingsService.settings.sosLatitude,
        initialLongitude: settingsService.settings.sosLongitude,
        phoneLocation: context.read<SosService>().phoneLocation,
      ),
    );
    if (result == null) return;
    await settingsService.setSosLocation(result.$1, result.$2);
  }
}

/// Pops `(latitude, longitude)`, or `(null, null)` to clear the location.
class SosLocationDialog extends StatefulWidget {
  final double? initialLatitude;
  final double? initialLongitude;
  final PhoneLocationProvider? phoneLocation;

  const SosLocationDialog({
    super.key,
    this.initialLatitude,
    this.initialLongitude,
    this.phoneLocation,
  });

  @override
  State<SosLocationDialog> createState() => _SosLocationDialogState();
}

class _SosLocationDialogState extends State<SosLocationDialog> {
  late final TextEditingController _latController = TextEditingController(
    text: widget.initialLatitude?.toStringAsFixed(5) ?? '',
  );
  late final TextEditingController _lonController = TextEditingController(
    text: widget.initialLongitude?.toStringAsFixed(5) ?? '',
  );
  String? _error;
  bool _locating = false;

  Future<void> _useCurrentGps(PhoneLocationProvider provider) async {
    setState(() {
      _locating = true;
      _error = null;
    });
    await provider.requestPermission();
    final fix = await provider.currentFix();
    if (!mounted) return;
    setState(() {
      _locating = false;
      if (fix == null || !fix.hasPosition) {
        _error = context.l10n.sos_gpsUnavailable;
        return;
      }
      _latController.text = fix.latitude!.toStringAsFixed(5);
      _lonController.text = fix.longitude!.toStringAsFixed(5);
    });
  }

  @override
  void dispose() {
    _latController.dispose();
    _lonController.dispose();
    super.dispose();
  }

  void _save() {
    final l10n = context.l10n;
    final latText = _latController.text.trim();
    final lonText = _lonController.text.trim();
    if (latText.isEmpty && lonText.isEmpty) {
      Navigator.pop(context, (null, null));
      return;
    }
    if (latText.isEmpty || lonText.isEmpty) {
      setState(() => _error = l10n.settings_locationBothRequired);
      return;
    }
    final lat = double.tryParse(latText);
    final lon = double.tryParse(lonText);
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) {
      setState(() => _error = l10n.settings_locationInvalid);
      return;
    }
    Navigator.pop(context, (lat, lon));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final provider = widget.phoneLocation;
    const keyboard = TextInputType.numberWithOptions(
      decimal: true,
      signed: true,
    );
    return AlertDialog(
      title: Text(l10n.sos_storedLocation),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _latController,
              keyboardType: keyboard,
              decoration: InputDecoration(labelText: l10n.settings_latitude),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lonController,
              keyboardType: keyboard,
              decoration: InputDecoration(
                labelText: l10n.settings_longitude,
                errorText: _error,
              ),
            ),
            if (provider != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _locating
                        ? null
                        : () => _useCurrentGps(provider),
                    icon: _locating
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location),
                    label: Text(l10n.sos_useCurrentGps),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              l10n.sos_storedLocationHelper,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(onPressed: _save, child: Text(l10n.common_save)),
      ],
    );
  }
}

class _SosContactsSheet extends StatelessWidget {
  const _SosContactsSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final settingsService = context.watch<AppSettingsService>();
    final selected = settingsService.settings.sosContactKeys;
    final contacts =
        context
            .watch<MeshCoreConnector>()
            .contacts
            .where((c) => c.type == advTypeChat)
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.sos_contacts,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (contacts.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.sos_contactsEmpty),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final contact in contacts)
                      CheckboxListTile(
                        value: selected.contains(contact.publicKeyHex),
                        title: Text(contact.name),
                        secondary: contact.isFavorite
                            ? const Icon(Icons.star, size: 20)
                            : null,
                        onChanged: (value) => settingsService.setSosContact(
                          contact.publicKeyHex,
                          value ?? false,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
