import 'package:flutter/foundation.dart';

import '../models/broadcast_list.dart';
import 'db_services.dart';

/// Where broadcast lists are kept. The app uses its encrypted database; tests
/// use memory.
abstract class BroadcastListStore {
  /// The lists, in the order they were made.
  Future<List<BroadcastList>> all();
  Future<void> save(BroadcastList list, int position);
  Future<void> delete(String id);
}

class DatabaseBroadcastListStore implements BroadcastListStore {
  @override
  Future<List<BroadcastList>> all() async {
    final rows = await DatabaseHelper.instance.broadcastLists();
    return [
      for (final row in rows)
        BroadcastList(
          id: row['id'] as String,
          name: row['name'] as String,
          members: BroadcastList.decodeMembers(row['members'] as String),
        ),
    ];
  }

  @override
  Future<void> save(BroadcastList list, int position) =>
      DatabaseHelper.instance.saveBroadcastList(
        list.id,
        list.name,
        BroadcastList.encodeMembers(list.members),
        position,
      );

  @override
  Future<void> delete(String id) =>
      DatabaseHelper.instance.deleteBroadcastList(id);
}

/// The broadcast lists on this phone.
class BroadcastLists extends ChangeNotifier {
  BroadcastLists({BroadcastListStore? store})
    : _store = store ?? DatabaseBroadcastListStore();

  /// The one the app uses. Tests replace it.
  static BroadcastLists instance = BroadcastLists();

  static const maxLists = 20;
  static const maxNameLength = 30;

  /// A message to a list is sent to each person in turn, so a list is kept to a
  /// size that finishes quickly.
  static const maxMembers = 50;

  final BroadcastListStore _store;
  List<BroadcastList> _lists = [];
  Future<void>? _loading;

  List<BroadcastList> get lists => List.unmodifiable(_lists);

  BroadcastList? byId(String id) => _lists.where((l) => l.id == id).firstOrNull;

  /// Reads the saved lists, once.
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final saved = await _store.all();
      // A list made while this was loading is already here.
      final known = {for (final l in _lists) l.id};
      _lists = [...saved.where((l) => !known.contains(l.id)), ..._lists];
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't read broadcast lists: $e");
      _loading = null;
    }
  }

  /// Why [name] and [members] can't make a list (the list [exceptId], if
  /// editing it), or null if they can.
  String? problemWith(
    String name,
    List<BroadcastMember> members, {
    String? exceptId,
  }) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'Give the list a name.';
    if (trimmed.length > maxNameLength) {
      return 'Keep the name to $maxNameLength characters.';
    }
    if (members.isEmpty) return 'Pick at least one person.';
    if (members.length > maxMembers) {
      return 'A list can have up to $maxMembers people.';
    }
    final taken = _lists.any(
      (l) => l.id != exceptId && l.name.toLowerCase() == trimmed.toLowerCase(),
    );
    return taken ? 'You already have a list with that name.' : null;
  }

  /// Makes a list. Returns the list, or why it couldn't be made.
  Future<(BroadcastList?, String?)> create(
    String name,
    List<BroadcastMember> members,
  ) async {
    final problem = problemWith(name, members);
    if (problem != null) return (null, problem);
    if (_lists.length >= maxLists) {
      return (null, 'You can have up to $maxLists lists.');
    }
    final list = BroadcastList(
      id: 'b${DateTime.now().microsecondsSinceEpoch}',
      name: name.trim(),
      members: _unique(members),
    );
    _lists = [..._lists, list];
    await _write(list);
    notifyListeners();
    return (list, null);
  }

  /// Renames a list and sets its people. Returns why it couldn't, or null.
  Future<String?> update(
    String id,
    String name,
    List<BroadcastMember> members,
  ) async {
    final old = byId(id);
    if (old == null) return 'That list is gone.';
    final problem = problemWith(name, members, exceptId: id);
    if (problem != null) return problem;
    final list = old.copyWith(name: name.trim(), members: _unique(members));
    _lists = [for (final l in _lists) l.id == id ? list : l];
    await _write(list);
    notifyListeners();
    return null;
  }

  Future<void> delete(String id) async {
    if (byId(id) == null) return;
    _lists = _lists.where((l) => l.id != id).toList();
    try {
      await _store.delete(id);
    } catch (e) {
      debugPrint("Couldn't delete a broadcast list: $e");
    }
    notifyListeners();
  }

  /// Someone is gone from the person's chats (blocked, say): they leave every
  /// list, and a list left with nobody goes too.
  Future<void> forgetPerson(String userId) async {
    final key = userId.toLowerCase();
    for (final list in List.of(_lists)) {
      if (!list.members.any((m) => m.id.toLowerCase() == key)) continue;
      final rest = [
        for (final m in list.members)
          if (m.id.toLowerCase() != key) m,
      ];
      if (rest.isEmpty) {
        await delete(list.id);
        continue;
      }
      final next = list.copyWith(members: rest);
      _lists = [for (final l in _lists) l.id == list.id ? next : l];
      await _write(next);
    }
    notifyListeners();
  }

  /// Forgets every list from memory, at sign-out.
  void reset() {
    _lists = [];
    _loading = null;
    notifyListeners();
  }

  List<BroadcastMember> _unique(List<BroadcastMember> members) {
    final seen = <String>{};
    return [
      for (final m in members)
        if (seen.add(m.id.toLowerCase())) m,
    ];
  }

  Future<void> _write(BroadcastList list) async {
    final position = _lists.indexWhere((l) => l.id == list.id);
    try {
      await _store.save(list, position);
    } catch (e) {
      debugPrint("Couldn't save a broadcast list: $e");
    }
  }
}
