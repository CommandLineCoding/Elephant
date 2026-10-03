/// A user as returned by `/api/users/*` and the auth endpoints.
class UserModel {
  final String id;
  final String username;
  final String displayName;
  final String? email;
  final DateTime? createdAt;

  UserModel({
    required this.id,
    required this.username,
    required this.displayName,
    this.email,
    this.createdAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    final username = json['username']?.toString() ?? '';
    final displayName = json['display_name']?.toString() ?? '';
    final email = json['email']?.toString();
    return UserModel(
      id: json['id']?.toString() ?? '',
      username: username,
      displayName: displayName.isNotEmpty ? displayName : username,
      email: (email == null || email.isEmpty) ? null : email,
      createdAt: DateTime.tryParse(
        json['created_at']?.toString() ?? '',
      )?.toLocal(),
    );
  }
}
