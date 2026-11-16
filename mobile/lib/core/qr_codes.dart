import 'dart:typed_data';

import 'package:mobile/core/profile_links.dart';
import 'package:zxing2/qrcode.dart';

final _bareUsername = RegExp(r'^[a-z0-9]{1,40}\.[0-9]{4}$');

/// The username an Elephant QR code points to: a profile link (current codes)
/// or a bare username (codes shown by older versions). Null for any other
/// code.
String? usernameFromQr(String text) {
  final trimmed = text.trim();
  final uri = Uri.tryParse(trimmed);
  if (uri != null && uri.hasScheme) return ProfileLinks.usernameFrom(uri);
  final lower = trimmed.toLowerCase();
  return _bareUsername.hasMatch(lower) ? lower : null;
}

/// Decodes a QR code from a camera frame's brightness (Y) plane, or returns
/// null if there's none. [rowStride] is the bytes per row, which can be more
/// than [width].
String? decodeQr(
  Uint8List luminance, {
  required int width,
  required int height,
  required int rowStride,
}) {
  try {
    final source = _BrightnessPlane(luminance, rowStride, width, height);
    return QRCodeReader().decode(BinaryBitmap(HybridBinarizer(source))).text;
  } on ReaderException {
    return null;
  } catch (_) {
    // A malformed frame is just "no code here".
    return null;
  }
}

/// A camera frame's brightness plane, rows [_stride] bytes apart, as zxing2
/// reads it.
class _BrightnessPlane extends LuminanceSource {
  final Int8List _data;
  final int _stride;

  _BrightnessPlane(Uint8List data, this._stride, int width, int height)
    : _data = Int8List.sublistView(data),
      super(width, height);

  @override
  Int8List getRow(int y, Int8List? row) {
    if (row == null || row.length < width) row = Int8List(width);
    row.setRange(0, width, _data, y * _stride);
    return row;
  }

  @override
  Int8List getMatrix() {
    final matrix = Int8List(width * height);
    for (var y = 0; y < height; y++) {
      matrix.setRange(y * width, (y + 1) * width, _data, y * _stride);
    }
    return matrix;
  }
}
