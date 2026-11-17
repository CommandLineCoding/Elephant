import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../db_services.dart';

/// How a call ended, from this phone's side.
enum CallOutcome {
  /// The call connected. The entry has a duration.
  answered,

  /// An incoming call nobody answered here.
  missed,

  /// An incoming call declined here, or an outgoing one the other person
  /// declined.
  declined,

  /// An outgoing call that rang out.
  noAnswer,

  /// An outgoing call to someone already in a call.
  busy,

  /// An outgoing call hung up here before it was answered.
  cancelled,

  /// An outgoing call that couldn't reach the other person.
  unavailable,

  /// The call couldn't connect, or dropped before it did.
  failed,
}

/// One call in a direct chat's history.
class CallLogEntry {
  final String id;
  final String chatId;
  final bool outgoing;
  final CallOutcome outcome;
  final DateTime startedAt;
  final Duration duration;

  const CallLogEntry({
    required this.id,
    required this.chatId,
    required this.outgoing,
    required this.outcome,
    required this.startedAt,
    this.duration = Duration.zero,
  });

  bool get isMissed => !outgoing && outcome == CallOutcome.missed;

  /// What the chat shows for this call, e.g. "Voice call · 3:12".
  String get label {
    switch (outcome) {
      case CallOutcome.answered:
        return 'Voice call · ${formatCallDuration(duration)}';
      case CallOutcome.missed:
        return 'Missed voice call';
      case CallOutcome.declined:
        return outgoing ? 'Voice call declined' : 'Declined voice call';
      case CallOutcome.noAnswer:
        return 'Voice call · No answer';
      case CallOutcome.busy:
        return 'Voice call · Busy';
      case CallOutcome.cancelled:
        return 'Cancelled voice call';
      case CallOutcome.unavailable:
        return 'Voice call · Unavailable';
      case CallOutcome.failed:
        return 'Voice call · Couldn\'t connect';
    }
  }

  Map<String, dynamic> toRow() => {
    'id': id,
    'chat_id': chatId,
    'outgoing': outgoing ? 1 : 0,
    'outcome': outcome.name,
    'started_at': startedAt.millisecondsSinceEpoch,
    'duration_seconds': duration.inSeconds,
  };

  static CallLogEntry fromRow(Map<String, dynamic> row) => CallLogEntry(
    id: row['id'] as String,
    chatId: row['chat_id'] as String,
    outgoing: row['outgoing'] == 1,
    outcome: CallOutcome.values.firstWhere(
      (o) => o.name == row['outcome'],
      orElse: () => CallOutcome.failed,
    ),
    startedAt: DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
    duration: Duration(seconds: row['duration_seconds'] as int),
  );
}

/// "3:12", or "1:02:05" for calls over an hour.
String formatCallDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// The calls in each direct chat, kept on this device only.
class CallLog extends ChangeNotifier {
  static final CallLog instance = CallLog();

  final Map<String, List<CallLogEntry>> _byChat = {};

  /// Calls in [chatId], oldest first. Empty until [load] has run for it.
  List<CallLogEntry> entriesFor(String chatId) =>
      _byChat[chatId.toLowerCase()] ?? const [];

  Future<void> load(String chatId) async {
    final id = chatId.toLowerCase();
    try {
      final db = await DatabaseHelper.instance.database;
      final rows = await db.query(
        'call_log',
        where: 'chat_id = ?',
        whereArgs: [id],
        orderBy: 'started_at ASC',
      );
      _byChat[id] = rows.map(CallLogEntry.fromRow).toList();
      notifyListeners();
    } catch (e) {
      debugPrint("Couldn't load the call log: $e");
    }
  }

  Future<void> add(CallLogEntry entry) async {
    final id = entry.chatId.toLowerCase();
    _byChat[id] = [...entriesFor(id), entry]
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    notifyListeners();
    try {
      final db = await DatabaseHelper.instance.database;
      await db.insert(
        'call_log',
        entry.toRow()..['chat_id'] = id,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      debugPrint("Couldn't save a call to the log: $e");
    }
  }

  /// Forgets a chat's calls (the database rows go with the chat).
  void forget(String chatId) {
    if (_byChat.remove(chatId.toLowerCase()) != null) notifyListeners();
  }

  void clear() {
    _byChat.clear();
    notifyListeners();
  }

  @visibleForTesting
  void debugSet(String chatId, List<CallLogEntry> entries) {
    _byChat[chatId.toLowerCase()] = entries;
    notifyListeners();
  }
}
