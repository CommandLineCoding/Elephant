import 'package:flutter/foundation.dart';

import 'db_services.dart';

/// What was typed in a chat's message box but not sent, and the message it
/// was going to reply to.
class Draft {
  final String text;
  final String? replyToId;

  const Draft(this.text, {this.replyToId});
}

/// Where drafts are kept. The app uses its encrypted database; tests use
/// memory.
abstract class DraftStore {
  Future<Map<String, Draft>> all();
  Future<void> save(String chatId, Draft draft);
  Future<void> delete(String chatId);
}

class DatabaseDraftStore implements DraftStore {
  @override
  Future<Map<String, Draft>> all() async {
    final rows = await DatabaseHelper.instance.drafts();
    return {
      for (final row in rows)
        row['chat_id'] as String: Draft(
          row['text'] as String,
          replyToId: row['reply_to_id'] as String?,
        ),
    };
  }

  @override
  Future<void> save(String chatId, Draft draft) =>
      DatabaseHelper.instance.saveDraft(chatId, draft.text, draft.replyToId);

  @override
  Future<void> delete(String chatId) =>
      DatabaseHelper.instance.deleteDraft(chatId);
}

/// The unsent drafts on this phone, one per chat. Only kept here: nobody
/// else, and not the server, ever sees them.
class Drafts extends ChangeNotifier {
  Drafts({DraftStore? store}) : _store = store ?? DatabaseDraftStore();

  /// The one the app uses. Tests replace it.
  static Drafts instance = Drafts();

  final DraftStore _store;
  Map<String, Draft> _drafts = {};
  Future<void>? _loading;

  /// Reads the saved drafts, once.
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final saved = await _store.all();
      // Whatever was typed while this was loading is newer.
      _drafts = {...saved, ..._drafts};
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't read drafts: $e");
      _loading = null;
    }
  }

  /// The draft of [chatId], or null if there is none.
  Draft? of(String chatId) => _drafts[chatId.toLowerCase()];

  /// Keeps [text] as the draft of [chatId]. Nothing but spaces is no draft.
  Future<void> save(String chatId, String text, {String? replyToId}) async {
    if (text.trim().isEmpty) return clear(chatId);
    final key = chatId.toLowerCase();
    final old = _drafts[key];
    if (old != null && old.text == text && old.replyToId == replyToId) return;
    final draft = Draft(text, replyToId: replyToId);
    _drafts[key] = draft;
    try {
      await _store.save(key, draft);
    } catch (e) {
      debugPrint("Couldn't save a draft: $e");
    }
    notifyListeners();
  }

  /// Drops the draft of [chatId], e.g. once it is sent.
  Future<void> clear(String chatId) async {
    final key = chatId.toLowerCase();
    // The store is asked even when this doesn't know the draft yet, since it
    // may not have been read.
    final had = _drafts.remove(key) != null;
    try {
      await _store.delete(key);
    } catch (e) {
      debugPrint("Couldn't delete a draft: $e");
    }
    if (had) notifyListeners();
  }

  /// Forgets every draft from memory, at sign-out.
  void reset() {
    _drafts = {};
    _loading = null;
    notifyListeners();
  }
}
