import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'protocol.dart';

enum CaptureRotation {
  none(0),
  clockwise(90),
  upsideDown(180),
  counterclockwise(270);

  const CaptureRotation(this.degrees);
  final int degrees;
  static CaptureRotation fromDegrees(int value) => values.firstWhere(
    (rotation) => rotation.degrees == value,
    orElse: () => throw const AutomationError(
      'invalid_rotation',
      'Use 0, 90, 180 or 270 degrees',
    ),
  );
  image.Image apply(image.Image pixels) =>
      this == none ? pixels : image.copyRotate(pixels, angle: degrees);
  String get videoFilter => switch (this) {
    none => '',
    clockwise => 'transpose=1,',
    upsideDown => 'hflip,vflip,',
    counterclockwise => 'transpose=2,',
  };
}

({int width, int height}) pngSize(List<int> bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 ||
      !List.generate(8, (i) => bytes[i] == signature[i]).every((v) => v)) {
    throw const AutomationError('invalid_png', 'Capture did not return a PNG');
  }
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  final width = data.getUint32(16), height = data.getUint32(20);
  if (width <= 0 || height <= 0 || width * height > 64000000) {
    throw const AutomationError('invalid_png', 'Invalid PNG dimensions');
  }
  return (width: width, height: height);
}

Json projection(int sourceWidth, int sourceHeight, int width, int height) {
  final landscapeFit = (width * sourceHeight / sourceWidth).floor();
  final w = height > landscapeFit
      ? width
      : (height * sourceWidth / sourceHeight).floor();
  final h = height > landscapeFit ? landscapeFit : height;
  return {
    'x': (width - w) ~/ 2,
    'y': (height - h) ~/ 2,
    'width': w,
    'height': h,
    'sourceWidth': sourceWidth,
    'sourceHeight': sourceHeight,
  };
}

/// Presentation probe colours (RGB): pink is 1, aqua is 0. Must match the
/// fixture's LabProbe and tools/window_capture/capture.cpp.
const probeOne = [255, 143, 177];
const probeZero = [56, 189, 216];

/// The probe is an 8×4 grid, row-major from the top-left, encoding
/// `1010 · 24-bit token · 0101`.
const probeColumns = 8, probeRows = 4;

int probeWord(int token) => (0xa << 28) | (token << 4) | 5;

/// Header dots calibrate the observed colours; they must stay near nominal.
const _referenceTolerance = 64;

/// Minimum observed distance between the calibrated pink and aqua.
const _minimumSeparation = 90.0;

double _distance(List<double> a, List<num> b) {
  var sum = 0.0;
  for (var c = 0; c < 3; c++) {
    sum += (a[c] - b[c]) * (a[c] - b[c]);
  }
  return sqrt(sum);
}

List<double> _mean(List<double> a, List<double> b) => [
  for (var c = 0; c < 3; c++) (a[c] + b[c]) / 2,
];

/// Oriented display-space rectangle of probe cell [index] (left, top,
/// right, bottom), applying view bounds, pixel ratio and display projection.
(double, double, double, double) probeCell(
  Json probe,
  int index, {
  Json? displayProjection,
  required int sourceWidth,
  required int sourceHeight,
}) {
  final bounds = probe.child('native').child('viewBounds');
  final rect = probe.child('rect');
  final ratio = probe.number('pixelRatio');
  final column = index % probeColumns, row = index ~/ probeColumns;
  final cellWidth = rect.number('width') / probeColumns;
  final cellHeight = rect.number('height') / probeRows;
  (double, double) map(double lx, double ly) {
    var x = bounds.number('x') + lx * ratio;
    var y = bounds.number('y') + ly * ratio;
    if (displayProjection != null) {
      x =
          displayProjection.number('x') +
          x * displayProjection.number('width') / sourceWidth;
      y =
          displayProjection.number('y') +
          y * displayProjection.number('height') / sourceHeight;
    }
    return (x, y);
  }

  final (left, top) = map(
    rect.number('x') + column * cellWidth,
    rect.number('y') + row * cellHeight,
  );
  final (right, bottom) = map(
    rect.number('x') + (column + 1) * cellWidth,
    rect.number('y') + (row + 1) * cellHeight,
  );
  return (left, top, right, bottom);
}

/// Paints solid probe cells into an oriented image. Used by tests and
/// fixtures that synthesise captures; decoders never alter captured pixels.
void paintProbe(
  image.Image pixels,
  Json probe, {
  int? token,
  Json? displayProjection,
}) {
  final word = probeWord(token ?? probe.integer('token'));
  for (var i = 0; i < 32; i++) {
    final (left, top, right, bottom) = probeCell(
      probe,
      i,
      displayProjection: displayProjection,
      sourceWidth: displayProjection?.integer('sourceWidth') ?? pixels.width,
      sourceHeight: displayProjection?.integer('sourceHeight') ?? pixels.height,
    );
    final color = word >> (31 - i) & 1 == 1 ? probeOne : probeZero;
    for (var y = top.floor(); y < bottom.ceil(); y++) {
      for (var x = left.floor(); x < right.ceil(); x++) {
        if (x < 0 || y < 0 || x >= pixels.width || y >= pixels.height) {
          continue;
        }
        pixels.setPixelRgb(x, y, color[0], color[1], color[2]);
      }
    }
  }
}

bool markerMatches(
  image.Image pixels,
  Json probe, {
  Json? displayProjection,
  CaptureRotation rotation = CaptureRotation.none,
}) {
  final bounds = probe.child('native').child('viewBounds');
  final ratio = probe.number('pixelRatio');
  final (width, height) = switch (rotation) {
    CaptureRotation.clockwise ||
    CaptureRotation.counterclockwise => (pixels.height, pixels.width),
    _ => (pixels.width, pixels.height),
  };
  final sourceWidth = displayProjection?.integer('sourceWidth') ?? width;
  final sourceHeight = displayProjection?.integer('sourceHeight') ?? height;
  if (ratio <= 0 ||
      bounds.number('x') < 0 ||
      bounds.number('y') < 0 ||
      bounds.number('x') + bounds.number('width') > sourceWidth + 1 ||
      bounds.number('y') + bounds.number('height') > sourceHeight + 1) {
    throw const AutomationError(
      'geometry_changed',
      'Flutter view bounds are outside the captured display',
    );
  }
  // Average a 3×3 neighbourhood at each cell centre. Only the sample
  // coordinates are rotated; rotating a multi-megapixel copy for 32 samples
  // could itself overrun a recording interval.
  final samples = <List<double>>[];
  for (var i = 0; i < 32; i++) {
    final (left, top, right, bottom) = probeCell(
      probe,
      i,
      displayProjection: displayProjection,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    );
    final cx = ((left + right) / 2).floor(), cy = ((top + bottom) / 2).floor();
    if (cx < 1 || cy < 1 || cx >= width - 1 || cy >= height - 1) return false;
    final sum = [0.0, 0.0, 0.0];
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final px = cx + dx, py = cy + dy;
        final (rawX, rawY) = switch (rotation) {
          CaptureRotation.none => (px, py),
          CaptureRotation.clockwise => (py, pixels.height - 1 - px),
          CaptureRotation.counterclockwise => (pixels.width - 1 - py, px),
          CaptureRotation.upsideDown => (
            pixels.width - 1 - px,
            pixels.height - 1 - py,
          ),
        };
        final pixel = pixels.getPixel(rawX, rawY);
        sum[0] += pixel.r;
        sum[1] += pixel.g;
        sum[2] += pixel.b;
      }
    }
    samples.add([for (final v in sum) v / 9]);
  }
  return probeBitsMatch(samples, probe.integer('token'));
}

/// Classifies 32 sampled RGB cells against the token, calibrating pink and
/// aqua from the `1010` header so uniform colour shifts (lossy video, tone
/// mapping, night light) do not reject a correctly presented probe.
bool probeBitsMatch(List<List<double>> samples, int token) {
  final word = probeWord(token);
  // Header cells 0 and 2 are pink, 1 and 3 aqua; each pair must agree.
  if (_distance(samples[0], samples[2]) > 40 ||
      _distance(samples[1], samples[3]) > 40) {
    return false;
  }
  final one = _mean(samples[0], samples[2]);
  final zero = _mean(samples[1], samples[3]);
  for (var c = 0; c < 3; c++) {
    if ((one[c] - probeOne[c]).abs() > _referenceTolerance ||
        (zero[c] - probeZero[c]).abs() > _referenceTolerance) {
      return false;
    }
  }
  final separation = _distance(one, zero);
  if (separation < _minimumSeparation) return false;
  for (var i = 0; i < 32; i++) {
    final toOne = _distance(samples[i], one);
    final toZero = _distance(samples[i], zero);
    // Reject cells that resemble neither calibrated colour.
    if (min(toOne, toZero) > separation * .45) return false;
    if ((toOne < toZero) != (word >> (31 - i) & 1 == 1)) return false;
  }
  return true;
}

Future<bool> markerInFile(
  String path,
  Json probe, {
  Json? displayProjection,
}) async {
  final pixels = image.decodePng(await File(path).readAsBytes());
  if (pixels == null) {
    throw const AutomationError('invalid_png', 'Could not decode original PNG');
  }
  return markerMatches(pixels, probe, displayProjection: displayProjection);
}

Future<Json> compareCapture(
  Json app,
  Json native, {
  required bool android,
  required Json state,
}) async {
  final left = image.decodePng(await File(app.text('path')).readAsBytes());
  final right = image.decodePng(await File(native.text('path')).readAsBytes());
  if (left == null || right == null) {
    throw const AutomationError('invalid_png', 'Could not decode capture pair');
  }
  final oriented = CaptureRotation.fromDegrees(
    native.integer('rotationToAppDegrees', fallback: 0),
  ).apply(right);
  final content = app['contentRect'] is Json
      ? app.child('contentRect')
      : <String, Object?>{
          'x': 0,
          'y': 0,
          'width': left.width,
          'height': left.height,
        };
  final bounds = android
      ? state.child('native').child('viewBounds')
      : <String, Object?>{'x': native['clientX'], 'y': native['clientY']};
  final x = content.integer('x'),
      y = content.integer('y'),
      w = content.integer('width'),
      h = content.integer('height');
  final nx = bounds.number('x').round() + x,
      ny = bounds.number('y').round() + y;
  if (x < 0 ||
      y < 0 ||
      w < 1 ||
      h < 1 ||
      x + w > left.width ||
      y + h > left.height ||
      nx < 0 ||
      ny < 0 ||
      nx + w > oriented.width ||
      ny + h > oriented.height) {
    throw const AutomationError(
      'geometry_changed',
      'Capture pair bounds disagree',
    );
  }
  image.Image crop(image.Image source, int x, int y) => image.copyResize(
    image.copyCrop(source, x: x, y: y, width: w, height: h),
    width: 96,
    height: 54,
    interpolation: image.Interpolation.average,
  );
  final a = crop(left, x, y), b = crop(oriented, nx, ny);
  var sum = 0.0, mean = 0.0, squares = 0.0;
  const count = 96 * 54 * 3;
  for (var yy = 0; yy < 54; yy++) {
    for (var xx = 0; xx < 96; xx++) {
      final aa = a.getPixel(xx, yy), bb = b.getPixel(xx, yy);
      for (final pair in [(aa.r, bb.r), (aa.g, bb.g), (aa.b, bb.b)]) {
        sum += (pair.$1 - pair.$2).abs();
        mean += pair.$2;
        squares += pair.$2 * pair.$2;
      }
    }
  }
  mean /= count;
  final variance = squares / count - mean * mean;
  return {
    'meanPixelDifference': sum / count,
    'contentVariance': variance,
    'passed': sum / count < (android ? 8 : 3.5) && variance > 64,
    'region': content,
  };
}
