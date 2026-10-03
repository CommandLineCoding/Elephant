/// A group as returned by `GET /api/groups` and `GET /api/groups/{id}`.
class Group {
  final String id;
  final String name;
  final String createdBy;
  final DateTime createdAt;

  Group({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdAt,
  });

  factory Group.fromJson(Map<String, dynamic> json) {
    return Group(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      createdBy: json['created_by']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }
}

/// A row of `GET /api/groups/{id}/members`.
class GroupMember {
  final String userId;
  final String username;
  final String displayName;
  final String role;
  final DateTime? joinedAt;

  GroupMember({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.role,
    this.joinedAt,
  });

  bool get isAdmin => role == 'admin';

  factory GroupMember.fromJson(Map<String, dynamic> json) {
    final username = json['username']?.toString() ?? '';
    final displayName = json['display_name']?.toString() ?? '';
    return GroupMember(
      userId: json['user_id'].toString(),
      username: username,
      displayName: displayName.isNotEmpty ? displayName : username,
      role: json['role']?.toString() ?? 'member',
      joinedAt: DateTime.tryParse(
        json['joined_at']?.toString() ?? '',
      )?.toLocal(),
    );
  }
}
