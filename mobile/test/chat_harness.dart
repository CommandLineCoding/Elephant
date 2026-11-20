import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What a [TestChat] was asked to send.
class SentMessage {
  final String targetId;
  final bool isGroup;
  final String text;
  final bool silent;
  final String? replyTo;
  const SentMessage(
    this.targetId,
    this.isGroup,
    this.text,
    this.silent,
    this.replyTo,
  );
}

/// An [ActiveChatController] with no network, database or Signal: opening
/// does nothing, and sending records the message and adds it to the chat the
/// way a real send does.
class TestChat extends ActiveChatController {
  final List<SentMessage> sent = [];

  @override
  Future<void> openChat(String targetUid, {bool isGroup = false}) async {}

  @override
  Future<void> loadMoreMessages() async {}

  @override
  Future<(String?, Message?)> sendTo(
    String targetId, {
    required bool isGroup,
    required String text,
    Message? replyingTo,
    bool silent = false,
  }) async {
    sent.add(SentMessage(targetId, isGroup, text, silent, replyingTo?.id));
    final message = Message(
      id: 'sent-${sent.length}',
      senderId: 'me',
      receiverId: targetId,
      content: text,
      createdAt: DateTime.now(),
      isRead: false,
    );
    if (currentChatUserId == targetId) {
      activeChat = [...activeChat, message];
      notifyListeners();
    }
    return (null, message);
  }
}

/// Mocks the platform channels the app touches at start-up. Call from
/// `setUpAll`.
void mockPlatformChannels() {
  SharedPreferences.setMockInitialValues({});
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  for (final name in [
    'com.llfbandit.app_links/messages',
    'com.llfbandit.app_links/events',
    'dev.fluttercommunity.plus/connectivity',
    'dev.fluttercommunity.plus/connectivity_status',
    'plugins.it_nomads.com/flutter_secure_storage',
  ]) {
    messenger.setMockMethodCallHandler(MethodChannel(name), (call) async {
      if (call.method == 'check') return 'wifi';
      return null;
    });
  }
}

/// A message in a test chat. Anything not from [sender] `me` is from someone
/// else.
Message testMessage(
  String id,
  String content, {
  String sender = 'u2',
  DateTime? at,
  bool pending = false,
}) => Message(
  id: id,
  senderId: sender,
  receiverId: sender == 'me' ? 'u2' : 'me',
  content: content,
  createdAt: at ?? DateTime.now().subtract(const Duration(minutes: 5)),
  isRead: true,
  syncStatus: pending ? 'pending' : 'synced',
);

/// Shows a chat page for [chatId] with [messages] already loaded.
Future<TestChat> showTestChat(
  WidgetTester tester, {
  required List<Message> messages,
  String chatId = 'u2',
  bool isGroup = false,
  InboxController? inbox,
  TestChat? chat,
  Widget Function(Widget page)? wrap,
}) async {
  final controller = chat ?? TestChat();
  controller
    ..currentUserIdProvider = (() => 'me')
    ..currentChatUserId = chatId
    ..isCurrentChatGroup = isGroup
    ..activeChat = messages;
  final inboxController = inbox ?? (InboxController()..hasLoadedOnce = true);

  Widget page = ChatPage(
    chatUserId: chatId,
    displayName: isGroup ? 'The group' : 'Bob',
    username: isGroup ? null : 'bob.1234',
    isGroup: isGroup,
  );
  if (wrap != null) page = wrap(page);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AuthState()),
        ChangeNotifierProvider.value(value: inboxController),
        ChangeNotifierProvider<ActiveChatController>.value(value: controller),
        ChangeNotifierProvider(create: (_) => GroupController()),
        ChangeNotifierProvider(create: (_) => ChatSearchController()),
        ChangeNotifierProvider(create: (_) => GroupDetailsController()),
        ChangeNotifierProvider(
          create: (_) => ChatConnectionController(
            eventHandler: ChatEventHandler(
              inboxController: inboxController,
              activeChatController: controller,
              currentUserIdProvider: () => 'me',
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppThemes.getTheme(ThemeType.frost),
        home: page,
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  return controller;
}
