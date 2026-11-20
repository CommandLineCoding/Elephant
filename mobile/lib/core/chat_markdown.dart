import 'package:markdown/markdown.dart' as md;

import 'mention.dart';

/// GitHub-flavoured Markdown without tables: a chat message that happens to
/// contain pipes shouldn't turn into a grid.
final md.ExtensionSet chatMarkdownExtensions = md.ExtensionSet(
  md.ExtensionSet.gitHubFlavored.blockSyntaxes
      .where((s) => s is! md.TableSyntax)
      .toList(),
  [MentionSyntax(), ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes],
);

final _fence = RegExp(r'^ {0,3}(```|~~~)');
// A heading (`# x`), a rule (`---`, `***`, `___`) or a setext underline
// (`===`, which would turn the line above into a heading).
final _heading = RegExp(r'^( {0,3})#');
final _rule = RegExp(r'^( {0,3})([-*_])(?: *\2){2,} *$');
final _setext = RegExp(r'^( {0,3})=+ *$');
// Inline code, links and mentions are passed through untouched.
final _protected = RegExp('`+[^`]*`+|https?://\\S+|${mentionPattern.pattern}');
// `*` between two letters or digits, as in 2*3*4.
final _intrawordStar = RegExp(r'(?<=[A-Za-z0-9])\*(?=[A-Za-z0-9])');

/// Escapes the Markdown that chat text triggers by accident, so ordinary
/// messages render as typed. Intended formatting keeps working: **bold**,
/// _italic_ and *italic* around words, `code`, ~~strike~~, links and lists.
///
/// What is escaped, outside code and links:
/// - `*` inside a word or number (`2*3*4`),
/// - `__` (`__init__.py`; use `**` for bold),
/// - `<`, so HTML-looking text shows as typed,
/// - `#`, `---`/`***`/`___` and `===` lines, which would become headings or
///   rules.
String prepareChatMarkdown(String text) {
  final out = <String>[];
  var inFence = false;
  for (final line in text.split('\n')) {
    if (_fence.hasMatch(line)) {
      inFence = !inFence;
      out.add(line);
      continue;
    }
    if (inFence) {
      out.add(line);
      continue;
    }
    out.add(_escapeLine(line));
  }
  return out.join('\n');
}

String _escapeLine(String line) {
  var result = line
      .replaceFirstMapped(_heading, (m) => '${m[1]}\\#')
      .replaceFirstMapped(
        _rule,
        (m) => '${m[1]}\\${m[0]!.substring(m[1]!.length)}',
      )
      .replaceFirstMapped(
        _setext,
        (m) => '${m[1]}\\${m[0]!.substring(m[1]!.length)}',
      );

  // Escape inline markers everywhere except inside code spans and links.
  final buffer = StringBuffer();
  var last = 0;
  for (final m in _protected.allMatches(result)) {
    buffer
      ..write(_escapeInline(result.substring(last, m.start)))
      ..write(m[0]);
    last = m.end;
  }
  buffer.write(_escapeInline(result.substring(last)));
  return buffer.toString();
}

String _escapeInline(String text) => text
    .replaceAll(_intrawordStar, r'\*')
    .replaceAll('__', r'\_\_')
    .replaceAll('<', r'\<');
