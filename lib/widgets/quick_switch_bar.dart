import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/l10n.dart';
import '../services/sos_service.dart';
import '../theme/mesh_theme.dart';

class QuickSwitchBar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final int contactsUnreadCount;
  final int channelsUnreadCount;
  final bool highContrast;

  const QuickSwitchBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    this.contactsUnreadCount = 0,
    this.channelsUnreadCount = 0,
    this.highContrast = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium ?? const TextStyle();
    final background = highContrast ? MapPalette.panelDark : Colors.transparent;
    // The selected icon sits on the primary indicator pill, so it uses
    // onPrimary. The label sits below on the bar background, so it must use a
    // foreground color that contrasts with the surface (not onPrimary, which
    // is white-on-white in the light theme).
    final selectedIconColor = highContrast
        ? MapPalette.textPrimary
        : colorScheme.onPrimary;
    final selectedLabelColor = highContrast
        ? MapPalette.textPrimary
        : colorScheme.onSurface;
    final unselectedColor = highContrast
        ? MapPalette.textSecondary
        : colorScheme.onSurfaceVariant;
    final indicator = highContrast ? MapPalette.selected : colorScheme.primary;
    final sos = context.watch<SosService>();
    final openAlerts = sos.openIncoming.length;

    return SizedBox(
      width: double.infinity,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              border: Border.all(
                color: highContrast
                    ? MapPalette.border
                    : colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
            child: NavigationBarTheme(
              data: NavigationBarThemeData(
                backgroundColor: Colors.transparent,
                surfaceTintColor: Colors.transparent,
                shadowColor: Colors.transparent,
                indicatorColor: indicator,
                labelTextStyle: WidgetStateProperty.resolveWith((states) {
                  final isSelected = states.contains(WidgetState.selected);
                  return labelStyle.copyWith(
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? selectedLabelColor : unselectedColor,
                  );
                }),
                iconTheme: WidgetStateProperty.resolveWith((states) {
                  final isSelected = states.contains(WidgetState.selected);
                  return IconThemeData(
                    color: isSelected ? selectedIconColor : unselectedColor,
                  );
                }),
              ),
              child: NavigationBar(
                height: 60,
                selectedIndex: selectedIndex,
                onDestinationSelected: onDestinationSelected,
                destinations: [
                  NavigationDestination(
                    icon: _buildIconWithBadge(
                      context,
                      const Icon(Icons.people_outline),
                      contactsUnreadCount,
                    ),
                    selectedIcon: _buildIconWithBadge(
                      context,
                      const Icon(Icons.people),
                      contactsUnreadCount,
                    ),
                    label: context.l10n.nav_contacts,
                  ),
                  NavigationDestination(
                    icon: _buildIconWithBadge(
                      context,
                      const Icon(Icons.tag),
                      channelsUnreadCount,
                    ),
                    selectedIcon: _buildIconWithBadge(
                      context,
                      const Icon(Icons.tag),
                      channelsUnreadCount,
                    ),
                    label: context.l10n.nav_channels,
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.map_outlined),
                    selectedIcon: const Icon(Icons.map),
                    label: context.l10n.nav_map,
                  ),
                  NavigationDestination(
                    icon: _buildSosIcon(
                      Icon(Icons.sos, color: colorScheme.error),
                      openAlerts,
                      sos.isActive,
                    ),
                    selectedIcon: _buildSosIcon(
                      const Icon(Icons.sos),
                      openAlerts,
                      sos.isActive,
                    ),
                    label: context.l10n.nav_emergency,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Count of open incoming alerts, or a dot while this device's SOS is on.
  Widget _buildSosIcon(Icon icon, int openAlerts, bool active) {
    if (openAlerts > 0) return Badge(label: Text('$openAlerts'), child: icon);
    if (active) return Badge(child: icon);
    return icon;
  }

  Widget _buildIconWithBadge(BuildContext context, Icon icon, int count) {
    if (count <= 0) return icon;
    final label = count > 99 ? '99+' : '$count';
    return Badge(label: Text(label), child: icon);
  }
}
