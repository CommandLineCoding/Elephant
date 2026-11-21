import 'package:flutter/services.dart';

/// What this phone is called, like "Google Pixel 8", sent when signing in so
/// the person can tell their devices apart in Signed-in devices. It is the
/// maker and model the phone reports, nothing that identifies the person.
class DeviceName {
  DeviceName._();

  static const _channel = MethodChannel('elephant/window');
  static String? _cached;

  /// The phone's name, or an empty string if it can't be read.
  static Future<String> get() async {
    final cached = _cached;
    if (cached != null) return cached;
    try {
      final name = await _channel.invokeMethod<String>('deviceName');
      return _cached = (name ?? '').trim();
    } on MissingPluginException {
      return '';
    } on PlatformException {
      return '';
    }
  }
}
