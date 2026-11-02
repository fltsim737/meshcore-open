import 'package:flutter/material.dart';

class ChatScrollController extends ScrollController {
  final ValueNotifier<bool> showJumpToBottom = ValueNotifier(false);
  VoidCallback? onScrollNearTop;

  static const _bottomThreshold = 100.0;
  static const _topThreshold = 50.0;

  ChatScrollController() {
    addListener(_handleScroll);
  }

  void _handleScroll() {
    if (!hasClients) return;
    final pos = position;

    // With reverse: true, position 0 is bottom, maxScrollExtent is top
    // Show jump button when scrolled away from bottom (position > threshold)
    final isAtBottom = pos.pixels <= _bottomThreshold;
    if (showJumpToBottom.value == isAtBottom) {
      showJumpToBottom.value = !isAtBottom;
    }

    // Pagination trigger when scrolled near top (maxScrollExtent)
    if (pos.pixels >= pos.maxScrollExtent - _topThreshold) {
      onScrollNearTop?.call();
    }
  }

  void jumpToBottom() {
    if (hasClients && position.maxScrollExtent > 0) {
      animateTo(
        0, // With reverse: true, position 0 is bottom
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void handleKeyboardOpen() {
    // Simple: just scroll to bottom when keyboard opens
    if (hasClients) {
      animateTo(
        0, // With reverse: true, position 0 is bottom
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  /// Jumps toward an off-screen message so that lazy ListView.builder builds
  /// items near it. Only visible + cacheExtent items have real heights, so we
  /// use proportion of maxScrollExtent (itself an estimate from built items'
  /// avg height). Call [onJumped] on the next frame to ensureVisible/scroll
  /// to the exact target.
  void jumpToEstimatedOffset({
    required int unreadCount,
    required int totalMessages,
    required VoidCallback onJumped,
  }) {
    if (!hasClients || totalMessages == 0) return;
    final maxExtent = position.maxScrollExtent;
    final jumpOffset = maxExtent * (unreadCount / totalMessages);
    if (jumpOffset > 100) {
      jumpTo(jumpOffset);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => onJumped());
  }

  /// Brings the widget under [key] into view (10.2.6, chat search). Message
  /// heights vary, so it first jumps to [fraction] of the list (0 the newest,
  /// 1 the oldest), then steps outwards a screen at a time until the widget
  /// is built, and centres it. False if it never appears.
  Future<bool> reveal(GlobalKey key, {required double fraction}) async {
    if (!hasClients) return false;
    Future<void> frame() => WidgetsBinding.instance.endOfFrame;
    if (key.currentContext == null) {
      final max = position.maxScrollExtent;
      jumpTo((max * fraction.clamp(0.0, 1.0)).clamp(0.0, max));
      await frame();
    }
    final step = position.viewportDimension * 0.8;
    final base = hasClients ? offset : 0.0;
    for (var i = 1; key.currentContext == null && i <= 80; i++) {
      if (!hasClients) return false;
      final reach = step * ((i + 1) ~/ 2);
      final target = base + (i.isOdd ? reach : -reach);
      if (target < -step && target > position.maxScrollExtent + step) break;
      jumpTo(target.clamp(0.0, position.maxScrollExtent));
      await frame();
    }
    final ctx = key.currentContext;
    if (ctx == null || !ctx.mounted) return false;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      alignment: 0.4,
    );
    return true;
  }

  void scrollToBottomIfAtBottom() {
    // Only scroll if jump button is NOT showing (i.e., already at bottom)
    if (!showJumpToBottom.value && hasClients && position.maxScrollExtent > 0) {
      animateTo(
        0, // With reverse: true, position 0 is bottom
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  void dispose() {
    showJumpToBottom.dispose();
    super.dispose();
  }
}
