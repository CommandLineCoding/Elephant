import '../core/status_content.dart';

/// A status, as this phone knows it: someone else's (decrypted when it came) or
/// the person's own.
class StatusPost {
  final String id;
  final String authorId;

  /// What it says, or null if it couldn't be read (it was for a session this
  /// phone no longer has): such a status is kept so it isn't tried again, and
  /// never shown.
  final StatusContent? content;
  final DateTime createdAt;
  final DateTime expiresAt;
  final bool viewed;

  const StatusPost({
    required this.id,
    required this.authorId,
    required this.content,
    required this.createdAt,
    required this.expiresAt,
    this.viewed = false,
  });

  bool isExpired(DateTime now) => !expiresAt.isAfter(now);

  StatusPost copyWith({bool? viewed}) => StatusPost(
    id: id,
    authorId: authorId,
    content: content,
    createdAt: createdAt,
    expiresAt: expiresAt,
    viewed: viewed ?? this.viewed,
  );

  Map<String, Object?> toRow() => {
    'id': id,
    'author_id': authorId,
    'content': content?.encode() ?? '',
    'created_at': createdAt.millisecondsSinceEpoch,
    'expires_at': expiresAt.millisecondsSinceEpoch,
    'viewed': viewed ? 1 : 0,
  };

  factory StatusPost.fromRow(Map<String, Object?> row) {
    final raw = row['content'] as String? ?? '';
    return StatusPost(
      id: row['id'] as String,
      authorId: row['author_id'] as String,
      content: raw.isEmpty ? null : StatusContent.tryParse(raw),
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int),
      viewed: row['viewed'] == 1,
    );
  }
}

/// Someone who saw the person's status.
class StatusViewer {
  final String userId;
  final DateTime viewedAt;

  const StatusViewer({required this.userId, required this.viewedAt});
}
