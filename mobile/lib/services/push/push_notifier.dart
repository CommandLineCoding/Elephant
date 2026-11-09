import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:mobile/models/inbox_item.dart';

/// The conversations that deserve a notification: they have unread messages
/// newer than both the last one we notified about and [since].
List<InboxItem> chatsToNotify(
  List<InboxItem> conversations,
  Map<String, int> lastNotified, {
  required DateTime since,
}) {
  return [
    for (final chat in conversations)
      if (chat.unreadCount > 0 &&
          chat.timestamp.millisecondsSinceEpoch >
              (lastNotified[chat.id] ?? since.millisecondsSinceEpoch))
        chat,
  ];
}

/// Notification text. It never contains message text: the app can't decrypt in
/// the background, and the text shouldn't go through the notification system.
({String title, String body}) notificationText(
  InboxItem chat, {
  required bool showName,
}) {
  final body = chat.unreadCount > 1
      ? '${chat.unreadCount} new messages'
      : 'New message';
  if (!showName) return (title: 'Elephant', body: body);
  return (
    title: chat.title.isEmpty ? (chat.username ?? 'Elephant') : chat.title,
    body: body,
  );
}

/// What a notification's tap hands back to the app.
String chatPayload(InboxItem chat) =>
    jsonEncode({'id': chat.id, 'group': chat.isGroup});

String? chatIdFromPayload(String? payload) {
  if (payload == null || payload.isEmpty) return null;
  try {
    final id = (jsonDecode(payload) as Map<String, dynamic>)['id'];
    return id is String && id.isNotEmpty ? id : null;
  } catch (_) {
    return null;
  }
}

/// Shows and clears local notifications.
class PushNotifier {
  static const channelId = 'messages';
  static const _icon = 'ic_stat_notify';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  Future<void> init({DidReceiveNotificationResponseCallback? onTap}) async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings(_icon),
      ),
      onDidReceiveNotificationResponse: onTap,
    );
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        'Messages',
        description: 'Alerts for new messages',
        importance: Importance.high,
      ),
    );
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Asks for the Android 13+ notification permission. True if granted (or
  /// not needed).
  Future<bool> requestPermission() async {
    final android = _android;
    if (android == null) return true;
    return await android.requestNotificationsPermission() ?? false;
  }

  Future<bool> permissionGranted() async {
    final android = _android;
    if (android == null) return true;
    return await android.areNotificationsEnabled() ?? false;
  }

  /// The chat the app was launched from, if a notification was tapped while
  /// the app wasn't running.
  Future<String?> launchChatId() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details?.didNotificationLaunchApp != true) return null;
    return chatIdFromPayload(details?.notificationResponse?.payload);
  }

  Future<void> showChat(InboxItem chat, {required bool showName}) async {
    final text = notificationText(chat, showName: showName);
    try {
      await _plugin.show(
        id: chat.id.hashCode & 0x7fffffff,
        title: text.title,
        body: text.body,
        payload: chatPayload(chat),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            'Messages',
            channelDescription: 'Alerts for new messages',
            importance: Importance.high,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            // Hide the sender on the lock screen until the phone is unlocked.
            visibility: NotificationVisibility.private,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Could not show a notification: $e');
    }
  }

  Future<void> cancelAll() => _plugin.cancelAll();
}
