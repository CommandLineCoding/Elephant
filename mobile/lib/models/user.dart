/// A user as returned by `/api/users/*` and the auth endpoints.
class UserModel {
  final String id;
  final String username;
  final String displayName;
  final String? email;
  final DateTime? createdAt;

  /// When the person last changed their username. Only their own profile has it.
  final DateTime? usernameChangedAt;

  /// The "about" text, up to 140 characters. Empty if there is none.
  final String bio;

  /// The custom status: an emoji and a few words. Both empty if there is none.
  final String statusEmoji;
  final String statusText;

  /// When the status ends, or null if it has no end.
  final DateTime? statusExpiresAt;

  UserModel({
    required this.id,
    required this.username,
    required this.displayName,
    this.email,
    this.createdAt,
    this.usernameChangedAt,
    this.bio = '',
    this.statusEmoji = '',
    this.statusText = '',
    this.statusExpiresAt,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    final username = json['username']?.toString() ?? '';
    final displayName = json['display_name']?.toString() ?? '';
    final email = json['email']?.toString();
    final status = json['status'];
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
      bio: json['bio']?.toString().trim() ?? '',
      statusEmoji: status is Map ? '${status['emoji'] ?? ''}'.trim() : '',
      statusText: status is Map ? '${status['text'] ?? ''}'.trim() : '',
      statusExpiresAt: status is Map
          ? DateTime.tryParse('${status['expires_at'] ?? ''}')?.toLocal()
          : null,
    );
  }

  /// Whether they have a custom status that hasn't ended at [now].
  bool hasStatus([DateTime? now]) =>
      (statusEmoji.isNotEmpty || statusText.isNotEmpty) &&
      (statusExpiresAt == null ||
          statusExpiresAt!.isAfter(now ?? DateTime.now()));

  /// The status as one line, like "🚴 On a ride", or null if there is none.
  String? statusLine([DateTime? now]) => hasStatus(now)
      ? [statusEmoji, statusText].where((p) => p.isNotEmpty).join(' ')
      : null;
}
