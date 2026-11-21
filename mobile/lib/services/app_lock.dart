import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks the phone to confirm it is its owner: a fingerprint or face, or the
/// screen lock's PIN, pattern or password. A class so a test can stand in for
/// the phone.
abstract class Authenticator {
  /// Whether the phone has a fingerprint or screen lock to ask with.
  Future<bool> isSupported();

  /// Shows the phone's own prompt. True only if the person passed it.
  Future<bool> authenticate(String reason);
}

class DeviceAuthenticator implements Authenticator {
  final _auth = LocalAuthentication();

  @override
  Future<bool> isSupported() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      debugPrint("Couldn't check for a screen lock: $e");
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason);
    } catch (e) {
      debugPrint("Authentication failed: $e");
      return false;
    }
  }
}

/// Locks the app behind the phone's own fingerprint, face or screen lock.
/// This keeps someone who picks up an unlocked phone out of the chats. It adds
/// no encryption: the chat database is already encrypted.
class AppLock extends ChangeNotifier {
  AppLock({Authenticator? authenticator, DateTime Function()? clock})
    : _authenticator = authenticator ?? DeviceAuthenticator(),
      _clock = clock ?? DateTime.now;

  /// The app's lock. Not final so a test can swap in its own.
  static AppLock instance = AppLock();

  /// How long the app may be out of sight before it locks.
  static const timeouts = [
    Duration.zero,
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 30),
  ];

  static const _enabledKey = 'app_lock';
  static const _timeoutKey = 'app_lock_after_seconds';

  final Authenticator _authenticator;
  final DateTime Function() _clock;

  bool _enabled = false;
  Duration _lockAfter = Duration.zero;
  bool _locked = false;
  DateTime? _leftAt;
  bool _asking = false;

  /// Whether the call screen is showing. It stays usable while the app is
  /// locked, so a call can be answered; leaving it shows the lock.
  final callScreenOpen = ValueNotifier<bool>(false);

  bool get enabled => _enabled;
  Duration get lockAfter => _lockAfter;
  bool get locked => _enabled && _locked;

  /// True while the phone's prompt is open.
  bool get asking => _asking;

  /// Reads the setting. The app starts locked if it is on. Call it once at
  /// startup.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? false;
    final seconds = prefs.getInt(_timeoutKey) ?? 0;
    _lockAfter = timeouts.firstWhere(
      (t) => t.inSeconds == seconds,
      orElse: () => Duration.zero,
    );
    _locked = _enabled;
    notifyListeners();
  }

  /// Turns the lock on or off. Either way the phone asks first, so a stranger
  /// holding an unlocked phone can't switch it off. Returns an error to show,
  /// or null on success.
  Future<String?> setEnabled(bool on) async {
    if (on == _enabled) return null;
    if (on && !await _authenticator.isSupported()) {
      return 'Set a screen lock, fingerprint or face on your phone first. '
          'Elephant uses it to unlock.';
    }
    if (!await _ask(on ? 'Turn on app lock' : 'Turn off app lock')) {
      return on ? 'App lock stayed off.' : 'App lock stayed on.';
    }
    _enabled = on;
    _locked = false;
    _leftAt = null;
    await (await SharedPreferences.getInstance()).setBool(_enabledKey, on);
    notifyListeners();
    return null;
  }

  Future<void> setLockAfter(Duration after) async {
    _lockAfter = after;
    await (await SharedPreferences.getInstance()).setInt(
      _timeoutKey,
      after.inSeconds,
    );
    notifyListeners();
  }

  /// The app left the screen.
  void didLeave() {
    // The phone's own prompt takes the app off the screen for a moment.
    if (_asking) return;
    _leftAt = _clock();
  }

  /// The app is back on the screen. Locks it if it was away for long enough.
  void didReturn() {
    final left = _leftAt;
    _leftAt = null;
    if (!_enabled || _locked || _asking || left == null) return;
    if (_clock().difference(left) >= _lockAfter) {
      _locked = true;
      notifyListeners();
    }
  }

  /// Shows the phone's prompt and unlocks if it is passed. A phone that no
  /// longer has a screen lock can't ask, and the app doesn't keep its owner
  /// out for good: it unlocks.
  Future<bool> unlock() async {
    if (!locked) return true;
    if (!await _authenticator.isSupported()) {
      _locked = false;
      notifyListeners();
      return true;
    }
    if (!await _ask('Unlock Elephant')) return false;
    _locked = false;
    notifyListeners();
    return true;
  }

  Future<bool> _ask(String reason) async {
    if (_asking) return false;
    _asking = true;
    try {
      return await _authenticator.authenticate(reason);
    } finally {
      _asking = false;
      // Coming back from the prompt isn't coming back to the app.
      _leftAt = null;
    }
  }
}
