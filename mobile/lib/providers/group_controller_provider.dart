import 'package:flutter/widgets.dart';
import 'package:mobile/models/group.dart';
import 'package:mobile/services/api_services.dart';

/// Creates groups (`POST /api/groups`) and adds the initial members.
class GroupController extends ChangeNotifier {
  final ApiService _api = ApiService();

  bool _isLoading = false;
  bool get isLoading => _isLoading;

  String? lastError;

  /// Members that couldn't be added during the last [createGroup] call.
  List<String> failedMemberIds = [];

  Future<Group?> createGroup({
    required String groupName,
    required List<String> memberIds,
  }) async {
    if (_isLoading) return null;
    _isLoading = true;
    lastError = null;
    failedMemberIds = [];
    notifyListeners();

    try {
      final res = await _api.createGroup(groupName.trim());
      final group = Group.fromJson(ApiService.dataMap(res.data));

      final results = await Future.wait(
        memberIds.map((userId) async {
          try {
            await _api.addGroupMember(group.id, userId);
            return null;
          } catch (e) {
            debugPrint("Failed to add $userId to ${group.id}: $e");
            return userId;
          }
        }),
      );
      failedMemberIds = results.whereType<String>().toList();
      return group;
    } catch (e) {
      lastError = ApiService.errorMessage(
        e,
        fallback: "Couldn't create the group.",
      );
      return null;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void clearGroupData() {
    _isLoading = false;
    lastError = null;
    failedMemberIds = [];
    notifyListeners();
  }
}
