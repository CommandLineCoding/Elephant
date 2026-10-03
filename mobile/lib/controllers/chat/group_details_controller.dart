import 'package:flutter/material.dart';
import '../../models/group.dart';
import '../../services/api_services.dart';

/// Member lists, roles and admin actions for groups.
class GroupDetailsController extends ChangeNotifier {
  final ApiService _api = ApiService();

  String? _currentGroupId;
  List<GroupMember> currentGroupMembers = [];
  bool isLoadingDetails = false;

  /// user ID → display name, across every group loaded this session.
  final Map<String, String> userCache = {};
  final Set<String> _fetchedGroups = {};

  bool hasFetchedGroup(String groupId) => _fetchedGroups.contains(groupId);

  String nameFor(String userId, {String fallback = 'Member'}) {
    return userCache[userId.trim().toLowerCase()] ?? fallback;
  }

  bool isAdmin(String? userId) {
    if (userId == null) return false;
    return currentGroupMembers.any(
      (m) => m.userId.toLowerCase() == userId.toLowerCase() && m.isAdmin,
    );
  }

  Future<void> fetchGroupMembers(String groupId) async {
    if (_currentGroupId != groupId) {
      currentGroupMembers = [];
      _currentGroupId = groupId;
    }
    isLoadingDetails = true;
    notifyListeners();

    try {
      final res = await _api.getGroupMembers(groupId);
      currentGroupMembers = ApiService.dataList(res.data)
          .map((json) => GroupMember.fromJson(Map<String, dynamic>.from(json)))
          .toList();
      _remember(currentGroupMembers);
      _fetchedGroups.add(groupId);
    } catch (e) {
      debugPrint("Error fetching members: $e");
    } finally {
      isLoadingDetails = false;
      notifyListeners();
    }
  }

  /// Warms [userCache] so inbox previews can show sender names.
  Future<void> preloadGroupMembers(String groupId) async {
    if (_fetchedGroups.contains(groupId)) return;
    _fetchedGroups.add(groupId);

    try {
      final res = await _api.getGroupMembers(groupId);
      _remember(
        ApiService.dataList(
          res.data,
        ).map((json) => GroupMember.fromJson(Map<String, dynamic>.from(json))),
      );
      notifyListeners();
    } catch (e) {
      _fetchedGroups.remove(groupId);
      debugPrint("Failed to preload members for $groupId: $e");
    }
  }

  void _remember(Iterable<GroupMember> members) {
    for (final m in members) {
      userCache[m.userId.toLowerCase()] = m.displayName;
    }
  }

  /// The admin actions below return an error message, or null on success.

  Future<String?> addMember(String groupId, String userId) async {
    try {
      await _api.addGroupMember(groupId, userId);
      await fetchGroupMembers(groupId);
      return null;
    } catch (e) {
      return ApiService.errorMessage(e, fallback: "Couldn't add this member.");
    }
  }

  Future<String?> removeMember(String groupId, String userId) async {
    try {
      await _api.removeGroupMember(groupId, userId);
      currentGroupMembers.removeWhere((m) => m.userId == userId);
      notifyListeners();
      return null;
    } catch (e) {
      return ApiService.errorMessage(
        e,
        fallback: "Couldn't remove this member.",
      );
    }
  }

  Future<String?> renameGroup(String groupId, String newName) async {
    try {
      await _api.renameGroup(groupId, newName.trim());
      return null;
    } catch (e) {
      return ApiService.errorMessage(e, fallback: "Couldn't rename the group.");
    }
  }

  Future<String?> leaveGroup(String groupId) async {
    try {
      await _api.leaveGroup(groupId);
      _fetchedGroups.remove(groupId);
      if (_currentGroupId == groupId) currentGroupMembers = [];
      notifyListeners();
      return null;
    } catch (e) {
      return ApiService.errorMessage(e, fallback: "Couldn't leave the group.");
    }
  }

  void clearCache() {
    currentGroupMembers = [];
    _currentGroupId = null;
    userCache.clear();
    _fetchedGroups.clear();
    isLoadingDetails = false;
    notifyListeners();
  }
}
