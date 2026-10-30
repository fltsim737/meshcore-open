import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/l10n.dart';
import '../services/app_settings_service.dart';
import '../services/background_service.dart';
import '../services/login_autostart.dart';
import '../services/sos_service.dart';
import '../storage/prefs_manager.dart';
import '../utils/platform_info.dart';
import '../widgets/sos_dnd_access_tile.dart';
import '../widgets/sos_screen_access_tile.dart';
import '../widgets/sos_settings_section.dart';
import '../widgets/sound_devices_tiles.dart';
import 'app_settings_screen.dart';
import 'sos_network_screen.dart';

/// The first-time setup: what the app is, how alerts reach this device, the
/// emergency network, the emergency location, then connecting a radio.
/// Shown once on a new install; it can be run again from the settings.
class SetupWizardScreen extends StatefulWidget {
  const SetupWizardScreen({super.key});

  static const String _doneKey = 'setup_wizard_done';

  /// Opens the wizard over [context] the first time the app starts. An app
  /// already set up (it has an emergency network or location) skips it.
  static Future<void> showIfFirstRun(BuildContext context) async {
    final bool setUp;
    try {
      final prefs = PrefsManager.instance;
      if (prefs.getBool(_doneKey) ?? false) return;
      final settings = context.read<AppSettingsService>().settings;
      setUp =
          context.read<SosService>().network != null ||
          settings.sosLatitude != null;
      await prefs.setBool(_doneKey, true);
    } catch (_) {
      return; // no settings store or services (as in tests): never mind
    }
    if (setUp || !context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const SetupWizardScreen(),
      ),
    );
  }

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

enum _Start { coordinator, join }

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  final _pages = PageController();
  int _page = 0;
  _Start _start = _Start.join;

  static const _pageCount = 5;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int page) {
    setState(() => _page = page);
    _pages.animateToPage(
      page,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final last = _page == _pageCount - 1;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.wizard_title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.wizard_skip),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(value: (_page + 1) / _pageCount),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l10n.wizard_step(_page + 1, _pageCount),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _welcome(context),
                  _alerts(context),
                  _network(context),
                  _location(context),
                  _radio(context),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  if (_page > 0)
                    TextButton(
                      onPressed: () => _go(_page - 1),
                      child: Text(l10n.wizard_back),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: last
                        ? () => Navigator.pop(context)
                        : () => _go(_page + 1),
                    child: Text(last ? l10n.wizard_finish : l10n.wizard_next),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _step(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
    List<Widget> children = const [],
  }) {
    final textTheme = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      children: [
        Icon(icon, size: 48, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 12),
        Text(
          title,
          style: textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(body, style: textTheme.bodyLarge, textAlign: TextAlign.center),
        const SizedBox(height: 16),
        ...children,
      ],
    );
  }

  Widget _welcome(BuildContext context) {
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    Widget choice(_Start value, IconData icon, String title, String detail) =>
        Card(
          child: ListTile(
            leading: Icon(icon),
            title: Text(title),
            subtitle: Text(detail),
            trailing: Icon(
              _start == value
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            onTap: () => setState(() => _start = value),
          ),
        );
    return _step(
      context,
      icon: Icons.sos,
      title: l10n.wizard_welcomeTitle(l10n.appTitle),
      body: l10n.wizard_welcomeBody,
      children: [
        Card(
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              l10n.wizard_bestEffort,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.wizard_roleQuestion,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        choice(
          _Start.coordinator,
          Icons.group_add_outlined,
          l10n.wizard_roleCoordinator,
          l10n.wizard_roleCoordinatorDetail,
        ),
        choice(
          _Start.join,
          Icons.qr_code_scanner,
          l10n.wizard_roleJoin,
          l10n.wizard_roleJoinDetail,
        ),
      ],
    );
  }

  Widget _alerts(BuildContext context) {
    final l10n = context.l10n;
    final settingsService = context.watch<AppSettingsService>();
    return _step(
      context,
      icon: Icons.notifications_active_outlined,
      title: l10n.wizard_alertsTitle,
      body: l10n.wizard_alertsBody,
      children: [
        Card(
          child: Column(
            children: [
              if (PlatformInfo.isAndroid) ...[
                const SosScreenAccessTile(),
                const SosDndAccessTile(),
                ListTile(
                  leading: const Icon(Icons.battery_saver_outlined),
                  title: Text(l10n.appSettings_batteryOptimization),
                  subtitle: Text(l10n.appSettings_batteryOptimizationSubtitle),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: BackgroundService.openBatteryOptimizationSettings,
                ),
              ],
              if (LoginAutostart.forPlatform() != null)
                const StartOnLoginTile(),
              ListTile(
                leading: const Icon(Icons.notifications_active_outlined),
                title: Text(l10n.sos_alarmSound),
                subtitle: Text(
                  settingsService.sosAlarmTone ==
                          AppSettingsService.alarmToneClassic
                      ? l10n.sos_alarmSoundClassic
                      : l10n.sos_alarmSoundMorse,
                ),
                onTap: () => chooseSosAlarmSound(context, settingsService),
              ),
              const SoundDevicesTiles(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _network(BuildContext context) {
    final l10n = context.l10n;
    final sos = context.watch<SosService>();
    final network = sos.network;
    return _step(
      context,
      icon: Icons.shield_outlined,
      title: l10n.wizard_networkTitle,
      body: _start == _Start.coordinator
          ? l10n.wizard_networkBodyCoordinator
          : l10n.wizard_networkBodyJoin,
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(
              network == null
                  ? l10n.wizard_networkNone
                  : l10n.sos_networkSummary(
                      network.name,
                      sosRoleLabel(l10n, network.role),
                    ),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SosNetworkScreen()),
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.shield_outlined),
          label: Text(l10n.wizard_networkOpen),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SosNetworkScreen()),
          ),
        ),
      ],
    );
  }

  Widget _location(BuildContext context) {
    final l10n = context.l10n;
    final settingsService = context.watch<AppSettingsService>();
    final lat = settingsService.settings.sosLatitude;
    final lon = settingsService.settings.sosLongitude;
    return _step(
      context,
      icon: Icons.home_work_outlined,
      title: l10n.wizard_locationTitle,
      body: l10n.wizard_locationBody,
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.home_work_outlined),
            title: Text(l10n.sos_storedLocation),
            subtitle: Text(
              lat != null && lon != null
                  ? '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
                  : l10n.sos_storedLocationUnset,
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: () => _editLocation(context, settingsService),
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

  Widget _radio(BuildContext context) {
    final l10n = context.l10n;
    return _step(
      context,
      icon: Icons.settings_input_antenna,
      title: l10n.wizard_radioTitle,
      body: l10n.wizard_radioBody(
        '${l10n.settings_title} → ${l10n.appSettings_title} → '
        '${l10n.sos_settingsSection}',
      ),
    );
  }
}
