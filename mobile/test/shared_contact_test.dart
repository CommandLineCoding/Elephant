import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/message_payload.dart';
import 'package:mobile/core/shared_contact.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/pages/chat/contact_picker_page.dart';
import 'package:mobile/themes/app_themes.dart';

import 'chat_harness.dart';

const avaId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const ava = SharedContact(id: avaId, name: 'Ava Stone', username: 'ava.1234');

String contactMessage(SharedContact c) {
  final (data, text) = c.toPayload();
  return MessagePayload.encode('contact', data, text: text);
}

InboxItem chatWith(
  String id,
  String title,
  String? username, {
  bool group = false,
}) => InboxItem(
  id: id,
  title: title,
  username: username,
  lastMessage: 'hi',
  timestamp: DateTime(2026),
  isGroup: group,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the contact payload', () {
    test('round-trips, and older apps get a name and a link', () {
      final content = contactMessage(ava);
      final read = SharedContact.fromPayload(
        MessagePayload.split(content).payload,
      )!;
      expect(read.id, avaId);
      expect(read.name, 'Ava Stone');
      expect(read.username, 'ava.1234');

      final text = MessagePayload.readable(content);
      expect(text, startsWith('👤 Contact: Ava Stone (@ava.1234)\n'));
      expect(text, contains('/u/ava.1234'));
    });

    test('rejects anything that isn\'t a proper contact', () {
      MessagePayload p(Map<String, dynamic> data) =>
          MessagePayload('contact', data);
      Map<String, dynamic> good() => {
        'id': avaId,
        'name': 'Ava',
        'username': 'ava.1234',
      };
      expect(SharedContact.fromPayload(p(good())), isNotNull);
      expect(SharedContact.fromPayload(null), isNull);
      expect(SharedContact.fromPayload(MessagePayload('poll', good())), isNull);
      expect(
        SharedContact.fromPayload(p(good()..['id'] = 'not-a-uuid')),
        isNull,
      );
      expect(SharedContact.fromPayload(p(good()..['id'] = 5)), isNull);
      expect(
        SharedContact.fromPayload(p(good()..['username'] = 'AVA')),
        isNull,
      );
      expect(
        SharedContact.fromPayload(p(good()..['username'] = '../../x.1234')),
        isNull,
      );
      expect(SharedContact.fromPayload(p(good()..['name'] = ' ')), isNull);
      expect(
        SharedContact.fromPayload(p(good()..['name'] = 'x' * 101)),
        isNull,
      );
      expect(SharedContact.fromPayload(p(good()..remove('name'))), isNull);
    });
  });

  group('in a chat', () {
    testWidgets('a shared contact is a card with a Message button', (
      tester,
    ) async {
      await showTestChat(
        tester,
        messages: [testMessage('c1', contactMessage(ava))],
      );
      expect(find.text('Ava Stone'), findsOneWidget);
      expect(find.text('@ava.1234'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Message'), findsOneWidget);
      // The text older apps show isn't drawn.
      expect(find.textContaining('👤 Contact'), findsNothing);
    });

    testWidgets('Message opens a chat with them, and Back returns', (
      tester,
    ) async {
      final chat = await showTestChat(
        tester,
        messages: [testMessage('c1', contactMessage(ava))],
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Message'));
      await tester.pumpAndSettle();

      expect(find.byType(ChatPage, skipOffstage: false), findsNWidgets(2));
      expect(chat.opened.last, avaId);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOneWidget);
      expect(
        chat.opened.last,
        'u2',
        reason: 'the chat underneath is opened again',
      );
      expect(chat.currentChatUserId, 'u2');
    });

    testWidgets(
      'no Message button for yourself, or for the person you are chatting with',
      (tester) async {
        await showTestChat(
          tester,
          chatId: avaId,
          messages: [testMessage('c1', contactMessage(ava))],
        );
        expect(find.text('Ava Stone'), findsWidgets);
        expect(find.widgetWithText(OutlinedButton, 'Message'), findsNothing);
      },
    );

    testWidgets('a contact that can not be read shows its text instead', (
      tester,
    ) async {
      final broken = MessagePayload.encode('contact', {
        'id': 'nope',
        'name': 'x',
        'username': 'x',
      }, text: '👤 Contact: x');
      await showTestChat(tester, messages: [testMessage('c1', broken)]);
      expect(find.text('👤 Contact: x'), findsOneWidget);
    });

    testWidgets('Attach → Contact lists your chats, and sharing sends it', (
      tester,
    ) async {
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [
          chatWith('u2', 'Bob', 'bob.1234'),
          chatWith(avaId, 'Ava Stone', 'ava.1234'),
          chatWith('g1', 'The group', null, group: true),
        ];
      final chat = await showTestChat(tester, messages: [], inbox: inbox);
      await tester.tap(find.byTooltip('Attach'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Contact'));
      await tester.pumpAndSettle();

      expect(find.byType(ContactPickerPage), findsOneWidget);
      expect(find.text('Ava Stone'), findsOneWidget);
      expect(find.text('Bob'), findsNothing, reason: 'not into their own chat');
      expect(find.text('The group'), findsNothing, reason: 'people only');

      await tester.tap(find.text('Ava Stone'));
      await tester.pumpAndSettle();

      expect(find.byType(ContactPickerPage), findsNothing);
      final sent = chat.sent.single;
      expect(sent.silent, isFalse, reason: 'a contact is a message');
      final shared = SharedContact.fromPayload(
        MessagePayload.split(sent.text).payload,
      )!;
      expect(shared.id, avaId);
      expect(shared.username, 'ava.1234');
      expect(find.text('@ava.1234'), findsOneWidget);
    });

    testWidgets('the picker can search, and says when there is no one', (
      tester,
    ) async {
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [
          chatWith(avaId, 'Ava Stone', 'ava.1234'),
          chatWith('b', 'Ben Hall', 'ben.5678'),
        ];
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: ChangeNotifierProvider.value(
            value: inbox,
            child: const ContactPickerPage(),
          ),
        ),
      );
      expect(find.text('Ava Stone'), findsOneWidget);
      expect(find.text('Ben Hall'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'ben');
      await tester.pump();
      expect(find.text('Ava Stone'), findsNothing);
      expect(find.text('Ben Hall'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump();
      expect(find.text('No one to share'), findsOneWidget);
    });
  });
}
