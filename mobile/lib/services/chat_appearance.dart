import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/chat_wallpaper.dart';

/// How big message text is.
enum MessageTextSize {
  small('Small', 0.9),
  standard('Default', 1.0),
  large('Large', 1.15),
  larger('Larger', 1.3);

  final String label;

  /// Multiplies the size of message text, on top of the phone's own setting.
  final double scale;
  const MessageTextSize(this.label, this.scale);

  static MessageTextSize byName(String? name) => values.firstWhere(
    (s) => s.name == name,
    orElse: () => MessageTextSize.standard,
  );
}

/// How chats look on this phone: the wallpaper for all of them or for one, and
/// the size of message text. Kept on the phone only.
class ChatAppearance extends ChangeNotifier {
  /// The one the app uses. Tests replace it.
  static ChatAppearance instance = ChatAppearance();

  static const _sizeKey = 'message_text_size';
  static const _allKey = 'chat_wallpaper';
  static const _perChatKey = 'chat_wallpapers';

  MessageTextSize _size = MessageTextSize.standard;
  Wallpaper _all = Wallpaper.none;
  final Map<String, Wallpaper> _perChat = {};

  MessageTextSize get textSize => _size;

  /// The wallpaper for chats that don't have their own.
  Wallpaper get wallpaper => _all;

  /// The wallpaper for [chatId]: its own, else the one for all chats.
  Wallpaper wallpaperFor(String chatId) =>
      _perChat[chatId.toLowerCase()] ?? _all;

  /// Whether [chatId] has a wallpaper of its own.
  bool hasOwnWallpaper(String chatId) =>
      _perChat.containsKey(chatId.toLowerCase());

  /// Reads the saved choices. Call once at startup.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _size = MessageTextSize.byName(prefs.getString(_sizeKey));
    _all = Wallpaper.byId(prefs.getString(_allKey));
    _perChat.clear();
    try {
      final saved = jsonDecode(prefs.getString(_perChatKey) ?? '{}');
      if (saved is Map) {
        for (final entry in saved.entries) {
          _perChat['${entry.key}'.toLowerCase()] = Wallpaper.byId(
            '${entry.value}',
          );
        }
      }
    } on FormatException {
      // A damaged value is the same as none.
    }
    notifyListeners();
  }

  Future<void> setTextSize(MessageTextSize size) async {
    _size = size;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      _sizeKey,
      size.name,
    );
  }

  Future<void> setWallpaper(Wallpaper wallpaper) async {
    _all = wallpaper;
    notifyListeners();
    await (await SharedPreferences.getInstance()).setString(
      _allKey,
      wallpaper.id,
    );
  }

  /// Gives [chatId] its own wallpaper, or, with null, goes back to the one for
  /// all chats.
  Future<void> setWallpaperFor(String chatId, Wallpaper? wallpaper) async {
    final key = chatId.toLowerCase();
    if (wallpaper == null) {
      _perChat.remove(key);
    } else {
      _perChat[key] = wallpaper;
    }
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _perChatKey,
      jsonEncode({for (final e in _perChat.entries) e.key: e.value.id}),
    );
  }

  /// Forgets the chats' own wallpapers, on sign-out: the chats belong to the
  /// account. The choices for all chats and the text size stay.
  void forgetChats() {
    if (_perChat.isEmpty) return;
    _perChat.clear();
    notifyListeners();
    SharedPreferences.getInstance().then((p) => p.remove(_perChatKey));
  }
}
