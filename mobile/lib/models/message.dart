import '../core/constants.dart';
import '../core/mention.dart';
import '../core/message_payload.dart';
import '../core/message_summary.dart';

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

  /// When the sender deleted it for everyone. Its content is gone.
  final DateTime? deletedAt;

  /// When it reached the recipient's phone (direct messages we sent).
  final DateTime? deliveredAt;

  /// When a disappearing message goes, or null if it stays. The server works it
  /// out, so both phones agree.
  final DateTime? expiresAt;

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
    this.deletedAt,
    this.deliveredAt,
    this.expiresAt,
  });

  bool get isEdited => editedAt != null;

  /// Whether it has disappeared by [now].
  bool isExpired([DateTime? now]) =>
      expiresAt != null && !expiresAt!.isAfter(now ?? DateTime.now());

  /// Reached the recipient's phone. A message that was read was delivered.
  bool get isDelivered => deliveredAt != null || isRead;

  /// Shown as "This message was deleted".
  bool get isDeleted => deletedAt != null;

  /// Whether the server's edit time is newer than the cached one. The local copy
  /// is stored in milliseconds but the server sends microseconds, so comparing
  /// them directly makes an unchanged edit look newer. The message would then be
  /// decrypted a second time, which a Signal session rejects, and the readable
  /// text replaced by a placeholder.
  static bool isNewerEdit(DateTime? server, DateTime? local) {
    if (server == null) return false;
    if (local == null) return true;
    return server.millisecondsSinceEpoch > local.millisecondsSinceEpoch;
  }

  bool get isPending => syncStatus == 'pending';

  // A message is immutable, so what its content holds is worked out once.
  static final Expando<({String text, MessagePayload? payload})> _parsed =
      Expando();

  ({String text, MessagePayload? payload}) get _split =>
      _parsed[this] ??= MessagePayload.split(content);

  /// The structured payload in this message, if it has a valid one.
  MessagePayload? get payload => _split.payload;

  /// The message text without a payload's hidden line: what to show, copy and
  /// quote.
  String get text => _split.text;

  /// [text] with mentions as plain `@Name`, for a line of text (a quote, a
  /// list).
  String get plainText => plainMentions(text);

  /// A short line for a pinned bar, a quote or a search result: [plainText],
  /// except that a location or a contact gets a label.
  String get summary => plainMentions(summarizeMessage(text, payload));

  /// An action (a reaction, a vote, a pin) rather than something to show.
  bool get isAction => payload?.isAction ?? false;

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
      deletedAt: _parseDate(json['deleted_at']),
      deliveredAt: _parseDate(json['delivered_at']),
      expiresAt: _parseDate(json['expires_at']),
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
      deletedAt: row['deleted_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['deleted_at'] as int)
          : null,
      deliveredAt: row['delivered_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['delivered_at'] as int)
          : null,
      expiresAt: row['expires_at'] != null
          ? DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int)
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
      'deleted_at': deletedAt?.millisecondsSinceEpoch,
      'delivered_at': deliveredAt?.millisecondsSinceEpoch,
      'expires_at': expiresAt?.millisecondsSinceEpoch,
    };
  }

  Message copyWith({
    bool? isRead,
    String? id,
    String? syncStatus,
    String? content,
    DateTime? editedAt,
    DateTime? deletedAt,
    DateTime? deliveredAt,
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
      deletedAt: deletedAt ?? this.deletedAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      expiresAt: expiresAt,
    );
  }
}
