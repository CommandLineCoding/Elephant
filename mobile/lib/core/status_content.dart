import 'dart:convert';

import 'package:flutter/material.dart';

/// What a text status looks like: its words on a coloured background in one of
/// a few fonts. Travels inside the encrypted copy, so the server never sees it.
/// Text that is a little quieter than white on a status's background and still
/// holds 4.5:1 on all of them.
const statusMutedWhite = Color(0xEBFFFFFF);

class StatusStyle {
  /// The backgrounds to choose from. All hold white text at 4.5:1 or better.
  static const backgrounds = <Color>[
    Color(0xFF4F5FE0),
    Color(0xFF2A8577),
    Color(0xFFB85A33),
    Color(0xFF9A4A78),
    Color(0xFF3F8244),
    Color(0xFF3B4252),
  ];

  /// The fonts to choose from: a name to show, and the family to use.
  static const fonts = <(String, String?)>[
    ('Classic', null),
    ('Serif', 'serif'),
    ('Mono', 'monospace'),
  ];

  static Color backgroundAt(int index) =>
      backgrounds[index.clamp(0, backgrounds.length - 1)];

  static String? fontFamilyAt(int index) =>
      fonts[index.clamp(0, fonts.length - 1)].$2;
}

class StatusContent {
  /// The most characters a status can have.
  static const maxLength = 700;

  final String text;
  final int background;
  final int font;

  const StatusContent({required this.text, this.background = 0, this.font = 0});

  Color get backgroundColor => StatusStyle.backgroundAt(background);
  String? get fontFamily => StatusStyle.fontFamilyAt(font);

  /// [text] with its edges trimmed and cut to [maxLength] characters.
  static String clean(String text) {
    final trimmed = text.trim();
    final runes = trimmed.runes.toList();
    return runes.length <= maxLength
        ? trimmed
        : String.fromCharCodes(runes.take(maxLength));
  }

  /// The plaintext that is encrypted for each person.
  String encode() =>
      jsonEncode({'v': 1, 'text': clean(text), 'bg': background, 'font': font});

  /// The content in [raw], or null if it isn't one: a status from a newer app
  /// that this one can't show, or garbage. Colours and fonts it doesn't know
  /// fall back to the first.
  static StatusContent? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != 1) return null;
      final text = decoded['text'];
      if (text is! String) return null;
      final cleaned = clean(text);
      if (cleaned.isEmpty) return null;
      final bg = decoded['bg'];
      final font = decoded['font'];
      return StatusContent(
        text: cleaned,
        background: bg is int && bg >= 0 && bg < StatusStyle.backgrounds.length
            ? bg
            : 0,
        font: font is int && font >= 0 && font < StatusStyle.fonts.length
            ? font
            : 0,
      );
    } catch (_) {
      return null;
    }
  }
}

/// How long ago a status was posted, for its header: "Just now", "5 min ago",
/// "3 h ago".
String statusAge(DateTime posted, DateTime now) {
  final d = now.difference(posted);
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  return '${d.inHours} h ago';
}

/// The message a private reply to a status is sent as: it quotes the status,
/// then says the reply. A normal message, so the other person can answer it
/// like any other.
String statusReplyText(StatusContent status, String reply) {
  final runes = status.text.replaceAll(RegExp(r'\s+'), ' ').runes.toList();
  final quoted = runes.length <= 60
      ? String.fromCharCodes(runes)
      : '${String.fromCharCodes(runes.take(60))}…';
  return '↩️ Status: “$quoted”\n\n${reply.trim()}';
}
