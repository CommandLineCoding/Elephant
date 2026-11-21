import 'package:flutter/foundation.dart';

import '../models/inbox_item.dart';
import 'db_services.dart';

/// Where nicknames are kept. The app uses its encrypted database; tests use
/// memory.
abstract class NicknameStore {
  Future<Map<String, String>> all();
  Future<void> save(String userId, String nickname);
  Future<void> delete(String userId);
}

class DatabaseNicknameStore implements NicknameStore {
  @override
  Future<Map<String, String>> all() => DatabaseHelper.instance.nicknames();

  @override
  Future<void> save(String userId, String nickname) =>
      DatabaseHelper.instance.saveNickname(userId, nickname);

  @override
  Future<void> delete(String userId) =>
      DatabaseHelper.instance.deleteNickname(userId);
}

/// Names the person gave their contacts. Only they see them: they live on this
/// phone, in its encrypted database, and the server and the contact never learn
/// of them. Clearing one goes back to the contact's own display name.
class Nicknames extends ChangeNotifier {
  Nicknames({NicknameStore? store}) : _store = store ?? DatabaseNicknameStore();

  /// The one the app uses. Tests replace it.
  static Nicknames instance = Nicknames();

  static const maxLength = 30;

  final NicknameStore _store;
  final Map<String, String> _byUser = {};
  Future<void>? _loading;

  /// Reads the saved nicknames, once.
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final saved = await _store.all();
      // One set while this was loading wins over the saved one.
      for (final entry in saved.entries) {
        _byUser.putIfAbsent(entry.key.toLowerCase(), () => entry.value);
      }
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't read nicknames: $e");
      _loading = null;
    }
  }

  /// The nickname for [userId], or null if there isn't one.
  String? of(String userId) => _byUser[userId.toLowerCase()];

  /// What to call [userId]: the nickname, else [fallback], their own name.
  String nameFor(String userId, String fallback) => of(userId) ?? fallback;

  /// Gives [userId] a nickname, or clears it if [nickname] is blank. Extra
  /// spaces are collapsed and long ones cut to [maxLength].
  Future<void> set(String userId, String nickname) async {
    final key = userId.toLowerCase();
    final cleaned = Nicknames.clean(nickname);
    if (cleaned.isEmpty) {
      if (_byUser.remove(key) == null) return;
      notifyListeners();
      await _guard(() => _store.delete(key));
      return;
    }
    if (_byUser[key] == cleaned) return;
    _byUser[key] = cleaned;
    notifyListeners();
    await _guard(() => _store.save(key, cleaned));
  }

  /// Forgets every nickname, on sign-out.
  void reset() {
    _loading = null;
    if (_byUser.isEmpty) return;
    _byUser.clear();
    notifyListeners();
  }

  Future<void> _guard(Future<void> Function() write) async {
    try {
      await write();
    } catch (e) {
      debugPrint("Couldn't save a nickname: $e");
    }
  }

  /// [nickname] with extra spaces collapsed, cut to [maxLength] characters.
  static String clean(String nickname) {
    final spaced = nickname.trim().split(RegExp(r'\s+')).join(' ');
    final runes = spaced.runes.toList();
    return runes.length <= maxLength
        ? spaced
        : String.fromCharCodes(runes.take(maxLength)).trim();
  }
}

extension NicknamedChat on InboxItem {
  /// What to show for this chat: a direct chat's contact by the nickname if
  /// there is one. Groups keep their own name.
  String get shownTitle =>
      isGroup ? title : Nicknames.instance.nameFor(id, title);
}
