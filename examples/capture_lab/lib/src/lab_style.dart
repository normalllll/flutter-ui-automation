import 'dart:math';

import 'package:flutter/material.dart';

/// Dark "instrument panel" palette for the fixture. Everything is static:
/// decorative motion would keep transient callbacks alive and prevent the
/// verifier from observing a settled frame.
abstract final class Lab {
  static const ink = Color(0xff080b12);
  static const surface = Color(0xff101622);
  static const raised = Color(0xff161e2e);
  static const line = Color(0x1affffff);
  static const text = Color(0xffeef1f7);
  static const muted = Color(0xff8c96aa);
  static const clay = Color(0xffd97757);
  static const sky = Color(0xff54c5f8);
  static const teal = Color(0xff2ec4b6);
  static const ok = Color(0xff4ade80);
  static const off = Color(0xff5b667a);
  static const sans = 'Segoe UI';
  static const mono = 'Cascadia Mono';
  static const monoFallback = [
    'Consolas',
    'JetBrains Mono',
    'Roboto Mono',
    'Menlo',
    'monospace',
  ];

  static TextStyle monoStyle({
    double size = 13,
    FontWeight weight = FontWeight.w500,
    Color color = text,
    double spacing = 0,
  }) => TextStyle(
    fontFamily: mono,
    fontFamilyFallback: monoFallback,
    fontSize: size,
    fontWeight: weight,
    color: color,
    letterSpacing: spacing,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  static TextStyle eyebrow([Color color = muted]) =>
      monoStyle(size: 11, weight: FontWeight.w600, color: color, spacing: 1.6);

  static ThemeData theme() {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: clay,
          brightness: Brightness.dark,
        ).copyWith(
          primary: clay,
          onPrimary: const Color(0xff1b0d07),
          secondary: sky,
          tertiary: teal,
          surface: surface,
          onSurface: text,
          onSurfaceVariant: muted,
          outline: const Color(0x33ffffff),
          outlineVariant: line,
        );
    return ThemeData(
      colorScheme: scheme,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.transparent,
      fontFamily: sans,
      dividerColor: line,
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const Color(0xfffff4ee)
              : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? clay : raised,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? clay : scheme.outline,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xf00c111b),
        indicatorColor: clay.withValues(alpha: .18),
        surfaceTintColor: Colors.transparent,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? clay : muted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected) ? text : muted,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ink.withValues(alpha: .6),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0x2effffff)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: clay, width: 1.5),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: line),
        ),
      ),
    );
  }
}

/// Static backdrop: flat ink with a faint measurement grid.
///
/// Large areas stay flat on purpose. App screenshots are PNG-encoded on the
/// device during recordings; full-screen gradients made every frame ~7× larger
/// and pushed 2 fps Android acquisition past its timing budget.
class LabBackdrop extends StatelessWidget {
  const LabBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Lab.ink,
    child: Stack(
      children: [
        const Positioned.fill(child: CustomPaint(painter: _GridPainter())),
        Positioned.fill(child: child),
      ],
    ),
  );
}

class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0x0affffff)
      ..strokeWidth = 1;
    const step = 40.0;
    for (var x = 0.0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (var y = 0.0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Glassy panel with a hairline border and an accent edge along the top.
class LabPanel extends StatelessWidget {
  const LabPanel({
    super.key,
    required this.title,
    required this.child,
    this.eyebrow,
    this.trailing,
    this.accent = Lab.clay,
    this.padding = const EdgeInsets.all(24),
  });
  final String title;
  final String? eyebrow;
  final Widget? trailing;
  final Widget child;
  final Color accent;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: Lab.line),
      color: const Color(0xff131a28),
    ),
    child: Stack(
      children: [
        Positioned(
          left: 24,
          right: 24,
          top: 0,
          child: Container(
            height: 1.5,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  accent.withValues(alpha: 0),
                  accent,
                  accent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (eyebrow case final eyebrow?) ...[
                          Text(
                            eyebrow.toUpperCase(),
                            style: Lab.eyebrow(accent),
                          ),
                          const SizedBox(height: 6),
                        ],
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w700,
                            color: Lab.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      ],
    ),
  );
}

/// A small status light. Static glow, no pulsing.
class LabLed extends StatelessWidget {
  const LabLed(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(color: color.withValues(alpha: .7), blurRadius: size * 1.4),
      ],
    ),
  );
}

/// Instrument readout: mono label, mono value and a status light.
class LabReadout extends StatelessWidget {
  const LabReadout({
    super.key,
    required this.label,
    required this.value,
    required this.led,
    this.compact = false,
  });
  final String label;
  final String value;
  final Color led;
  final bool compact;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: compact ? 12 : 16,
      vertical: compact ? 9 : 13,
    ),
    decoration: BoxDecoration(
      color: const Color(0xb30c111b),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Lab.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            LabLed(led, size: compact ? 6 : 7),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Lab.eyebrow(),
              ),
            ),
          ],
        ),
        SizedBox(height: compact ? 4 : 7),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Lab.monoStyle(
            size: compact ? 14 : 17,
            weight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

/// Segmented meter: [filled] of [segments] cells lit with the accent ramp.
class LabMeter extends StatelessWidget {
  const LabMeter({
    super.key,
    required this.filled,
    this.segments = 25,
    this.height = 22,
  });
  final int filled;
  final int segments;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Row(
      children: [
        for (var i = 0; i < segments; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                color: i < filled
                    ? Color.lerp(
                        Lab.clay,
                        const Color(0xfff2b38f),
                        i / segments,
                      )
                    : const Color(0x14ffffff),
                boxShadow: i < filled && i == filled - 1
                    ? const [
                        BoxShadow(color: Color(0x99d97757), blurRadius: 10),
                      ]
                    : null,
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Presentation probe: an 8×4 dot matrix encoding `1010 · token · 0101`,
/// row-major from the top-left. Pink is 1, aqua is 0.
///
/// Decoders split [bitsKey]'s rect into an 8×4 grid and sample the centre of
/// each cell, using the header's two pink and two aqua dots as the colour
/// reference. The gaps between dots and the tag around the grid are
/// decoration outside the sampled centres.
class LabProbe extends StatelessWidget {
  const LabProbe({super.key, required this.bitsKey, required this.token});
  final Key bitsKey;
  final int token;

  /// Must match the decoders in tools/automation and tools/window_capture.
  static const probeOne = Color(0xffff8fb1);
  static const probeZero = Color(0xff38bdd8);
  static const columns = 8, rows = 4;
  // Compact but still ≥10 physical pixels per dot at 1.5× for 3×3 sampling.
  static const pitch = 9.0, dot = 7.0;

  Color _cell(int index) =>
      (0xa << 28 | token << 4 | 0x5) >> (31 - index) & 1 == 1
      ? probeOne
      : probeZero;

  @override
  Widget build(BuildContext context) {
    // Painted above the Navigator, outside any Material: supply the text
    // defaults here and keep the tag opaque over whatever lies beneath it.
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.fromLTRB(7, 7, 7, 5),
        decoration: BoxDecoration(
          color: const Color(0xff111827),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x59ff8fb1)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              key: bitsKey,
              width: columns * pitch,
              height: rows * pitch,
              // Plain rows: no scrollable, so nothing here can settle or scroll.
              child: Column(
                children: [
                  for (var row = 0; row < rows; row++)
                    Row(
                      children: [
                        for (var column = 0; column < columns; column++)
                          SizedBox.square(
                            dimension: pitch,
                            child: Padding(
                              padding: const EdgeInsets.all((pitch - dot) / 2),
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: _cell(row * columns + column),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '#${token.toRadixString(16).padLeft(6, '0')}',
              style: Lab.monoStyle(size: 9, color: Lab.muted, spacing: .4),
            ),
          ],
        ),
      ),
    );
  }
}

/// Static generative artwork for gallery tiles. Deterministic per [index]
/// and never animated, so tiles do not keep frames pending.
class LabArt extends StatelessWidget {
  const LabArt(this.index, {super.key});
  final int index;

  static const hues = [
    Lab.clay,
    Lab.sky,
    Lab.teal,
    Color(0xffa78bfa),
    Color(0xffff8fb1),
    Color(0xfffbbf24),
  ];

  @override
  Widget build(BuildContext context) {
    final a = hues[index % hues.length];
    final b = hues[(index * 5 + 2) % hues.length];
    // A flat tint, not a gradient: tiles are captured as app PNGs on device.
    return ColoredBox(
      color: Color.lerp(a, Lab.ink, .74)!,
      child: ClipRect(
        child: CustomPaint(
          painter: _ArtPainter(index, a, b),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _ArtPainter extends CustomPainter {
  const _ArtPainter(this.index, this.a, this.b);
  final int index;
  final Color a, b;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    switch (index % 3) {
      case 0:
        // Orbits around an off-centre sun.
        final centre = Offset(size.width * .68, size.height * .58);
        for (var i = 1; i <= 5; i++) {
          stroke.color = Color.lerp(a, b, i / 5)!.withValues(alpha: .75);
          canvas.drawCircle(centre, i * size.height * .13, stroke);
        }
        canvas.drawCircle(centre, size.height * .09, Paint()..color = a);
        canvas.drawCircle(
          centre.translate(-size.height * .39, -size.height * .1),
          size.height * .035,
          Paint()..color = b,
        );
      case 1:
        // Layered waves.
        for (var i = 0; i < 6; i++) {
          final path = Path();
          final base = size.height * (.3 + i * .1);
          path.moveTo(0, base);
          for (var x = 0.0; x <= size.width; x += 4) {
            path.lineTo(
              x,
              base + sin(x / size.width * pi * 2 + i * .7 + index) * 9,
            );
          }
          stroke.color = Color.lerp(a, b, i / 5)!.withValues(alpha: .8);
          canvas.drawPath(path, stroke);
        }
      default:
        // Dot field with a bright diagonal.
        const step = 14.0;
        for (var y = step / 2; y < size.height; y += step) {
          for (var x = step / 2; x < size.width; x += step) {
            final t = ((x / size.width) + (y / size.height)) / 2;
            final on =
                ((x / step).floor() + (y / step).floor() + index) % 7 == 0;
            canvas.drawCircle(
              Offset(x, y),
              on ? 3 : 1.6,
              Paint()
                ..color = Color.lerp(a, b, t)!.withValues(alpha: on ? 1 : .45),
            );
          }
        }
    }
  }

  @override
  bool shouldRepaint(covariant _ArtPainter old) =>
      old.index != index || old.a != a || old.b != b;
}
