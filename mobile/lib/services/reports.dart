import 'api_services.dart';

/// Why someone is being reported.
enum ReportReason {
  spam('spam', 'Spam'),
  harassment('harassment', 'Harassment or abuse'),
  other('other', 'Something else');

  final String wire;
  final String label;
  const ReportReason(this.wire, this.label);
}

/// One message sent along with a report, as plain text.
class AttachedMessage {
  final bool fromReported;
  final String text;
  final DateTime at;

  const AttachedMessage({
    required this.fromReported,
    required this.text,
    required this.at,
  });

  Map<String, dynamic> toJson() => {
    'from_reported': fromReported,
    'text': text,
    'at': at.toUtc().toIso8601String(),
  };
}

/// The longest note and message the server takes, and how many messages.
class ReportLimits {
  static const note = 500;
  static const messages = 5;
  static const messageText = 1000;
}

/// The server call behind a report. A class so a test can stand in for it.
abstract class ReportsApi {
  Future<void> send({
    required String userId,
    required ReportReason reason,
    required String note,
    required List<AttachedMessage> messages,
  });
}

class ServerReportsApi implements ReportsApi {
  const ServerReportsApi();

  @override
  Future<void> send({
    required String userId,
    required ReportReason reason,
    required String note,
    required List<AttachedMessage> messages,
  }) async {
    await ApiService().createReport({
      'user_id': userId,
      'reason': reason.wire,
      'note': note,
      'messages': [for (final m in messages) m.toJson()],
    });
  }
}

/// The last few messages of a chat to attach to a report, oldest first, as the
/// server takes them: plain text, cut to length, with the ones that can't be
/// read left out.
List<AttachedMessage> messagesForReport(
  Iterable<({bool fromReported, String? text, DateTime at})> chat,
) {
  final readable = [
    for (final m in chat)
      if (m.text != null && m.text!.trim().isNotEmpty)
        AttachedMessage(
          fromReported: m.fromReported,
          text: m.text!.trim().length > ReportLimits.messageText
              ? m.text!.trim().substring(0, ReportLimits.messageText)
              : m.text!.trim(),
          at: m.at,
        ),
  ];
  return readable.length <= ReportLimits.messages
      ? readable
      : readable.sublist(readable.length - ReportLimits.messages);
}
