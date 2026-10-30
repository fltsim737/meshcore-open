import 'package:flutter/material.dart';

import '../utils/platform_info.dart';

/// On a computer (Linux, Windows, macOS) the app shows as one phone-width
/// column in the middle of the window, as it looks on Android, however wide
/// the window is (9.8.5); a window narrower than that is filled as before. A
/// screen that's better wide (the map) asks for the whole window while it's
/// open. The widget tree stays the same either way, so changing between the
/// two never rebuilds the screens underneath.
class DesktopPhoneFrame extends StatelessWidget {
  const DesktopPhoneFrame({super.key, required this.child});

  final Widget child;

  /// As the radio's web page: its column is 680 px too.
  static const double columnWidth = 680;

  static final ValueNotifier<int> _wideScreens = ValueNotifier<int>(0);

  /// A screen that wants the whole window (the map) opened, or closed.
  static void wideScreenOpened() => _wideScreens.value++;
  static void wideScreenClosed() {
    if (_wideScreens.value > 0) _wideScreens.value--;
  }

  @override
  Widget build(BuildContext context) {
    if (!PlatformInfo.isDesktop) return child;
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: _wideScreens,
      builder: (context, wide, _) => LayoutBuilder(
        builder: (context, constraints) {
          final framed = wide == 0 && constraints.maxWidth > columnWidth + 80;
          return ColoredBox(
            color: framed ? scheme.surfaceContainerHighest : Colors.transparent,
            child: Align(
              alignment: Alignment.topCenter,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: framed
                      ? Border.symmetric(
                          vertical: BorderSide(color: scheme.outlineVariant),
                        )
                      : null,
                ),
                child: SizedBox(
                  width: framed ? columnWidth : double.infinity,
                  height: double.infinity,
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
