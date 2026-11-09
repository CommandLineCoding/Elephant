import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Settings and bookkeeping for push notifications, kept in
/// SharedPreferences so they are also readable when the app is started in the
/// background by a push.
class PushPrefs {
  static const _enabledKey = 'push_enabled';
  static const _enabledAtKey = 'push_enabled_at';
  static const _showNamesKey = 'push_show_names';
  static const _endpointKey = 'push_endpoint';
  static const _lastNotifiedKey = 'push_last_notified';

  /// Always reloads, because another isolate (the background one a push starts)
  /// may have written since this one cached the values.
  static Future<SharedPreferences> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs;
  }

  static Future<bool> isEnabled() async =>
      (await _prefs()).getBool(_enabledKey) ?? false;

  /// When notifications were switched on. Chats that were already unread by
  /// then don't produce a notification.
  static Future<DateTime> enabledAt() async {
    final ms = (await _prefs()).getInt(_enabledAtKey);
    return DateTime.fromMillisecondsSinceEpoch(ms ?? 0);
  }

  static Future<void> setEnabled(bool value) async {
    final prefs = await _prefs();
    await prefs.setBool(_enabledKey, value);
    if (value) {
      await prefs.setInt(_enabledAtKey, DateTime.now().millisecondsSinceEpoch);
    }
  }

  /// Whether notifications show who the message is from. On by default.
  static Future<bool> showNames() async =>
      (await _prefs()).getBool(_showNamesKey) ?? true;

  static Future<void> setShowNames(bool value) async =>
      (await _prefs()).setBool(_showNamesKey, value);

  /// The endpoint last handed to the server, so it can be removed again.
  static Future<String?> endpoint() async =>
      (await _prefs()).getString(_endpointKey);

  static Future<void> setEndpoint(String? value) async {
    final prefs = await _prefs();
    if (value == null) {
      await prefs.remove(_endpointKey);
    } else {
      await prefs.setString(_endpointKey, value);
    }
  }

  /// Chat id -> time (ms) of the last message we already notified about.
  static Future<Map<String, int>> lastNotified() async {
    final raw = (await _prefs()).getString(_lastNotifiedKey);
    if (raw == null) return {};
    try {
      return (jsonDecode(raw) as Map<String, dynamic>).map(
        (key, value) => MapEntry(key, (value as num).toInt()),
      );
    } catch (_) {
      return {};
    }
  }

  static Future<void> setLastNotified(Map<String, int> value) async =>
      (await _prefs()).setString(_lastNotifiedKey, jsonEncode(value));

  static Future<void> clearLastNotified() async =>
      (await _prefs()).remove(_lastNotifiedKey);
}
