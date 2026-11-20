import 'package:flutter/foundation.dart';

import '../models/chat_folder.dart';
import 'db_services.dart';

/// Where folders are kept. The app uses its encrypted database; tests use
/// memory.
abstract class ChatFolderStore {
  /// The folders, in the order they were made.
  Future<List<ChatFolder>> all();
  Future<void> save(ChatFolder folder, int position);
  Future<void> delete(String id);
}

class DatabaseChatFolderStore implements ChatFolderStore {
  @override
  Future<List<ChatFolder>> all() async {
    final rows = await DatabaseHelper.instance.chatFolders();
    return [
      for (final row in rows)
        ChatFolder(
          id: row['id'] as String,
          name: row['name'] as String,
          chatIds: DatabaseHelper.decodeChatIds(row['chat_ids'] as String),
        ),
    ];
  }

  @override
  Future<void> save(ChatFolder folder, int position) => DatabaseHelper.instance
      .saveChatFolder(folder.id, folder.name, folder.chatIds, position);

  @override
  Future<void> delete(String id) =>
      DatabaseHelper.instance.deleteChatFolder(id);
}

/// The folders on this phone. Kept private: not the server, nor anyone else,
/// learns how chats are sorted.
class ChatFolders extends ChangeNotifier {
  ChatFolders({ChatFolderStore? store})
    : _store = store ?? DatabaseChatFolderStore();

  /// The one the app uses. Tests replace it.
  static ChatFolders instance = ChatFolders();

  static const maxFolders = 10;
  static const maxNameLength = 20;

  final ChatFolderStore _store;
  List<ChatFolder> _folders = [];
  Future<void>? _loading;

  List<ChatFolder> get folders => List.unmodifiable(_folders);

  ChatFolder? byId(String id) => _folders.where((f) => f.id == id).firstOrNull;

  /// Reads the saved folders, once.
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final saved = await _store.all();
      // A folder made while this was loading is already here.
      final known = {for (final f in _folders) f.id};
      _folders = [...saved.where((f) => !known.contains(f.id)), ..._folders];
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't read chat folders: $e");
      _loading = null;
    }
  }

  /// Why [name] can't be used (for the folder [exceptId], if renaming), or
  /// null if it can.
  String? problemWith(String name, {String? exceptId}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Give the folder a name.';
    if (trimmed.length > maxNameLength) {
      return 'Keep the name to $maxNameLength characters.';
    }
    final taken = _folders.any(
      (f) => f.id != exceptId && f.name.toLowerCase() == trimmed.toLowerCase(),
    );
    return taken ? 'You already have a folder with that name.' : null;
  }

  /// Makes a folder. Returns why it couldn't, or null.
  Future<String?> create(String name, Set<String> chatIds) async {
    final problem = problemWith(name);
    if (problem != null) return problem;
    if (_folders.length >= maxFolders) {
      return 'You can have up to $maxFolders folders.';
    }
    final folder = ChatFolder(
      id: 'f${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      chatIds: _lower(chatIds),
    );
    _folders = [..._folders, folder];
    await _write(folder);
    notifyListeners();
    return null;
  }

  /// Renames a folder and sets its chats. Returns why it couldn't, or null.
  Future<String?> update(String id, String name, Set<String> chatIds) async {
    final old = byId(id);
    if (old == null) return 'That folder is gone.';
    final problem = problemWith(name, exceptId: id);
    if (problem != null) return problem;
    final folder = old.copyWith(name: name.trim(), chatIds: _lower(chatIds));
    _folders = [for (final f in _folders) f.id == id ? folder : f];
    await _write(folder);
    notifyListeners();
    return null;
  }

  Future<void> delete(String id) async {
    if (byId(id) == null) return;
    _folders = _folders.where((f) => f.id != id).toList();
    try {
      await _store.delete(id);
    } catch (e) {
      debugPrint("Couldn't delete a chat folder: $e");
    }
    notifyListeners();
  }

  /// A chat is gone (left, deleted): it leaves every folder.
  Future<void> forgetChat(String chatId) async {
    final key = chatId.toLowerCase();
    final inside = _folders.where((f) => f.chatIds.contains(key)).toList();
    if (inside.isEmpty) return;
    for (final folder in inside) {
      final next = folder.copyWith(chatIds: {...folder.chatIds}..remove(key));
      _folders = [for (final f in _folders) f.id == folder.id ? next : f];
      await _write(next);
    }
    notifyListeners();
  }

  /// Forgets every folder from memory, at sign-out.
  void reset() {
    _folders = [];
    _loading = null;
    notifyListeners();
  }

  Set<String> _lower(Set<String> ids) => {
    for (final id in ids) id.toLowerCase(),
  };

  Future<void> _write(ChatFolder folder) async {
    try {
      await _store.save(folder, _folders.indexWhere((f) => f.id == folder.id));
    } catch (e) {
      debugPrint("Couldn't save a chat folder: $e");
    }
  }
}
