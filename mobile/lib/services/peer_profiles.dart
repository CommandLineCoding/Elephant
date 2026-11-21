import 'package:flutter/foundation.dart';

import '../models/user.dart';
import 'api_services.dart';

/// What people's profiles say (their about text and custom status), loaded when
/// a chat or contact page needs it and kept for a few minutes. These are public
/// to anyone who can look the person up.
class PeerProfiles extends ChangeNotifier {
  PeerProfiles({
    Future<UserModel?> Function(String userId)? fetch,
    DateTime Function()? clock,
  }) : _fetch = fetch ?? _fromServer,
       _clock = clock ?? DateTime.now;

  /// The one the app uses. Tests replace it.
  static PeerProfiles instance = PeerProfiles();

  static const keepFor = Duration(minutes: 5);

  final Future<UserModel?> Function(String userId) _fetch;
  final DateTime Function() _clock;
  final Map<String, ({UserModel user, DateTime at})> _known = {};
  final Map<String, Future<void>> _loading = {};

  static Future<UserModel?> _fromServer(String userId) async {
    final res = await ApiService().getUser(userId);
    return UserModel.fromJson(ApiService.dataMap(res.data));
  }

  /// What we know of [userId], or null if not loaded (or they are gone).
  UserModel? of(String userId) => _known[userId.toLowerCase()]?.user;

  /// Loads [userId]'s profile unless it was loaded in the last few minutes.
  /// Quiet if it fails: the page shows what it has.
  Future<void> load(String userId) {
    final key = userId.toLowerCase();
    final known = _known[key];
    if (known != null && _clock().difference(known.at) < keepFor) {
      return Future.value();
    }
    return _loading[key] ??= _read(key).whenComplete(() {
      // In braces: a callback that returns the removed future would make this
      // wait for itself.
      _loading.remove(key);
    });
  }

  Future<void> _read(String key) async {
    try {
      final user = await _fetch(key);
      if (user == null) return;
      _known[key] = (user: user, at: _clock());
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't load a profile: $e");
    }
  }

  /// Forgets everyone, on sign-out.
  void reset() {
    _known.clear();
    _loading.clear();
    notifyListeners();
  }
}
