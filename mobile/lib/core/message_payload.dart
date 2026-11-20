import 'dart:convert';

import 'package:flutter/foundation.dart';

/// A small structured payload carried inside an end-to-end encrypted message:
/// a reaction, a poll vote, a pin, a shared contact, a location, a link
/// preview. The server never sees it (see "Structured messages" in
/// docs/API_CONTRACTS.md).
///
/// The message text is a readable first part, followed by one hidden Markdown
/// reference-definition line holding the payload:
///
///     👍 Reacted to a message
///
///     [//]: # (elephant:v1:act:eyJraW5kIjoi...)
///
/// Apps that don't know the payload show only the first part, because
/// Markdown doesn't draw a link reference definition. `act` marks an *action*
/// (kept out of the message list and the chat list, never unread); `msg` marks
/// a payload that belongs to a visible message.
@immutable
class MessagePayload {
  /// What the payload is, e.g. `reaction`. Always 1–24 characters.
  final String kind;

  /// The rest of the payload's JSON object.
  final Map<String, dynamic> data;

  const MessagePayload(this.kind, this.data);

  /// Payloads that change the chat's state without being messages themselves.
  static const actionKinds = {'reaction', 'vote', 'pin'};

  static const _prefix = '[//]: # (elephant:v1:';
  static const _actionTag = 'act:';
  static const _messageTag = 'msg:';

  /// The text of an action's hidden line that the local database can search
  /// for, to skip actions without reading them.
  static const actionMarker = '$_prefix$_actionTag';

  /// More than this in a hidden line is not a payload.
  static const maxBlobChars = 16 * 1024;

  bool get isAction => actionKinds.contains(kind);

  /// The message text for [kind] and [data], with [text] shown by apps that
  /// don't understand it.
  static String encode(
    String kind,
    Map<String, dynamic> data, {
    required String text,
  }) {
    assert(kind.isNotEmpty && kind.length <= 24, 'bad kind $kind');
    final isAction = actionKinds.contains(kind);
    final json = jsonEncode({...data, 'kind': kind});
    final blob = base64Url.encode(utf8.encode(json)).replaceAll('=', '');
    final tag = isAction ? _actionTag : _messageTag;
    final hidden = '$_prefix$tag$blob)';
    return text.trim().isEmpty ? hidden : '${text.trim()}\n\n$hidden';
  }

  /// Splits message [content] into its readable text and its payload, if it
  /// has a valid one. Content without one comes back unchanged. A hidden line
  /// that isn't a valid payload is left alone: it is plain text.
  static ({String text, MessagePayload? payload}) split(String content) {
    final at = content.lastIndexOf(_prefix);
    if (at == -1 || (at != 0 && content[at - 1] != '\n')) {
      return (text: content, payload: null);
    }
    final line = content.substring(at).trimRight();
    if (!line.endsWith(')') || line.contains('\n')) {
      return (text: content, payload: null);
    }

    var rest = line.substring(_prefix.length, line.length - 1);
    final isAction = rest.startsWith(_actionTag);
    if (!isAction && !rest.startsWith(_messageTag)) {
      return (text: content, payload: null);
    }
    rest = rest.substring(isAction ? _actionTag.length : _messageTag.length);
    if (rest.isEmpty || rest.length > maxBlobChars) {
      return (text: content, payload: null);
    }

    try {
      final padded = rest.padRight((rest.length + 3) ~/ 4 * 4, '=');
      final decoded = jsonDecode(utf8.decode(base64Url.decode(padded)));
      if (decoded is! Map) return (text: content, payload: null);
      final data = Map<String, dynamic>.from(decoded);
      final kind = data.remove('kind');
      if (kind is! String || kind.isEmpty || kind.length > 24) {
        return (text: content, payload: null);
      }
      // The tag has to agree with the kind, or the chat list's shortcut
      // (skipping `act` rows) would hide a visible message.
      if (actionKinds.contains(kind) != isAction) {
        return (text: content, payload: null);
      }
      return (
        text: content.substring(0, at).trimRight(),
        payload: MessagePayload(kind, data),
      );
    } on FormatException {
      return (text: content, payload: null);
    }
  }

  /// [content] without its hidden line: what to show in a preview.
  static String readable(String content) => split(content).text;

  /// A typed read of a field, or null if it is missing or the wrong type.
  T? field<T>(String name) {
    final value = data[name];
    return value is T ? value : null;
  }
}
