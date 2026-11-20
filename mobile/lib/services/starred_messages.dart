import 'package:flutter/foundation.dart';

import '../models/message.dart';
import 'db_services.dart';

/// A starred message, with the chat it is in and when it was starred.
class StarredEntry {
  final Message message;
  final String chatId;
  final DateTime starredAt;

  const StarredEntry({
    required this.message,
    required this.chatId,
    required this.starredAt,
  });
}

/// Where starred messages are kept. The app uses its encrypted database;
/// tests use memory.
abstract class StarredStore {
  Future<Set<String>> ids();
  Future<void> set(String chatId, String messageId, bool starred);
  Future<List<StarredEntry>> entries({String? chatId});
}

class DatabaseStarredStore implements StarredStore {
  @override
  Future<Set<String>> ids() => DatabaseHelper.instance.starredMessageIds();

  @override
  Future<void> set(String chatId, String messageId, bool starred) =>
      DatabaseHelper.instance.setMessageStarred(chatId, messageId, starred);

  @override
  Future<List<StarredEntry>> entries({String? chatId}) async {
    final rows = await DatabaseHelper.instance.starredMessages(chatId: chatId);
    return [
      for (final row in rows)
        StarredEntry(
          message: Message.fromRow(row.message),
          chatId: row.message['chat_id'] as String,
          starredAt: row.starredAt,
        ),
    ];
  }
}

/// The messages starred on this phone. Starring is private to the person:
/// nobody else, and not the server, learns of it.
class StarredMessages extends ChangeNotifier {
  StarredMessages({StarredStore? store})
    : _store = store ?? DatabaseStarredStore();

  /// The one the app uses. Tests replace it.
  static StarredMessages instance = StarredMessages();

  final StarredStore _store;
  Set<String> _ids = {};
  Future<void>? _loading;
  bool _loaded = false;

  bool isStarred(String messageId) => _ids.contains(messageId.toLowerCase());

  /// Reads which messages are starred, once.
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      _ids = {for (final id in await _store.ids()) id.toLowerCase()};
      _loaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't read starred messages: $e");
      _loading = null;
    }
  }

  /// Stars or unstars [messageId] in [chatId].
  Future<void> setStarred(String chatId, String messageId, bool starred) async {
    final id = messageId.toLowerCase();
    if (starred ? !_ids.add(id) : !_ids.remove(id)) return;
    // Listeners reload from the store, so it is written first.
    try {
      await _store.set(chatId, messageId, starred);
    } catch (e) {
      debugPrint("Couldn't save a starred message: $e");
    }
    notifyListeners();
  }

  /// A starred message is gone (deleted for everyone, or for me).
  Future<void> forget(String messageId) async {
    if (_loaded && !isStarred(messageId)) return;
    final id = messageId.toLowerCase();
    final had = _ids.remove(id);
    try {
      await _store.set('', messageId, false);
    } catch (e) {
      debugPrint("Couldn't forget a starred message: $e");
    }
    if (had) notifyListeners();
  }

  /// The starred messages that are still on this phone, newest star first.
  Future<List<StarredEntry>> entries({String? chatId}) async {
    try {
      return await _store.entries(chatId: chatId);
    } catch (e) {
      debugPrint("Couldn't list starred messages: $e");
      return const [];
    }
  }

  void clear() {
    _ids = {};
    _loaded = false;
    _loading = null;
    notifyListeners();
  }
}
