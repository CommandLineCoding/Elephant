import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The phone's side of a call outside the audio itself: ringing, the ringback
/// tone, and (while [inCall]) the ongoing-call notification that keeps the
/// call alive in the background, the screen turning off at the ear and the
/// volume keys setting the call's volume.
class CallSounds {
  static const _channel = MethodChannel('elephant/call');

  Future<void> ring() => _invoke('ring');

  Future<void> ringback() => _invoke('ringback');

  Future<void> stop() => _invoke('stopTones');

  Future<void> inCall(bool on, {String name = ''}) =>
      _invoke('inCall', {'on': on, 'name': name});

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      // Tests and platforms without the Android side.
    } catch (e) {
      debugPrint('Call sounds: $method failed: $e');
    }
  }
}
