import '../core/constants.dart';

class QuotedMessage {
  final String id;
  final String senderId;
  final String senderDisplayName;
  final String content;

  QuotedMessage({
    required this.id,
    required this.senderId,
    required this.senderDisplayName,
    required this.content,
  });

  factory QuotedMessage.fromJson(Map<String, dynamic> json) {
    return QuotedMessage(
      id: json['id']?.toString() ?? '',
      senderId: json['sender_id']?.toString() ?? '',
      senderDisplayName:
          json['sender_display_name']?.toString() ??
          json['sender_name']?.toString() ??
          '',
      content: json['content']?.toString() ?? '',
    );
  }

  QuotedMessage copyWith({String? content, String? senderDisplayName}) {
    return QuotedMessage(
      id: id,
      senderId: senderId,
      senderDisplayName: senderDisplayName ?? this.senderDisplayName,
      content: content ?? this.content,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sender_id': senderId,
    'sender_display_name': senderDisplayName,
    'content': content,
  };
}

class Message {
  final String id;

  /// The author's user ID, or `'me'` for messages written on this device.
  final String senderId;
  final String receiverId;
  final String content;
  final DateTime createdAt;
  final bool isRead;
  final String? replyToMessageId;
  final QuotedMessage? quotedMessage;
  final String syncStatus;
  final DateTime? editedAt;

  Message({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.content,
    required this.createdAt,
    required this.isRead,
    this.replyToMessageId,
    this.quotedMessage,
    this.syncStatus = 'synced',
    this.editedAt,
  });

  bool get isEdited => editedAt != null;
  bool get isPending => syncStatus == 'pending';

  bool isFrom(String? currentUserId) {
    final sender = senderId.trim().toLowerCase();
    return sender == 'me' ||
        (currentUserId != null && sender == currentUserId.trim().toLowerCase());
  }

  bool canEdit(String? currentUserId) {
    return isFrom(currentUserId) &&
        !isPending &&
        DateTime.now().difference(createdAt) < ServerLimits.editWindow;
  }

  static DateTime? _parseDate(dynamic value) {
    if (value == null) return null;
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    final text = value.toString();
    if (text.isEmpty || text.startsWith('0001-01-01')) return null;
    return DateTime.tryParse(text)?.toLocal();
  }

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id:
          json['client_message_id']?.toString() ??
          json['message_id']?.toString() ??
          json['id']?.toString() ??
          '',
      senderId: json['sender_id']?.toString() ?? '',
      receiverId: json['receiver_id']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      createdAt:
          _parseDate(json['created_at'] ?? json['timestamp']) ?? DateTime.now(),
      isRead: json['is_read'] == 1 || json['is_read'] == true,
      replyToMessageId: _nonEmpty(
        json['reply_to_message_id'] ?? json['reply_to_id'],
      ),
      quotedMessage: json['quoted_message'] is Map
          ? QuotedMessage.fromJson(
              Map<String, dynamic>.from(json['quoted_message']),
            )
          : null,
      syncStatus: json['sync_status']?.toString() ?? 'synced',
      editedAt: _parseDate(json['edited_at']),
    );
  }

  /// Builds a message from a row of the local `messages` table.
  factory Message.fromRow(Map<String, dynamic> row) {
    return Message(
      id: row['id'] as String,
      senderId: row['sender_id'] as String,
      receiverId: row['chat_id'] as String? ?? '',
      content: row['content'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      isRead: (row['is_read'] as int? ?? 0) == 1,
      replyToMessageId: row['reply_to_id'] as String?,
      syncStatus: row['sync_status'] as String? ?? 'synced',
      editedAt: row['edited_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['edited_at'] as int)
          : null,
    );
  }

  static String? _nonEmpty(dynamic value) {
    final text = value?.toString();
    return (text == null || text.isEmpty) ? null : text;
  }

  /// Row for the local `messages` table.
  Map<String, dynamic> toRow(String chatId) {
    return {
      'id': id,
      'chat_id': chatId,
      'sender_id': senderId,
      'content': content,
      'created_at': createdAt.millisecondsSinceEpoch,
      'is_read': isRead ? 1 : 0,
      'reply_to_id': replyToMessageId,
      'sync_status': syncStatus,
      'edited_at': editedAt?.millisecondsSinceEpoch,
    };
  }

  Message copyWith({
    bool? isRead,
    String? id,
    String? syncStatus,
    String? content,
    DateTime? editedAt,
    QuotedMessage? quotedMessage,
  }) {
    return Message(
      id: id ?? this.id,
      senderId: senderId,
      receiverId: receiverId,
      content: content ?? this.content,
      createdAt: createdAt,
      isRead: isRead ?? this.isRead,
      replyToMessageId: replyToMessageId,
      quotedMessage: quotedMessage ?? this.quotedMessage,
      syncStatus: syncStatus ?? this.syncStatus,
      editedAt: editedAt ?? this.editedAt,
    );
  }
}
