import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_capture_lab/src/lab_app.dart';

void main() {
  for (final size in [
    const Size(360, 800),
    const Size(800, 360),
    const Size(320, 568),
  ]) {
    testWidgets('mobile navigation, dialogs and keyboard layout at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(const CaptureLab());
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('nav-interaction')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('input-field')),
        'Mobile / 输入',
      );
      tester.view.viewInsets = FakeViewPadding(
        bottom: size.height > 500 ? 300 : 160,
      );
      await tester.pump();
      expect(find.byType(NavigationBar), findsNothing);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nav-scenarios')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('open-dialog')));
      await tester.tap(find.byKey(const ValueKey('open-dialog')));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('confirmation-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('dialog-confirm')));
      await tester.pump(const Duration(milliseconds: 350));
      final state = tester.state<CaptureLabState>(find.byType(CaptureLab));
      expect((await state.snapshot())['dialogConfirmed'], 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('navigation and controls work without native plugins', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const CaptureLab());
    expect(find.text('Automation overview'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-gallery')));
    await tester.pump();
    expect(find.text('Capture gallery'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tile-0')));
    await tester.tap(find.byKey(const ValueKey('nav-interaction')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('input-field')),
      'widget input',
    );
    await tester.tap(find.byKey(const ValueKey('increment-button')));
    await tester.pump();
    expect(find.text('2 clicks'), findsOneWidget);
    expect(find.text('widget input'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('modal route blocks the page and animation can pause and reset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const CaptureLab());
    await tester.tap(find.byKey(const ValueKey('nav-scenarios')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('open-dialog')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('confirmation-dialog')), findsOneWidget);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('nav-gallery'))),
    );
    await tester.pump();
    expect(find.text('Dialogs and animation'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dialog-confirm')));
    await tester.pump(const Duration(milliseconds: 300));
    final state = tester.state<CaptureLabState>(find.byType(CaptureLab));
    expect((await state.snapshot())['dialogConfirmed'], 1);
    expect(find.byKey(const ValueKey('confirmation-dialog')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('animation-play')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final moving = await state.snapshot();
    expect(moving['animationRunning'], true);
    expect(moving['animationValue'] as double, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('animation-pause')));
    await tester.pump();
    final paused = await state.snapshot();
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      (await state.snapshot())['animationFrames'],
      paused['animationFrames'],
    );
    await tester.tap(find.byKey(const ValueKey('animation-reset')));
    await tester.pump();
    expect((await state.snapshot())['animationValue'], 0);
    await tester.pumpWidget(const SizedBox());
  });
}
