import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;

import 'protocol.dart';

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

bool markerMatches(image.Image pixels, Json probe, {Json? displayProjection}) {
  final bounds = probe.child('native').child('viewBounds');
  final rect = probe.child('rect');
  final ratio = probe.number('pixelRatio');
  final sourceWidth = displayProjection?.integer('sourceWidth') ?? pixels.width;
  final sourceHeight =
      displayProjection?.integer('sourceHeight') ?? pixels.height;
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
  final word = (0xa << 28) | (probe.integer('token') << 4) | 5;
  for (var i = 0; i < 32; i++) {
    var x =
        bounds.number('x') +
        (rect.number('x') + (i + .5) * rect.number('width') / 32) * ratio;
    var y =
        bounds.number('y') +
        (rect.number('y') + rect.number('height') / 2) * ratio;
    if (displayProjection != null) {
      x =
          displayProjection.number('x') +
          x * displayProjection.number('width') / sourceWidth;
      y =
          displayProjection.number('y') +
          y * displayProjection.number('height') / sourceHeight;
    }
    final px = x.round(), py = y.round();
    if (px < 0 || py < 0 || px >= pixels.width || py >= pixels.height) {
      return false;
    }
    final actual = pixels.getPixel(px, py);
    final expected = word >> (31 - i) & 1 == 1 ? [240, 180, 41] : [22, 50, 79];
    final values = [actual.r, actual.g, actual.b];
    if (List.generate(
      3,
      (c) => (values[c] - expected[c]).abs() > 35,
    ).any((v) => v)) {
      return false;
    }
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
      nx + w > right.width ||
      ny + h > right.height) {
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
  final a = crop(left, x, y), b = crop(right, nx, ny);
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
