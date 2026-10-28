import 'package:flutter_ui_automation/src/pixels.dart';
import 'package:image/image.dart' as image;
import 'package:test/test.dart';

const _probe = <String, Object?>{
  'token': 0x00007b,
  'rect': {'x': 4, 'y': 4, 'width': 96, 'height': 48},
  'pixelRatio': 2,
  'native': {
    'viewBounds': {'x': 6, 'y': 8, 'width': 200, 'height': 100},
  },
};

image.Image _capture({int shift = 0, List<int>? one, List<int>? zero}) {
  final pixels = image.Image(width: 240, height: 140);
  image.fill(pixels, color: image.ColorRgb8(11, 15, 25));
  paintProbe(pixels, _probe);
  final from = [probeOne, probeZero], to = [one ?? probeOne, zero ?? probeZero];
  for (final pixel in pixels) {
    for (var k = 0; k < 2; k++) {
      if (pixel.r == from[k][0] &&
          pixel.g == from[k][1] &&
          pixel.b == from[k][2]) {
        pixel
          ..r = (to[k][0] + shift).clamp(0, 255)
          ..g = (to[k][1] + shift).clamp(0, 255)
          ..b = (to[k][2] + shift).clamp(0, 255);
      }
    }
  }
  return pixels;
}

void main() {
  test('8x4 grid decodes the exact token only', () {
    final pixels = _capture();
    expect(markerMatches(pixels, _probe), true);
    expect(markerMatches(pixels, {..._probe, 'token': 0x00007a}), false);
  });

  test('a uniform colour shift is calibrated from the header', () {
    // Beyond the old fixed ±35 tolerance on every channel.
    expect(markerMatches(_capture(shift: -45), _probe), true);
    expect(markerMatches(_capture(shift: 40), _probe), true);
  });

  test('a different palette is not accepted as the probe', () {
    expect(
      markerMatches(_capture(one: [240, 180, 41], zero: [22, 50, 79]), _probe),
      false,
    );
  });

  test('colours too close together are not accepted', () {
    expect(
      markerMatches(
        _capture(one: [200, 170, 190], zero: [150, 175, 200]),
        _probe,
      ),
      false,
    );
  });

  test('a blank or unrelated frame is rejected', () {
    final blank = image.Image(width: 240, height: 140);
    image.fill(blank, color: image.ColorRgb8(11, 15, 25));
    expect(markerMatches(blank, _probe), false);
  });

  test('cells that match neither calibrated colour reject the frame', () {
    final pixels = _capture();
    // Paint one payload cell grey: centre of cell 12 (row 1, column 4).
    final cx = 6 + (4 + 4.5 * 12) * 2, cy = 8 + (4 + 1.5 * 12) * 2;
    for (var y = cy.toInt() - 4; y < cy + 4; y++) {
      for (var x = cx.toInt() - 4; x < cx + 4; x++) {
        pixels.setPixelRgb(x, y, 128, 128, 128);
      }
    }
    expect(markerMatches(pixels, _probe), false);
  });
}
