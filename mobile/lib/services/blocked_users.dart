import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:mobile/services/api_services.dart';
import 'package:mobile/services/broadcast_lists.dart';

/// Someone the signed-in user blocked.
class BlockedUser {
  final String id;
  final String username;
  final String displayName;

  const BlockedUser({
    required this.id,
    required this.username,
    required this.displayName,
  });

  factory BlockedUser.fromJson(Map<String, dynamic> json) {
    final username = json['username']?.toString() ?? '';
    final displayName = json['display_name']?.toString() ?? '';
    return BlockedUser(
      id: json['id'].toString(),
      username: username,
      displayName: displayName.isEmpty ? username : displayName,
    );
  }
}

/// The people the signed-in user blocked. A blocked person isn't told; their
/// direct messages, typing and read receipts simply stop arriving.
class BlockedUsers extends ChangeNotifier {
  BlockedUsers._();

  static final BlockedUsers instance = BlockedUsers._();

  List<BlockedUser> _users = [];
  bool _loaded = false;

  List<BlockedUser> get users => List.unmodifiable(_users);
  bool get loaded => _loaded;

  bool isBlocked(String userId) {
    final id = userId.trim().toLowerCase();
    return _users.any((u) => u.id.toLowerCase() == id);
  }

  /// Loads the list from the server. On failure the last list is kept.
  Future<void> load() async {
    try {
      final res = await ApiService().listBlockedUsers();
      _users = ApiService.dataList(
        res.data,
      ).map((j) => BlockedUser.fromJson(Map<String, dynamic>.from(j))).toList();
      _loaded = true;
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't load blocked users: $e");
    }
  }

  /// Returns an error message, or null on success.
  Future<String?> block(BlockedUser user) async {
    try {
      await ApiService().blockUser(user.id);
      if (!isBlocked(user.id)) _users = [user, ..._users];
      notifyListeners();
      // Blocked people are dropped from broadcast lists: nothing sent to a list
      // would reach them.
      unawaited(BroadcastLists.instance.forgetPerson(user.id));
      return null;
    } catch (e) {
      return ApiService.errorMessage(e, fallback: "Couldn't block them.");
    }
  }

  /// Returns an error message, or null on success.
  Future<String?> unblock(String userId) async {
    try {
      await ApiService().unblockUser(userId);
      final id = userId.toLowerCase();
      _users = _users.where((u) => u.id.toLowerCase() != id).toList();
      notifyListeners();
      return null;
    } catch (e) {
      return ApiService.errorMessage(e, fallback: "Couldn't unblock them.");
    }
  }

  @visibleForTesting
  void debugSetUsers(List<BlockedUser> users) {
    _users = users;
    _loaded = true;
    notifyListeners();
  }

  /// Forgets the list, on sign-out.
  void clear() {
    _users = [];
    _loaded = false;
    notifyListeners();
  }
}
