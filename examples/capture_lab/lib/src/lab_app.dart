import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart'
    show LiveWidgetController, simulateKeyDownEvent, simulateKeyUpEvent;

import 'automation_binding.dart';
import 'driver_binding.dart';
import 'lab_style.dart';

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
  // The marker is instrumentation: shown only while a native capture holds
  // it, so ordinary UI is not covered between captures. Each prepareCapture
  // opens a hold that the controller releases when its capture ends; every
  // hold also expires on its own, so a lost controller cannot strand it.
  final _holds = <int, DateTime>{};
  int _holdSequence = 0;
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
        'orientation': ['android', 'ios'].contains(_os['platform']),
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
      'rawViewFocus':
          _automation?.rawViewFocus[View.of(context).viewId]?.state.name,
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

  void _scheduleProbeExpiry() {
    _probeHide?.cancel();
    if (_holds.isEmpty) return;
    final next = _holds.values.reduce((a, b) => a.isBefore(b) ? a : b);
    _probeHide = Timer(next.difference(DateTime.now()), () {
      if (!mounted) return;
      final now = DateTime.now();
      setState(() => _holds.removeWhere((_, until) => !until.isAfter(now)));
      _scheduleProbeExpiry();
    });
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
        if (!['android', 'ios'].contains(_os['platform']) ||
            _automation == null) {
          throw UnsupportedError(
            'Orientation hook requires a mobile test entrypoint',
          );
        }
        final restored = await native.invokeMapMethod<String, Object?>(
          'orientation',
          request['value'],
        );
        return jsonEncode({
          'requestedOrientation': request['value'],
          ...?restored,
        });
      case 'prepareCapture':
        // A per-request visible marker is a presentation fence, not a delay.
        // It lets the external HWND backend reject blank and stale frames.
        final settle = request['settle'] == false
            ? null
            : await _settle(_timeout(request));
        final hold = Duration(
          milliseconds: (request['holdMs'] as num?)?.toInt() ?? 12000,
        );
        final visibleUntil = DateTime.now().add(hold);
        // Holds are independent: a concurrent screenshot's release never
        // hides the probe a running recording still needs.
        final holdId = ++_holdSequence;
        setState(() {
          _probe = (_probe + 1) & 0xffffff;
          _holds[holdId] = visibleUntil;
        });
        _scheduleProbeExpiry();
        WidgetsBinding.instance.scheduleForcedFrame();
        await WidgetsBinding.instance.endOfFrame.timeout(
          const Duration(seconds: 3),
        );
        return jsonEncode({
          ...?settle,
          'token': _probe,
          'hold': holdId,
          'visibleUntilMs': visibleUntil.millisecondsSinceEpoch,
          'rect': _rect(_probeKey),
          'pixelRatio':
              ui.PlatformDispatcher.instance.views.first.devicePixelRatio,
          'native': (await snapshot())['native'],
        });
      case 'releaseCapture':
        final hold = request['hold'];
        if (hold is! int) throw ArgumentError('hold must be an integer');
        if (_holds.containsKey(hold)) setState(() => _holds.remove(hold));
        _scheduleProbeExpiry();
        return jsonEncode({
          'released': hold,
          'probeVisible': _holds.isNotEmpty,
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
          child: RepaintBoundary(
            key: _captureKey,
            child: LabBackdrop(child: child!),
          ),
        ),
        // Top-right: the page header leaves this corner empty on desktop and
        // mobile, so the probe does not cover navigation or page content.
        if (_automation != null && _holds.isNotEmpty)
          Positioned(
            right: 8 + MediaQuery.of(context).viewPadding.right,
            top: 8 + MediaQuery.of(context).viewPadding.top,
            child: IgnorePointer(
              child: LabProbe(bitsKey: _probeKey, token: _probe),
            ),
          ),
      ],
    ),
    debugShowCheckedModeBanner: false,
    title: 'Flutter Capture Lab',
    theme: Lab.theme(),
    home: LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth < 760 || constraints.maxHeight < 500
          ? _mobile(context)
          : _desktop(),
    ),
  );

  static const _titles = [
    'Automation overview',
    'Capture gallery',
    'Interaction bench',
    'Dialogs and animation',
  ];
  static const _subtitles = [
    'Visible window. Internal input. Independent capture.',
    'Stable keys, real scrolling and pixel-addressable tiles.',
    'Framework text, pointer and keyboard paths.',
    'Modal routes and a controlled animation stage.',
  ];
  static const _destinations = [
    (Icons.dashboard_outlined, 'Overview', 'Overview', 'nav-overview'),
    (Icons.grid_view_rounded, 'Gallery', 'Gallery', 'nav-gallery'),
    (Icons.touch_app_outlined, 'Interaction', 'Input', 'nav-interaction'),
    (
      Icons.play_circle_outline,
      'Dialogs & motion',
      'Scenarios',
      'nav-scenarios',
    ),
  ];

  // The Windows runner does not report a platform name; use the host's.
  String get _platformName =>
      '${_os['platform'] ?? defaultTargetPlatform.name}';

  // Keyed per page: the pages share a tree position, and without a key one
  // page's scroll position would be reused by the next.
  Widget _pageBody() => KeyedSubtree(
    key: ValueKey('page-$_page'),
    child: switch (_page) {
      0 => _overview(),
      1 => _gallery(),
      2 => _interactions(),
      _ => _scenarios(),
    },
  );

  List<LabReadout> _readouts({bool compact = false}) {
    final foreground = _os['isForeground'];
    final lifecycle = WidgetsBinding.instance.lifecycleState?.name ?? 'unknown';
    return [
      LabReadout(
        label: '$_platformName foreground',
        value: '${foreground ?? '?'}',
        led: foreground == true ? Lab.ok : Lab.off,
        compact: compact,
      ),
      LabReadout(
        label: 'Flutter',
        value: lifecycle,
        led: lifecycle == 'resumed' ? Lab.ok : Lab.clay,
        compact: compact,
      ),
      LabReadout(
        label: 'View focus',
        value: _viewFocus.name,
        led: _viewFocus == ui.ViewFocusState.focused ? Lab.sky : Lab.off,
        compact: compact,
      ),
      LabReadout(
        label: 'Heartbeat',
        value: '$_ticks',
        led: Lab.clay,
        compact: compact,
      ),
    ];
  }

  Widget _brandMark(double size) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * .3),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xfff0a07f), Lab.clay],
      ),
      boxShadow: const [BoxShadow(color: Color(0x66d97757), blurRadius: 18)],
    ),
    child: Icon(
      Icons.science_outlined,
      size: size * .55,
      color: const Color(0xff1b0d07),
    ),
  );

  Widget _navItem(int index) {
    final (icon, label, _, key) = _destinations[index];
    final selected = _page == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey(key),
          borderRadius: BorderRadius.circular(12),
          onTap: () => setState(() => _page = index),
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: selected ? Lab.clay.withValues(alpha: .14) : null,
              border: Border.all(
                color: selected
                    ? Lab.clay.withValues(alpha: .38)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 20, color: selected ? Lab.clay : Lab.muted),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: selected ? Lab.text : Lab.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sidebar() => Container(
    width: 240,
    decoration: const BoxDecoration(
      color: Color(0xb30a0e17),
      border: Border(right: BorderSide(color: Lab.line)),
    ),
    padding: const EdgeInsets.fromLTRB(16, 28, 16, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              _brandMark(40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'CAPTURE LAB',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.2,
                        color: Lab.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'flutter ui automation',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Lab.monoStyle(size: 11, color: Lab.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 36),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text('WORKSPACE', style: Lab.eyebrow()),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < _destinations.length; i++) _navItem(i),
        const Spacer(),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0x99141b29),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Lab.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('TARGET', style: Lab.eyebrow()),
              const SizedBox(height: 8),
              Row(
                children: [
                  const LabLed(Lab.ok, size: 7),
                  const SizedBox(width: 8),
                  Text(
                    _platformName,
                    style: Lab.monoStyle(size: 14, weight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'pid ${_os['pid'] ?? '-'}',
                style: Lab.monoStyle(size: 12, color: Lab.muted),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _desktop() => Scaffold(
    body: Row(
      children: [
        _sidebar(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(36, 30, 36, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CAPTURE LAB / ${_destinations[_page].$2.toUpperCase()}',
                  style: Lab.eyebrow(Lab.clay),
                ),
                const SizedBox(height: 8),
                Text(
                  _titles[_page],
                  key: const ValueKey('page-title'),
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.6,
                    color: Lab.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _subtitles[_page],
                  style: const TextStyle(fontSize: 15, color: Lab.muted),
                ),
                const SizedBox(height: 22),
                Wrap(spacing: 12, runSpacing: 12, children: _readouts()),
                const SizedBox(height: 24),
                Expanded(child: _pageBody()),
                if (_error case final error?)
                  Text(error, style: const TextStyle(color: Lab.clay)),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget _mobile(BuildContext context) {
    final typing = MediaQuery.of(context).viewInsets.bottom > 0;
    final readouts = _readouts(compact: true);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: Row(
                children: [
                  _brandMark(32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'CAPTURE LAB / $_platformName'.toUpperCase(),
                          style: Lab.eyebrow(Lab.clay),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _titles[_page],
                          key: const ValueKey('page-title'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            color: Lab.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // The keyboard leaves little height; keep the editor visible.
            if (!typing) ...[
              SizedBox(
                height: 62,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: readouts.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, index) => readouts[index],
                ),
              ),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
                child: _pageBody(),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: typing
          ? null
          : NavigationBar(
              selectedIndex: _page,
              onDestinationSelected: (value) => setState(() => _page = value),
              destinations: [
                for (final (icon, _, label, key) in _destinations)
                  NavigationDestination(
                    icon: Icon(icon, key: ValueKey(key)),
                    label: label,
                  ),
              ],
            ),
    );
  }

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
        icon: const Icon(Icons.verified_outlined, color: Lab.clay, size: 30),
        title: const Text(
          'Confirm sample action',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: Lab.text,
          ),
        ),
        content: const Text(
          'This Flutter dialog is controlled through internal pointer events.',
          style: TextStyle(fontSize: 14.5, color: Lab.muted),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
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

  Widget _overview() => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 860;
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _simulationPanel(wide),
          const SizedBox(height: 16),
          if (wide)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _activityPanel()),
                  const SizedBox(width: 16),
                  Expanded(child: _channelsPanel()),
                ],
              ),
            )
          else ...[
            _activityPanel(),
            const SizedBox(height: 16),
            _channelsPanel(),
          ],
        ],
      );
    },
  );

  Widget _simulationPanel(bool wide) {
    final simulated = _automation is AutomationBinding;
    final enabled = _automation?.pretendForeground ?? false;
    final lifecycle = _automation == null
        ? 'normal entrypoint'
        : _automation!.rawLifecycle?.name ?? 'not reported';
    final covers = _scope(
      'Covers',
      const ['Framework lifecycle observers', 'View-focus notifications'],
      Icons.check_rounded,
      Lab.ok,
    );
    final excludes = _scope(
      'Not simulated',
      const [
        'IME and OS hotkeys',
        'Foreground HWND checks',
        'Native activation',
      ],
      Icons.close_rounded,
      Lab.clay,
    );
    return LabPanel(
      eyebrow: simulated ? 'Windows test entrypoint' : 'Platform owned',
      title: simulated ? 'Foreground simulation' : 'Real platform lifecycle',
      // Simulation exists only in the Windows test binding; mobile shows
      // the real lifecycle without a control it could never enable.
      trailing: simulated
          ? Switch(
              key: const ValueKey('foreground-switch'),
              value: enabled,
              onChanged: (value) => _automation!.setPretendForeground(value),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            simulated
                ? 'Treat this app as foreground'
                : 'Lifecycle and focus come from the platform',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Lab.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            simulated
                ? 'Windows test entrypoint only. Mobile lifecycle remains real.'
                : 'No simulation in this binding. Observations are reported as they occur.',
            style: const TextStyle(fontSize: 14, color: Lab.muted),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              LabReadout(
                label: 'Platform lifecycle',
                value: lifecycle,
                led: lifecycle == 'resumed' ? Lab.ok : Lab.clay,
              ),
              if (simulated)
                LabReadout(
                  label: 'Simulation',
                  value: enabled ? 'engaged' : 'off',
                  led: enabled ? Lab.clay : Lab.off,
                ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(height: 1, color: Lab.line),
          const SizedBox(height: 18),
          if (wide)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: covers),
                const SizedBox(width: 24),
                Expanded(child: excludes),
              ],
            )
          else ...[
            covers,
            const SizedBox(height: 14),
            excludes,
          ],
        ],
      ),
    );
  }

  Widget _scope(String title, List<String> items, IconData icon, Color color) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title.toUpperCase(), style: Lab.eyebrow()),
          const SizedBox(height: 10),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: .14),
                      shape: BoxShape.circle,
                      border: Border.all(color: color.withValues(alpha: .4)),
                    ),
                    child: Icon(icon, size: 14, color: color),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      item,
                      style: const TextStyle(fontSize: 14, color: Lab.text),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );

  Widget _activityPanel() => LabPanel(
    eyebrow: 'Gated by resumed',
    title: 'Foreground-only activity',
    accent: Lab.sky,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              '$_gatedTicks',
              key: const ValueKey('foreground-ticks'),
              style: Lab.monoStyle(size: 52, weight: FontWeight.w700),
            ),
            const SizedBox(width: 10),
            const Text(
              'updates',
              style: TextStyle(fontSize: 16, color: Lab.muted),
            ),
          ],
        ),
        const SizedBox(height: 16),
        LabMeter(filled: (_gatedTicks % 50) ~/ 2),
        const SizedBox(height: 14),
        const Text(
          'This activity advances only while Flutter reports resumed.',
          style: TextStyle(fontSize: 14, color: Lab.muted),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            const Expanded(
              child: Text(
                'Animate capture marker',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Lab.text,
                ),
              ),
            ),
            Switch(
              value: _motion,
              onChanged: (value) => setState(() => _motion = value),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _channelsPanel() => LabPanel(
    eyebrow: 'Evidence',
    title: 'Capture channels',
    accent: Lab.teal,
    child: Column(
      children: [
        _channel(
          Icons.image_outlined,
          'App PNG',
          'Flutter RepaintBoundary',
          Lab.clay,
        ),
        const SizedBox(height: 10),
        _channel(
          Icons.monitor_outlined,
          'System capture',
          'Platform window or device capture',
          Lab.sky,
        ),
        const SizedBox(height: 10),
        _channel(
          Icons.cable_outlined,
          'Automation',
          'Flutter Driver over the local VM service',
          Lab.teal,
        ),
      ],
    ),
  );

  Widget _channel(IconData icon, String title, String detail, Color color) =>
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0x800a0e17),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Lab.line),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: color.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: color.withValues(alpha: .4)),
              ),
              child: Icon(icon, size: 20, color: color),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Lab.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: Lab.monoStyle(size: 12, color: Lab.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  static const _artworks = [
    'Aurora',
    'Tide',
    'Lattice',
    'Orbit',
    'Drift',
    'Pollen',
    'Halo',
    'Current',
    'Mosaic',
    'Eclipse',
    'Ripple',
    'Ember',
    'Nova',
    'Swell',
    'Grid',
    'Perigee',
    'Breeze',
    'Spark',
    'Zenith',
    'Undertow',
    'Weave',
    'Comet',
    'Shoal',
    'Glint',
  ];

  Widget _gallery() => NotificationListener<ScrollNotification>(
    onNotification: (event) {
      _scroll = event.metrics.pixels;
      return false;
    },
    child: GridView.builder(
      key: const ValueKey('gallery-scroll'),
      padding: const EdgeInsets.only(bottom: 24),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 280,
        mainAxisExtent: 210,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: 24,
      itemBuilder: (context, index) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Lab.line),
          color: Lab.surface,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('tile-$index'),
              onTap: () => setState(() => _clicks++),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: LabArt(index)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _artworks[index],
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: Lab.text,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                ['Orbits', 'Waves', 'Dot field'][index % 3],
                                style: const TextStyle(
                                  fontSize: 12.5,
                                  color: Lab.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          'tile-$index',
                          style: Lab.monoStyle(size: 11, color: Lab.muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _scenarios() => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 860;
      final dialog = _dialogPanel();
      final stage = _stagePanel();
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: wide
            ? [
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 2, child: dialog),
                      const SizedBox(width: 16),
                      Expanded(flex: 3, child: stage),
                    ],
                  ),
                ),
              ]
            : [dialog, const SizedBox(height: 16), stage],
      );
    },
  );

  Widget _dialogPanel() => LabPanel(
    eyebrow: 'Modal route',
    title: 'Confirmation dialog',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.icon(
          key: const ValueKey('open-dialog'),
          onPressed: _showConfirmation,
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text('Open confirmation dialog'),
        ),
        const SizedBox(height: 18),
        const Text(
          'Barrier dismissal is off; the page behind stays blocked.',
          style: TextStyle(fontSize: 14, color: Lab.muted),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            LabReadout(
              label: 'Result',
              value: _dialogResult,
              led: switch (_dialogResult) {
                'confirmed' => Lab.ok,
                'cancelled' => Lab.clay,
                _ => Lab.off,
              },
            ),
            LabReadout(
              label: 'Confirmed',
              value: '$_dialogConfirmed',
              led: _dialogOpen ? Lab.sky : Lab.off,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Result: $_dialogResult · confirmed $_dialogConfirmed',
          key: const ValueKey('dialog-result'),
          style: Lab.monoStyle(size: 11, color: Lab.muted),
        ),
      ],
    ),
  );

  Widget _stagePanel() => LabPanel(
    eyebrow: 'AnimationController · 2 s each way',
    title: 'Animation stage',
    accent: Lab.sky,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Controls sit above the stage so they stay on screen at phone sizes;
        // Driver taps require a hit-testable target and never scroll.
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              key: const ValueKey('animation-play'),
              onPressed: () {
                _animation.repeat(reverse: true);
                setState(() {});
              },
              icon: const Icon(Icons.play_arrow_rounded, size: 18),
              label: const Text('Play'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('animation-pause'),
              onPressed: () {
                _animation.stop();
                setState(() {});
              },
              icon: const Icon(Icons.pause_rounded, size: 18),
              label: const Text('Pause'),
            ),
            TextButton.icon(
              key: const ValueKey('animation-reset'),
              onPressed: () {
                _animation.reset();
                setState(() {});
              },
              icon: const Icon(Icons.restart_alt_rounded, size: 18),
              label: const Text('Reset'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // A dedicated region excludes the heartbeat/status labels from pixel
        // motion checks, so changing text cannot masquerade as animation.
        SizedBox(
          key: _animationKey,
          height: 140,
          width: double.infinity,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: ColoredBox(
              color: const Color(0xff0c1220),
              child: CustomPaint(
                painter: const _StagePainter(),
                child: AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) => Align(
                    alignment: Alignment(-0.85 + _animation.value * 1.7, 0),
                    child: Transform.rotate(
                      angle: _animation.value * 6.283185,
                      child: child,
                    ),
                  ),
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Lab.clay,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0xfff2b38f),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      size: 38,
                      color: Color(0xff1b0d07),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Pixel verification uses only this stage.',
          style: Lab.monoStyle(size: 11, color: Lab.muted),
        ),
      ],
    ),
  );

  Widget _interactions() => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 860;
      return ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: wide
            ? [
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 3, child: _inputPanel()),
                      const SizedBox(width: 16),
                      Expanded(
                        flex: 2,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _keyboardPanel(),
                            const SizedBox(height: 16),
                            Expanded(child: _eventsPanel()),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ]
            : [
                _inputPanel(),
                const SizedBox(height: 16),
                _keyboardPanel(),
                const SizedBox(height: 16),
                _eventsPanel(),
              ],
      );
    },
  );

  Widget _inputPanel() => LabPanel(
    eyebrow: 'Driver text and pointer',
    title: 'Text and pointer input',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          key: const ValueKey('input-field'),
          controller: _text,
          focusNode: _focus,
          style: const TextStyle(fontSize: 16, color: Lab.text),
          decoration: const InputDecoration(
            labelText: 'Automation text',
            hintText: 'Typed through the framework text path',
            prefixIcon: Icon(Icons.keyboard_alt_outlined, size: 20),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            LabReadout(
              label: 'Characters',
              value: '${_text.text.characters.length}',
              led: _text.text.isEmpty ? Lab.off : Lab.sky,
            ),
            LabReadout(
              label: 'Field focus',
              value: _focus.hasFocus ? 'focused' : 'idle',
              led: _focus.hasFocus ? Lab.ok : Lab.off,
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Divider(height: 1, color: Lab.line),
        const SizedBox(height: 18),
        // Wraps on narrow screens instead of squeezing the button.
        Wrap(
          spacing: 20,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '$_clicks clicks',
              key: const ValueKey('click-count'),
              style: Lab.monoStyle(size: 34, weight: FontWeight.w700),
            ),
            FilledButton.icon(
              key: const ValueKey('increment-button'),
              onPressed: () => setState(() => _clicks++),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Increment counter'),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _keyboardPanel() => LabPanel(
    eyebrow: 'Framework key events',
    title: 'Keyboard target',
    accent: Lab.teal,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Focus the target, then send F6 through Flutter key events. '
          'No OS keyboard input is generated.',
          style: TextStyle(fontSize: 14, color: Lab.muted),
        ),
        const SizedBox(height: 14),
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
            builder: (context) => OutlinedButton.icon(
              key: const ValueKey('focus-key-button'),
              onPressed: () => Focus.of(context).requestFocus(),
              icon: const Icon(Icons.center_focus_strong_outlined, size: 18),
              label: Text('Focus keyboard target · F6 count $_shortcutCount'),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _eventsPanel() {
    final events = _lifecycleEvents.reversed.take(6).toList();
    return LabPanel(
      eyebrow: 'Real platform',
      title: 'Lifecycle events',
      accent: Lab.sky,
      child: events.isEmpty
          ? const Text(
              'No lifecycle changes yet.',
              style: TextStyle(fontSize: 14, color: Lab.muted),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (index, event) in events.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Text(
                          (_lifecycleEvents.length - index).toString().padLeft(
                            2,
                            '0',
                          ),
                          style: Lab.monoStyle(size: 12, color: Lab.muted),
                        ),
                        const SizedBox(width: 12),
                        LabLed(event == 'resumed' ? Lab.ok : Lab.clay, size: 6),
                        const SizedBox(width: 10),
                        Text(event, style: Lab.monoStyle(size: 14)),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _StagePainter extends CustomPainter {
  const _StagePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()..color = const Color(0x0fffffff);
    for (var x = 0.0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    // The track the object travels along.
    canvas.drawLine(
      Offset(size.width * .075, size.height / 2),
      Offset(size.width * .925, size.height / 2),
      Paint()
        ..color = const Color(0x5554c5f8)
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
