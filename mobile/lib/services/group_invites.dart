import '../services/api_services.dart';

/// A group's invite link, as an admin sees it.
class GroupInvite {
  final String? code;
  final bool requireApproval;

  const GroupInvite({this.code, this.requireApproval = false});

  bool get enabled => code != null;

  factory GroupInvite.fromJson(Map<String, dynamic> json) => GroupInvite(
    code: json['enabled'] == true && json['code'] is String
        ? json['code'] as String
        : null,
    requireApproval: json['require_approval'] == true,
  );
}

/// What someone sees before joining with a link: the group's name and size.
class InvitePreview {
  final String groupId;
  final String name;
  final int memberCount;
  final bool requireApproval;
  final bool alreadyMember;
  final bool alreadyRequested;

  const InvitePreview({
    required this.groupId,
    required this.name,
    required this.memberCount,
    required this.requireApproval,
    required this.alreadyMember,
    required this.alreadyRequested,
  });

  factory InvitePreview.fromJson(Map<String, dynamic> json) => InvitePreview(
    groupId: '${json['group_id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    memberCount: json['member_count'] is int ? json['member_count'] as int : 0,
    requireApproval: json['require_approval'] == true,
    alreadyMember: json['already_member'] == true,
    alreadyRequested: json['already_requested'] == true,
  );
}

/// How using a link ended: `joined`, `requested` or `alreadyMember`.
enum JoinOutcome { joined, requested, alreadyMember }

/// Someone waiting to be let into a group.
class JoinRequest {
  final String userId;
  final String username;
  final String displayName;

  const JoinRequest({
    required this.userId,
    required this.username,
    required this.displayName,
  });

  factory JoinRequest.fromJson(Map<String, dynamic> json) => JoinRequest(
    userId: '${json['user_id'] ?? ''}',
    username: '${json['username'] ?? ''}',
    displayName: '${json['display_name'] ?? ''}',
  );

  String get title => displayName.isEmpty ? username : displayName;
}

/// The server calls behind invite links. A class so a test can stand in for
/// the server.
abstract class GroupInvitesApi {
  Future<GroupInvite> get(String groupId);
  Future<GroupInvite> set(String groupId, {bool? requireApproval, bool reset});
  Future<void> turnOff(String groupId);
  Future<List<JoinRequest>> requests(String groupId);
  Future<void> decide(String groupId, String userId, {required bool approve});
  Future<InvitePreview> preview(String code);
  Future<({JoinOutcome outcome, String groupId})> join(String code);
}

class ServerGroupInvitesApi implements GroupInvitesApi {
  const ServerGroupInvitesApi();

  @override
  Future<GroupInvite> get(String groupId) async => GroupInvite.fromJson(
    ApiService.dataMap((await ApiService().getInvite(groupId)).data),
  );

  @override
  Future<GroupInvite> set(
    String groupId, {
    bool? requireApproval,
    bool reset = false,
  }) async => GroupInvite.fromJson(
    ApiService.dataMap(
      (await ApiService().setInvite(groupId, {
        if (requireApproval != null) 'require_approval': requireApproval,
        if (reset) 'reset': true,
      })).data,
    ),
  );

  @override
  Future<void> turnOff(String groupId) async {
    await ApiService().deleteInvite(groupId);
  }

  @override
  Future<List<JoinRequest>> requests(String groupId) async => [
    for (final j in ApiService.dataList(
      (await ApiService().getJoinRequests(groupId)).data,
    ))
      JoinRequest.fromJson(Map<String, dynamic>.from(j)),
  ];

  @override
  Future<void> decide(
    String groupId,
    String userId, {
    required bool approve,
  }) async {
    await ApiService().decideJoinRequest(groupId, userId, approve: approve);
  }

  @override
  Future<InvitePreview> preview(String code) async => InvitePreview.fromJson(
    ApiService.dataMap((await ApiService().getInvitePreview(code)).data),
  );

  @override
  Future<({JoinOutcome outcome, String groupId})> join(String code) async {
    final data = ApiService.dataMap((await ApiService().joinInvite(code)).data);
    final outcome = switch (data['status']) {
      'joined' => JoinOutcome.joined,
      'requested' => JoinOutcome.requested,
      _ => JoinOutcome.alreadyMember,
    };
    return (outcome: outcome, groupId: '${data['group_id'] ?? ''}');
  }
}
