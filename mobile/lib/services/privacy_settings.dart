import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_services.dart';

/// Who may see or do something: anyone, people the person chats with, or no one.
enum Audience {
  everyone('everyone', 'Everyone'),
  contacts('contacts', 'People I chat with'),
  nobody('nobody', 'Nobody');

  final String wire;
  final String label;
  const Audience(this.wire, this.label);

  static Audience from(Object? wire, Audience fallback) {
    for (final a in values) {
      if (a.wire == wire) return a;
    }
    return fallback;
  }
}

/// The server calls behind the settings. A class so a test can stand in for
/// the server.
abstract class PrivacyApi {
  Future<Map<String, dynamic>> load();
  Future<Map<String, dynamic>> save(Map<String, dynamic> change);
}

class ServerPrivacyApi implements PrivacyApi {
  const ServerPrivacyApi();

  @override
  Future<Map<String, dynamic>> load() async =>
      ApiService.dataMap((await ApiService().getSettings()).data);

  @override
  Future<Map<String, dynamic>> save(Map<String, dynamic> change) async =>
      ApiService.dataMap((await ApiService().updateSettings(change)).data);
}

/// What the person lets others see and do. The server enforces it, so this is
/// only the copy the app shows and acts on: read receipts are not sent, and
/// others' are not shown, while that is off. The read-receipts switch is also
/// kept on this phone, so it applies from the first moment after a restart,
/// before the server has answered.
class PrivacySettings extends ChangeNotifier {
  PrivacySettings({this._api = const ServerPrivacyApi()});

  /// The app's settings. Not final so a test can swap in its own.
  static PrivacySettings instance = PrivacySettings();

  static const _receiptsKey = 'read_receipts';

  final PrivacyApi _api;

  Audience onlineStatus = Audience.contacts;
  bool readReceipts = true;
  Audience groupAdds = Audience.everyone;

  /// Reads the saved read-receipts switch. Call it once at startup.
  Future<void> loadLocal() async {
    final prefs = await SharedPreferences.getInstance();
    readReceipts = prefs.getBool(_receiptsKey) ?? true;
    notifyListeners();
  }

  /// Asks the server for the settings. Keeps what it has if that fails.
  Future<void> refresh() async {
    try {
      _apply(await _api.load());
      await _remember();
    } catch (e) {
      debugPrint("Couldn't load privacy settings: $e");
    }
  }

  /// Forgets everything, on sign-out.
  void reset() {
    onlineStatus = Audience.contacts;
    readReceipts = true;
    groupAdds = Audience.everyone;
    SharedPreferences.getInstance().then((p) => p.remove(_receiptsKey));
    notifyListeners();
  }

  Future<void> setOnlineStatus(Audience value) =>
      _change({'online_status': value.wire}, () => onlineStatus = value);

  Future<void> setReadReceipts(bool value) =>
      _change({'read_receipts': value}, () => readReceipts = value);

  Future<void> setGroupAdds(Audience value) =>
      _change({'group_adds': value.wire}, () => groupAdds = value);

  /// Shows [apply] at once, then saves it. If the server refuses, the old
  /// value comes back and the error is thrown for the screen to show.
  Future<void> _change(Map<String, dynamic> change, VoidCallback apply) async {
    final (status, receipts, adds) = (onlineStatus, readReceipts, groupAdds);
    apply();
    notifyListeners();
    try {
      _apply(await _api.save(change));
      await _remember();
    } catch (e) {
      onlineStatus = status;
      readReceipts = receipts;
      groupAdds = adds;
      notifyListeners();
      await _remember();
      rethrow;
    }
  }

  void _apply(Map<String, dynamic> data) {
    onlineStatus = Audience.from(data['online_status'], onlineStatus);
    groupAdds = Audience.from(data['group_adds'], groupAdds);
    if (data['read_receipts'] is bool) readReceipts = data['read_receipts'];
    notifyListeners();
  }

  Future<void> _remember() async => (await SharedPreferences.getInstance())
      .setBool(_receiptsKey, readReceipts);
}
