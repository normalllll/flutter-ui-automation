import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart'
    show LiveWidgetController, simulateKeyDownEvent, simulateKeyUpEvent;

import 'automation_binding.dart';
import 'driver_binding.dart';

const native = MethodChannel('capture_lab/native');

class CaptureLab extends StatefulWidget {
  const CaptureLab({super.key});
  @override
  State<CaptureLab> createState() => CaptureLabState();
}

class CaptureLabState extends State<CaptureLab>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _captureKey = GlobalKey();
  final _probeKey = GlobalKey();
  final _animationKey = GlobalKey();
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final AnimationController _animation;
  int _probe = 0;
  // The marker is instrumentation: shown only while a native capture may be
  // waiting for it, so ordinary UI is not covered between captures.
  DateTime? _probeVisibleUntil;
  Timer? _probeHide;
  int _animationFrames = 0;
  int _dialogConfirmed = 0;
  String _dialogResult = 'none';
  bool _dialogOpen = false;
  final _text = TextEditingController();
  final _focus = FocusNode(debugLabel: 'lab-text-input');
  Timer? _timer;
  bool _polling = false;
  Map<String, Object?> _os = {};
  int _page = 0;
  int _clicks = 0;
  int _ticks = 0;
  int _gatedTicks = 0;
  int _shortcutCount = 0;
  double _scroll = 0;
  bool _motion = true;
  ui.ViewFocusState _viewFocus = ui.ViewFocusState.unfocused;
  String? _error;

  final List<String> _lifecycleEvents = [];

  DriverBinding? get _automation => switch (WidgetsBinding.instance) {
    DriverBinding binding => binding,
    _ => null,
  };
  bool get _resumed =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    _animation = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..addListener(() => _animationFrames++);
    WidgetsBinding.instance.addObserver(this);
    _automation?.changes.addListener(_bindingChanged);
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      setState(() {
        _ticks++;
        if (_resumed && _motion) _gatedTicks++;
      });
      if (_ticks % 5 == 0) unawaited(_pollNative());
    });
    unawaited(_pollNative());
  }

  void _bindingChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    if (mounted) setState(() => _viewFocus = event.state);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleEvents.add(state.name);
    if (_lifecycleEvents.length > 64) _lifecycleEvents.removeAt(0);
  }

  Future<void> _pollNative() async {
    if (_polling) return;
    _polling = true;
    try {
      final data = await native.invokeMapMethod<String, Object?>('status');
      if (!mounted) return;
      if (data != null) {
        _automation?.initializePlatformState(
          visible: data['visible'] == true,
          isForeground: data['isForeground'] == true,
        );
      }
      if (mounted) setState(() => _os = data ?? {});
    } on PlatformException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on MissingPluginException {
      // Widget tests can render without a Windows runner.
    } finally {
      _polling = false;
    }
  }

  Future<Map<String, Object?>> snapshot() async {
    await _pollNative();
    if (!mounted) throw StateError('Application disposed during snapshot');
    return {
      'page': ['overview', 'gallery', 'interaction', 'scenarios'][_page],
      'capabilities': {
        'appScreenshot': _automation != null,
        'presentationProbe': _automation != null,
        'foregroundSimulation': _automation is AutomationBinding,
        'nativeUiAutomation': false,
        'orientation': _os['platform'] == 'android',
      },
      'lifecycleEvents': List<String>.of(_lifecycleEvents),
      'view': {
        'width':
            View.of(context).physicalSize.width /
            View.of(context).devicePixelRatio,
        'height':
            View.of(context).physicalSize.height /
            View.of(context).devicePixelRatio,
        'pixelRatio': View.of(context).devicePixelRatio,
        'keyboardInset':
            View.of(context).viewInsets.bottom /
            View.of(context).devicePixelRatio,
      },
      'clicks': _clicks,
      'text': _text.text,
      'textHasFocus': _focus.hasFocus,
      'shortcutCount': _shortcutCount,
      'dialogOpen': _dialogOpen,
      'dialogResult': _dialogResult,
      'dialogConfirmed': _dialogConfirmed,
      'animationRunning': _animation.isAnimating,
      'animationValue': _animation.value,
      'animationFrames': _animationFrames,
      'animationRect': _rect(_animationKey),
      'scrollOffset': _scroll,
      'ticks': _ticks,
      'foregroundTicks': _gatedTicks,
      'pretendForeground': _automation?.pretendForeground ?? false,
      'frameworkFocusAllowed': FocusManager.instance.rootScope.canRequestFocus,
      'rawLifecycle': _automation?.rawLifecycle?.name,
      'effectiveLifecycle': WidgetsBinding.instance.lifecycleState?.name,
      'effectiveViewFocus': _viewFocus.name,
      'native': _os,
      'error': _error,
    };
  }

  /// Pump frames until no transient (ticker) callbacks remain, within [timeout].
  ///
  /// Driver runs unsynchronized because the app has continuous timers, so a
  /// tap returns after one frame. Route transitions, ink ripples and scroll
  /// ballistics would otherwise be captured midway. Forced frames also advance
  /// them while ordinary frames are disabled by a hidden lifecycle.
  Future<Map<String, Object?>> _settle(Duration timeout) async {
    final binding = WidgetsBinding.instance;
    final clock = Stopwatch()..start();
    var frames = 0;
    do {
      binding.scheduleForcedFrame();
      await binding.endOfFrame.timeout(const Duration(seconds: 3));
      frames++;
    } while (binding.transientCallbackCount > 0 && clock.elapsed < timeout);
    return {
      'settled': binding.transientCallbackCount == 0,
      'settleFrames': frames,
      'settleMs': clock.elapsedMilliseconds,
      'pendingTransientCallbacks': binding.transientCallbackCount,
    };
  }

  Duration _timeout(Map<String, Object?> request) =>
      Duration(milliseconds: (request['settleMs'] as num?)?.toInt() ?? 3000);

  Future<String> handleRequest(String? message) async {
    final request = jsonDecode(message ?? '{}') as Map<String, Object?>;
    switch (request['command']) {
      case 'settle':
        return jsonEncode(await _settle(_timeout(request)));
      case 'refresh':
        WidgetsBinding.instance.scheduleForcedFrame();
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 3),
        );
        return jsonEncode({'refreshed': true});
      case 'state':
        return jsonEncode(await snapshot());
      case 'unfocus':
        FocusManager.instance.primaryFocus?.unfocus();
        return jsonEncode(await snapshot());
      case 'orientation':
        if (_os['platform'] != 'android' || _automation == null) {
          throw UnsupportedError(
            'Orientation hook requires the Android test entrypoint',
          );
        }
        await native.invokeMethod<void>('orientation', request['value']);
        return jsonEncode({'requestedOrientation': request['value']});
      case 'prepareCapture':
        // A per-request visible marker is a presentation fence, not a delay.
        // It lets the external HWND backend reject blank and stale frames.
        final settle = request['settle'] == false
            ? null
            : await _settle(_timeout(request));
        final hold = Duration(
          milliseconds: (request['holdMs'] as num?)?.toInt() ?? 12000,
        );
        final until = DateTime.now().add(hold);
        // A concurrent screenshot must not shorten a running recording's hold.
        final visibleUntil =
            _probeVisibleUntil != null && _probeVisibleUntil!.isAfter(until)
            ? _probeVisibleUntil!
            : until;
        setState(() {
          _probe = (_probe + 1) & 0xffffff;
          _probeVisibleUntil = visibleUntil;
        });
        _probeHide?.cancel();
        _probeHide = Timer(visibleUntil.difference(DateTime.now()), () {
          if (mounted) setState(() => _probeVisibleUntil = null);
        });
        WidgetsBinding.instance.scheduleForcedFrame();
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 3),
        );
        return jsonEncode({
          ...?settle,
          'token': _probe,
          'visibleUntilMs': visibleUntil.millisecondsSinceEpoch,
          'rect': _rect(_probeKey),
          'pixelRatio':
              ui.PlatformDispatcher.instance.views.first.devicePixelRatio,
          'native': (await snapshot())['native'],
        });
      case 'appScreenshot':
        // Hidden lifecycle disables normal frames. Force a capture frame
        // without changing the reported lifecycle or the actual OS focus.
        // Recordings pass settle=false: they must sample motion, not wait it out.
        final settle = request['settle'] == true
            ? await _settle(_timeout(request))
            : null;
        WidgetsBinding.instance.scheduleForcedFrame();
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 3),
        );
        if (!mounted) throw StateError('App disposed during capture');
        final boundary =
            _captureKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        final ratio =
            ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
        final view = View.of(context);
        final bottomInset = view.viewInsets.bottom > view.viewPadding.bottom
            ? view.viewInsets.bottom
            : view.viewPadding.bottom;
        final image = await boundary.toImage(pixelRatio: ratio);
        try {
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          return jsonEncode({
            ...?settle,
            'png': base64Encode(bytes!.buffer.asUint8List()),
            'width': image.width,
            'height': image.height,
            'pixelRatio': ratio,
            'contentRect': {
              'x': view.viewPadding.left.round(),
              'y': view.viewPadding.top.round(),
              'width':
                  (image.width - view.viewPadding.left - view.viewPadding.right)
                      .round(),
              'height': (image.height - view.viewPadding.top - bottomInset)
                  .round(),
            },
          });
        } finally {
          image.dispose();
        }
      case 'pretendForeground':
        final enabled = request['enabled'];
        if (enabled is! bool) throw ArgumentError('enabled must be a boolean');
        _automation!.setPretendForeground(enabled);
        return jsonEncode(await snapshot());
      case 'key':
        if (request['key'] != 'F6') throw ArgumentError('Supported key: F6');
        // Framework events only: this never sends global keyboard input.
        await simulateKeyDownEvent(LogicalKeyboardKey.f6);
        await simulateKeyUpEvent(LogicalKeyboardKey.f6);
        return jsonEncode(await snapshot());
      case 'tapAt':
        final x = (request['x'] as num).toDouble();
        final y = (request['y'] as num).toDouble();
        final view = ui.PlatformDispatcher.instance.views.first;
        final size = view.physicalSize / view.devicePixelRatio;
        if (!x.isFinite ||
            !y.isFinite ||
            x < 0 ||
            y < 0 ||
            x >= size.width ||
            y >= size.height) {
          throw ArgumentError('Pointer must stay inside this Flutter view');
        }
        await LiveWidgetController(WidgetsBinding.instance).tapAt(Offset(x, y));
        return jsonEncode(await snapshot());
      default:
        throw ArgumentError('Unknown command: ${request['command']}');
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _probeHide?.cancel();
    _animation.dispose();
    _automation?.changes.removeListener(_bindingChanged);
    WidgetsBinding.instance.removeObserver(this);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: _navigatorKey,
    // The app-capture boundary wraps the Navigator (dialogs, menus, overlays)
    // but not the marker, so app PNGs contain only real UI pixels. The marker
    // still paints above every route for the native window capture.
    builder: (context, child) => Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(key: _captureKey, child: child!),
        ),
        if (_automation != null && _probeVisibleUntil != null)
          Positioned(
            right: 8,
            bottom:
                8 +
                MediaQuery.of(context).viewPadding.bottom +
                MediaQuery.of(context).viewInsets.bottom,
            child: IgnorePointer(
              child: SizedBox(
                key: _probeKey,
                width: 128,
                height: 8,
                child: Row(
                  children: List.generate(32, (index) {
                    final word = (0xa << 28) | (_probe << 4) | 0x5;
                    return Expanded(
                      child: ColoredBox(
                        color: (word >> (31 - index)) & 1 == 1
                            ? const Color(0xfff0b429)
                            : const Color(0xff16324f),
                        child: const SizedBox.expand(),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
      ],
    ),
    debugShowCheckedModeBanner: false,
    title: 'Flutter Capture Lab',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff2563eb)),
      scaffoldBackgroundColor: const Color(0xfff5f7fb),
      fontFamily: 'Segoe UI',
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
    ),
    home: LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth < 760 || constraints.maxHeight < 500
          ? _mobile(context)
          : _desktop(),
    ),
  );

  Widget _desktop() => Scaffold(
    body: Row(
      children: [
        NavigationRail(
          extended: true,
          minExtendedWidth: 190,
          backgroundColor: Colors.white,
          leading: const Padding(
            padding: EdgeInsets.fromLTRB(16, 24, 16, 32),
            child: Row(
              children: [
                Icon(Icons.science_outlined),
                SizedBox(width: 12),
                Text(
                  'CAPTURE LAB',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
              ],
            ),
          ),
          selectedIndex: _page,
          onDestinationSelected: (value) => setState(() => _page = value),
          destinations: const [
            NavigationRailDestination(
              icon: Icon(
                Icons.dashboard_outlined,
                key: ValueKey('nav-overview'),
              ),
              label: Text('Overview'),
            ),
            NavigationRailDestination(
              icon: Icon(Icons.grid_view, key: ValueKey('nav-gallery')),
              label: Text('Gallery'),
            ),
            NavigationRailDestination(
              icon: Icon(
                Icons.touch_app_outlined,
                key: ValueKey('nav-interaction'),
              ),
              label: Text('Interaction'),
            ),
            NavigationRailDestination(
              icon: Icon(
                Icons.play_circle_outline,
                key: ValueKey('nav-scenarios'),
              ),
              label: Text('Dialogs & motion'),
            ),
          ],
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    'Automation overview',
                    'Capture gallery',
                    'Interaction bench',
                    'Dialogs and animation',
                  ][_page],
                  key: const ValueKey('page-title'),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Visible window. Internal input. Independent capture.',
                  style: TextStyle(color: Color(0xff475569)),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Chip(
                      label: Text(
                        'Windows foreground: ${_os['isForeground'] ?? '?'}',
                      ),
                    ),
                    Chip(
                      label: Text(
                        'Flutter: ${WidgetsBinding.instance.lifecycleState?.name ?? 'unknown'}',
                      ),
                    ),
                    Chip(label: Text('View focus: ${_viewFocus.name}')),
                    Chip(label: Text('Heartbeat: $_ticks')),
                  ],
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: switch (_page) {
                    0 => _overview(),
                    1 => _gallery(),
                    2 => _interactions(),
                    _ => _scenarios(),
                  },
                ),
                if (_error case final error?)
                  Text(error, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _mobile(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        [
          'Automation overview',
          'Capture gallery',
          'Interaction bench',
          'Dialogs and animation',
        ][_page],
        key: const ValueKey('page-title'),
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
    ),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: switch (_page) {
          0 => _overview(),
          1 => _gallery(),
          2 => _interactions(),
          _ => _scenarios(),
        },
      ),
    ),
    bottomNavigationBar: MediaQuery.of(context).viewInsets.bottom > 0
        ? null
        : NavigationBar(
            selectedIndex: _page,
            onDestinationSelected: (value) => setState(() => _page = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(
                  Icons.dashboard_outlined,
                  key: ValueKey('nav-overview'),
                ),
                label: 'Overview',
              ),
              NavigationDestination(
                icon: Icon(Icons.grid_view, key: ValueKey('nav-gallery')),
                label: 'Gallery',
              ),
              NavigationDestination(
                icon: Icon(
                  Icons.touch_app_outlined,
                  key: ValueKey('nav-interaction'),
                ),
                label: 'Input',
              ),
              NavigationDestination(
                icon: Icon(
                  Icons.play_circle_outline,
                  key: ValueKey('nav-scenarios'),
                ),
                label: 'Scenarios',
              ),
            ],
          ),
  );

  Map<String, double>? _rect(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    final offset = box.localToGlobal(Offset.zero);
    return {
      'x': offset.dx,
      'y': offset.dy,
      'width': box.size.width,
      'height': box.size.height,
    };
  }

  Future<void> _showConfirmation() async {
    setState(() => _dialogOpen = true);
    final confirmed = await showDialog<bool>(
      context: _navigatorKey.currentContext!,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        key: const ValueKey('confirmation-dialog'),
        title: const Text('Confirm sample action'),
        content: const Text(
          'This Flutter dialog is controlled through internal pointer events.',
        ),
        actions: [
          TextButton(
            key: const ValueKey('dialog-cancel'),
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('dialog-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() {
      _dialogOpen = false;
      _dialogResult = confirmed == true ? 'confirmed' : 'cancelled';
      if (confirmed == true) _dialogConfirmed++;
    });
  }

  Widget _panel(String title, Widget child) => Card(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );

  Widget _overview() => ListView(
    children: [
      _panel(
        _os['platform'] == 'android'
            ? 'Real device lifecycle'
            : 'Foreground simulation',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const ValueKey('foreground-switch'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Treat this app as foreground'),
              subtitle: const Text(
                'Windows test entrypoint only. Mobile lifecycle remains real.',
              ),
              value: _automation?.pretendForeground ?? false,
              onChanged: _automation is! AutomationBinding
                  ? null
                  : (value) => _automation!.setPretendForeground(value),
            ),
            const Divider(),
            Text(
              'Platform lifecycle: ${_automation?.rawLifecycle?.name ?? 'normal entrypoint'}',
            ),
            const SizedBox(height: 8),
            const Text(
              'Covers framework lifecycle observers and view-focus notifications.\n'
              'Does not simulate IME, OS hotkeys, foreground HWND checks, or native activation.',
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _panel(
        'Foreground-only activity',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$_gatedTicks updates',
              key: const ValueKey('foreground-ticks'),
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: (_gatedTicks % 50) / 50),
            const SizedBox(height: 12),
            const Text(
              'This activity advances only while Flutter reports resumed.',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Animate capture marker'),
              value: _motion,
              onChanged: (value) => setState(() => _motion = value),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _panel(
        'Capture channels',
        const Text(
          'App PNG: Flutter RepaintBoundary\n'
          'System capture: Windows WGC / Android ADB\n'
          'Automation: Flutter Driver over the local VM service',
        ),
      ),
    ],
  );

  Widget _gallery() => NotificationListener<ScrollNotification>(
    onNotification: (event) {
      _scroll = event.metrics.pixels;
      return false;
    },
    child: GridView.builder(
      key: const ValueKey('gallery-scroll'),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisExtent: 190,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: 24,
      itemBuilder: (context, index) => Card(
        color: Colors.primaries[index % Colors.primaries.length].shade100,
        child: InkWell(
          key: ValueKey('tile-$index'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _clicks++),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  [
                    Icons.landscape_outlined,
                    Icons.auto_awesome_outlined,
                    Icons.palette_outlined,
                  ][index % 3],
                  size: 36,
                ),
                const Spacer(),
                Text(
                  'Sample ${index + 1}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text('Stable key: tile-$index'),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _scenarios() => ListView(
    children: [
      _panel(
        'Modal interaction and real animation',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: const ValueKey('open-dialog'),
                  onPressed: _showConfirmation,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open confirmation dialog'),
                ),
                Text(
                  'Result: $_dialogResult · confirmed $_dialogConfirmed',
                  key: const ValueKey('dialog-result'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            // A dedicated region excludes the heartbeat/status labels from pixel
            // motion checks, so changing text cannot masquerade as animation.
            SizedBox(
              key: _animationKey,
              height: 140,
              width: double.infinity,
              child: ColoredBox(
                color: const Color(0xff14243b),
                child: AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) => Align(
                    alignment: Alignment(-0.85 + _animation.value * 1.7, 0),
                    child: Transform.rotate(
                      angle: _animation.value * 6.283185,
                      child: Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: const Color(0xfff0b429),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: const Icon(
                          Icons.play_arrow,
                          size: 40,
                          color: Color(0xff14243b),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                FilledButton(
                  key: const ValueKey('animation-play'),
                  onPressed: () {
                    _animation.repeat(reverse: true);
                    setState(() {});
                  },
                  child: const Text('Play animation'),
                ),
                OutlinedButton(
                  key: const ValueKey('animation-pause'),
                  onPressed: () {
                    _animation.stop();
                    setState(() {});
                  },
                  child: const Text('Pause'),
                ),
                TextButton(
                  key: const ValueKey('animation-reset'),
                  onPressed: () {
                    _animation.reset();
                    setState(() {});
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'AnimationController · 2 seconds each way · pixel verification uses only the dark stage.',
            ),
          ],
        ),
      ),
    ],
  );

  Widget _interactions() => ListView(
    children: [
      _panel(
        'Text and pointer input',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('input-field'),
              controller: _text,
              focusNode: _focus,
              decoration: const InputDecoration(
                labelText: 'Automation text',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const ValueKey('increment-button'),
              onPressed: () => setState(() => _clicks++),
              icon: const Icon(Icons.add),
              label: const Text('Increment counter'),
            ),
            const SizedBox(height: 16),
            Text(
              '$_clicks clicks',
              key: const ValueKey('click-count'),
              style: const TextStyle(fontSize: 24),
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _panel(
        'Framework keyboard event',
        Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.f6) {
              setState(() => _shortcutCount++);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (context) => OutlinedButton(
              key: const ValueKey('focus-key-button'),
              onPressed: () => Focus.of(context).requestFocus(),
              child: Text('Focus keyboard target · F6 count $_shortcutCount'),
            ),
          ),
        ),
      ),
    ],
  );
}
