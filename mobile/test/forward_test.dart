import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/pages/chat/forward_page.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:provider/provider.dart';

/// Records what would be forwarded instead of sending it.
class _Recorder extends ActiveChatController {
  String? text;
  Map<String, bool>? targets;

  @override
  Future<Map<String, String>> forward(
    String text,
    Map<String, bool> targets,
  ) async {
    this.text = text;
    this.targets = targets;
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'plugins.it_nomads.com/flutter_secure_storage',
      'dev.fluttercommunity.plus/connectivity',
      'dev.fluttercommunity.plus/connectivity_status',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (_) async => null,
      );
    }
  });

  test('forwarding to the open group shows the message there', () async {
    final chat = ActiveChatController()
      ..currentChatUserId = 'g1'
      ..isCurrentChatGroup = true;
    final failed = await chat.forward('hello crew', {'g1': true});
    expect(failed, isEmpty);
    expect(chat.activeChat.single.content, 'hello crew');
  });

  test(
    'a chat that can\'t be reached is reported, the rest still sent',
    () async {
      final chat = ActiveChatController();
      // No encryption session can be set up for a direct chat in tests.
      final failed = await chat.forward('hi', {'g1': true, 'u-bob': false});
      expect(failed.keys, ['u-bob']);
    },
  );

  testWidgets('the picker forwards to the chosen chats', (tester) async {
    final recorder = _Recorder();
    final inbox = InboxController()
      ..inbox = [
        InboxItem(
          id: 'u-bob',
          title: 'Bob',
          username: 'bob.1234',
          lastMessage: '',
          timestamp: DateTime.now(),
          isGroup: false,
        ),
        InboxItem(
          id: 'g1',
          title: 'Hiking crew',
          lastMessage: '',
          timestamp: DateTime.now(),
          isGroup: true,
        ),
      ];
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: inbox),
          ChangeNotifierProvider<ActiveChatController>.value(value: recorder),
        ],
        child: MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: const ForwardPage(text: 'see you at 8'),
        ),
      ),
    );

    expect(find.text('Choose chats'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hik');
    await tester.pump();
    expect(find.text('Bob'), findsNothing);
    expect(find.text('Hiking crew'), findsOneWidget);

    await tester.tap(find.text('Hiking crew'));
    await tester.pump();
    expect(find.text('Send to 1'), findsOneWidget);

    await tester.tap(find.text('Send to 1'));
    await tester.pump();
    expect(recorder.text, 'see you at 8');
    expect(recorder.targets, {'g1': true});
  });
}
