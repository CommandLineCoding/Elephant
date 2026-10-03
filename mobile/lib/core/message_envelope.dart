import 'dart:convert';

/// Wire format of the `content` field the server relays opaquely:
/// `{"type": <int>, "ciphertext": "<base64 or text>"}`.
///
/// `type == 0` carries plaintext (used for group messages, which are not
/// end-to-end encrypted yet). Any other type is a libsignal
/// `CiphertextMessage` type for direct messages.
class MessageEnvelope {
  static const int plaintextType = 0;

  /// Prefix of local placeholders shown when content can't be decrypted.
  static const String lockedPrefix = '🔒 ';

  final int type;
  final String body;

  const MessageEnvelope(this.type, this.body);

  bool get isPlaintext => type == plaintextType;

  String encode() => jsonEncode({'type': type, 'ciphertext': body});

  static String plain(String text) =>
      MessageEnvelope(plaintextType, text).encode();

  static MessageEnvelope? tryParse(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    if (!trimmed.startsWith('{') || !trimmed.contains('ciphertext')) {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return null;
      final type = decoded['type'];
      final body = decoded['ciphertext'];
      if (type is! int || body is! String) return null;
      return MessageEnvelope(type, body);
    } catch (_) {
      return null;
    }
  }

  /// True when [content] is still encrypted or is an undecryptable placeholder,
  /// i.e. it must not be cached or shown as readable text.
  static bool isUnreadable(String content) {
    if (content.startsWith(lockedPrefix)) return true;
    final envelope = tryParse(content);
    return envelope != null && !envelope.isPlaintext;
  }

  /// Best-effort readable text without touching Signal state: plaintext
  /// envelopes are unwrapped, encrypted ones become [fallback].
  static String preview(
    String content, {
    String fallback = '🔒 Encrypted message',
  }) {
    final envelope = tryParse(content);
    if (envelope == null) return content;
    return envelope.isPlaintext ? envelope.body : fallback;
  }

  static String locked(String reason) => '$lockedPrefix$reason';
}
