import 'package:markdown/markdown.dart' as md;

/// An @mention as it is stored in a message: `@[Name](user-id)`. The ID is
/// what counts, so a renamed member is still the one mentioned; the name is
/// only what apps that don't know mentions show (as a link named Name).
final mentionPattern = RegExp(
  r'@\[([^\[\]()\n]{1,60})\]\(([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})\)',
);

/// A name that is safe inside a mention.
String mentionName(String name) =>
    name.replaceAll(RegExp(r'[\[\]()\n\r]'), '').trim();

String mentionToken(String name, String userId) =>
    '@[${mentionName(name)}](${userId.toLowerCase()})';

/// The people mentioned in [text], by lower-case ID, each once.
Set<String> mentionedIds(String text) => {
  for (final m in mentionPattern.allMatches(text)) m[2]!.toLowerCase(),
};

/// Whether [text] mentions [userId].
bool mentionsUser(String text, String? userId) =>
    userId != null && mentionedIds(text).contains(userId.toLowerCase());

/// [text] with each mention as a plain `@Name`, for places that only show a
/// line of text (the chat list, a quote).
String plainMentions(String text) =>
    text.replaceAllMapped(mentionPattern, (m) => '@${m[1]}');

/// Turns stored mentions into what the person edits: plain `@Name`, and which
/// ID each name stands for. A name that would stand for two people is left as
/// it is stored.
({String text, Map<String, String> mentions}) decodeMentions(String text) {
  final mentions = <String, String>{};
  final shown = text.replaceAllMapped(mentionPattern, (m) {
    final key = '@${m[1]}';
    final id = m[2]!.toLowerCase();
    if (mentions.putIfAbsent(key, () => id) != id) return m[0]!;
    return key;
  });
  return (text: shown, mentions: mentions);
}

/// The reverse of [decodeMentions]: each `@Name` in [text] that is in
/// [mentions] (name → ID) becomes a stored mention. Names that were edited
/// away are skipped, and a name only counts as a whole word.
String encodeMentions(String text, Map<String, String> mentions) {
  final names = mentions.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  var result = text;
  for (final key in names) {
    final pattern = RegExp(
      '(?<![\\p{L}\\p{N}_])${RegExp.escape(key)}(?![\\p{L}\\p{N}_])',
      unicode: true,
    );
    result = result.replaceAllMapped(
      pattern,
      (_) => mentionToken(key.substring(1), mentions[key]!),
    );
  }
  return result;
}

/// Reads mentions as their own element when a message is drawn as Markdown.
class MentionSyntax extends md.InlineSyntax {
  MentionSyntax() : super(mentionPattern.pattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    parser.addNode(
      md.Element.text('mention', match[1]!)
        ..attributes['id'] = match[2]!.toLowerCase(),
    );
    return true;
  }
}
