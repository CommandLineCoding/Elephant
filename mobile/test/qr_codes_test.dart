import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/qr_codes.dart';
import 'package:zxing2/qrcode.dart';

/// Renders [text] as a QR code into a brightness plane, the way a camera
/// frame arrives: dark modules are 0, light are 255, with a quiet zone and
/// rows padded to [rowStride].
({Uint8List y, int size}) renderQr(String text, {int scale = 6, int pad = 8}) {
  final matrix = Encoder.encode(text, ErrorCorrectionLevel.m).matrix!;
  final size = (matrix.width + 8) * scale;
  final stride = size + pad;
  final y = Uint8List(stride * size)..fillRange(0, stride * size, 255);
  for (var my = 0; my < matrix.height; my++) {
    for (var mx = 0; mx < matrix.width; mx++) {
      if (matrix.get(mx, my) != 1) continue;
      for (var dy = 0; dy < scale; dy++) {
        for (var dx = 0; dx < scale; dx++) {
          final px = (mx + 4) * scale + dx, py = (my + 4) * scale + dy;
          y[py * stride + px] = 0;
        }
      }
    }
  }
  return (y: y, size: size);
}

void main() {
  group('usernameFromQr', () {
    test('accepts profile links and bare usernames', () {
      expect(
        usernameFromQr('https://elephant.commandlinecoding.in/u/alex.4821'),
        'alex.4821',
      );
      expect(usernameFromQr('elephant://u/alex.4821'), 'alex.4821');
      expect(usernameFromQr('  Alex.4821 '), 'alex.4821');
    });

    test('rejects other codes', () {
      for (final code in [
        'https://example.com',
        'WIFI:S:home;T:WPA;P:secret;;',
        'alex',
        'hello world',
        '',
      ]) {
        expect(usernameFromQr(code), isNull, reason: code);
      }
    });
  });

  test('a camera frame with an Elephant code decodes to the username', () {
    const link = 'https://elephant.commandlinecoding.in/u/maya.2723';
    final frame = renderQr(link);
    final text = decodeQr(
      frame.y,
      width: frame.size,
      height: frame.size,
      rowStride: frame.size + 8,
    );
    expect(text, link);
    expect(usernameFromQr(text!), 'maya.2723');
  });

  test('a frame without a code decodes to nothing', () {
    final blank = Uint8List(200 * 200)..fillRange(0, 200 * 200, 255);
    expect(decodeQr(blank, width: 200, height: 200, rowStride: 200), isNull);
  });
}
