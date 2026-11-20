import 'message_payload.dart';

/// A poll sent in a chat: a question and a few options. Its ID is the ID of
/// the message that carries it, and votes are silent `vote` actions pointing
/// at it (see [MessagePayload]).
class PollData {
  final String question;
  final List<String> options;

  /// Whether people can pick more than one option.
  final bool multi;

  const PollData(this.question, this.options, {this.multi = false});

  static const minOptions = 2;
  static const maxOptions = 10;
  static const maxQuestionLength = 100;
  static const maxOptionLength = 50;

  /// Reads a `poll` payload, or null if it isn't a usable poll.
  static PollData? fromPayload(MessagePayload? payload) {
    if (payload == null || payload.kind != 'poll') return null;
    final question = payload.field<String>('q')?.trim();
    final raw = payload.field<List>('opts');
    if (question == null || question.isEmpty || raw == null) return null;
    if (raw.length < minOptions || raw.length > maxOptions) return null;
    final options = <String>[];
    for (final option in raw) {
      if (option is! String || option.trim().isEmpty) return null;
      options.add(option.trim());
    }
    return PollData(
      question,
      options,
      multi: payload.field<bool>('multi') ?? false,
    );
  }

  /// The payload for this poll and the text apps without polls show.
  (Map<String, dynamic>, String) toPayload() {
    final lines = [for (final option in options) '▫️ $option'];
    return (
      {'q': question, 'opts': options, 'multi': multi},
      '📊 Poll: $question\n${lines.join('\n')}',
    );
  }

  /// Why this can't be sent, or null if it can.
  static String? problemWith(String question, List<String> options) {
    if (question.trim().isEmpty) return 'Ask a question.';
    final filled = [
      for (final o in options)
        if (o.trim().isNotEmpty) o.trim(),
    ];
    if (filled.length < minOptions) return 'Add at least two options.';
    if (filled.toSet().length != filled.length) {
      return 'Each option has to be different.';
    }
    return null;
  }
}

/// What a poll's votes add up to.
class PollTally {
  /// Per option: who voted for it (sender keys, in the order they voted).
  final List<List<String>> votersByOption;

  /// How many people voted at all.
  final int voters;

  const PollTally(this.votersByOption, this.voters);

  int countFor(int option) => votersByOption[option].length;

  /// The share of voters who picked [option], from 0 to 1.
  double shareOf(int option) => voters == 0 ? 0 : countFor(option) / voters;

  /// The options [who] picked.
  Set<int> picksOf(String who) => {
    for (var i = 0; i < votersByOption.length; i++)
      if (votersByOption[i].contains(who)) i,
  };

  /// Adds up [votes] (voter → their picked options) for [poll]. Picks outside
  /// the poll are dropped, a single-choice poll keeps a voter's first pick,
  /// and a voter with nothing left isn't counted.
  static PollTally of(PollData poll, Map<String, List<int>> votes) {
    final byOption = List.generate(poll.options.length, (_) => <String>[]);
    var voters = 0;
    for (final entry in votes.entries) {
      var picks = {
        for (final i in entry.value)
          if (i >= 0 && i < poll.options.length) i,
      }.toList();
      if (!poll.multi && picks.length > 1) picks = [picks.first];
      if (picks.isEmpty) continue;
      voters++;
      for (final i in picks) {
        byOption[i].add(entry.key);
      }
    }
    return PollTally(byOption, voters);
  }
}

/// A vote's payload and the text apps without polls show.
(Map<String, dynamic>, String) votePayload(String pollId, Set<int> options) => (
  {'poll': pollId, 'opts': (options.toList()..sort())},
  options.isEmpty ? 'Took back a vote' : '🗳️ Voted in a poll',
);
