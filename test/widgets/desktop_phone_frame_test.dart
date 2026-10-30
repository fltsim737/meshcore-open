import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/widgets/desktop_phone_frame.dart';

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => n++),
    child: SizedBox.expand(key: const Key('screen'), child: Text('$n')),
  );
}

void main() {
  Future<void> pump(WidgetTester tester, Size window) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(home: DesktopPhoneFrame(child: _Counter())),
    );
  }

  // the tests run on a computer (Linux), as the desktop apps do
  testWidgets('a wide window shows the app as a phone-width column', (
    tester,
  ) async {
    await pump(tester, const Size(1600, 900));
    expect(
      tester.getSize(find.byKey(const Key('screen'))).width,
      DesktopPhoneFrame.columnWidth,
    );
    expect(
      tester.getCenter(find.byKey(const Key('screen'))).dx,
      800,
    ); // in the middle
  });

  testWidgets('a narrow window is filled, as before', (tester) async {
    await pump(tester, const Size(720, 900));
    expect(tester.getSize(find.byKey(const Key('screen'))).width, 720);
  });

  testWidgets(
    'the map takes the whole window, and nothing underneath is rebuilt',
    (tester) async {
      await pump(tester, const Size(1600, 900));
      await tester.tap(find.byKey(const Key('screen')));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      DesktopPhoneFrame.wideScreenOpened();
      await tester.pump();
      expect(tester.getSize(find.byKey(const Key('screen'))).width, 1600);
      expect(find.text('1'), findsOneWidget); // its state kept
      DesktopPhoneFrame.wideScreenClosed();
      await tester.pump();
      expect(
        tester.getSize(find.byKey(const Key('screen'))).width,
        DesktopPhoneFrame.columnWidth,
      );
      expect(find.text('1'), findsOneWidget);
    },
  );
}
