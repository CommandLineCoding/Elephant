import 'message_payload.dart';
import 'shared_contact.dart';
import 'shared_location.dart';

/// One short line for a message in a place that has room for a few words: the
/// pinned bar, a quote, the chat list, a search result. A place and a person
/// get a label, since the text other apps see is a long link.
String summarizeMessage(String text, MessagePayload? payload) {
  if (SharedLocation.fromPayload(payload) != null) return '📍 Location';
  final contact = SharedContact.fromPayload(payload);
  if (contact != null) return '👤 Contact: ${contact.name}';
  return text;
}

/// [summarizeMessage] for raw message [content] with its hidden line.
String summarizeContent(String content) {
  final parts = MessagePayload.split(content);
  return summarizeMessage(parts.text, parts.payload);
}
