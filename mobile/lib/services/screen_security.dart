import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Two privacy switches for this phone: keep the app out of screenshots and the
/// recent-apps preview, and ask the keyboard not to learn from what you type.
/// Both are kept on this device only and are off until the person turns them on.
class ScreenSecurity {
  ScreenSecurity._();

  static const _screenKey = 'screen_security';
  static const _keyboardKey = 'incognito_keyboard';
  static const _channel = MethodChannel('elephant/window');

  /// True while screenshots and the recent-apps preview are blocked.
  static final screenSecure = ValueNotifier<bool>(false);

  /// True while the message box asks the keyboard not to learn.
  static final incognitoKeyboard = ValueNotifier<bool>(false);

  /// Reads both switches and applies the first. Call once at startup.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    screenSecure.value = prefs.getBool(_screenKey) ?? false;
    incognitoKeyboard.value = prefs.getBool(_keyboardKey) ?? false;
    await _apply(screenSecure.value);
  }

  static Future<void> setScreenSecure(bool on) async {
    screenSecure.value = on;
    await (await SharedPreferences.getInstance()).setBool(_screenKey, on);
    await _apply(on);
  }

  static Future<void> setIncognitoKeyboard(bool on) async {
    incognitoKeyboard.value = on;
    await (await SharedPreferences.getInstance()).setBool(_keyboardKey, on);
  }

  /// Tells the phone to block or allow capture. The switch still counts if
  /// there is no native side (a test, or another platform).
  static Future<void> _apply(bool on) async {
    try {
      await _channel.invokeMethod<void>('secure', {'on': on});
    } on MissingPluginException {
      // Nothing to block on this platform.
    } on PlatformException catch (e) {
      debugPrint("Couldn't change screen security: $e");
    }
  }
}
