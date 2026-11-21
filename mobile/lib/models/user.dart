/// A user as returned by `/api/users/*` and the auth endpoints.
class UserModel {
  final String id;
  final String username;
  final String displayName;
  final String? email;
  final DateTime? createdAt;

  /// When the person last changed their username. Only their own profile has it.
  final DateTime? usernameChangedAt;

  UserModel({
    required this.id,
    required this.username,
    required this.displayName,
    this.email,
    this.createdAt,
    this.usernameChangedAt,
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
      usernameChangedAt: DateTime.tryParse(
        json['username_changed_at']?.toString() ?? '',
      )?.toLocal(),
    );
  }
}
