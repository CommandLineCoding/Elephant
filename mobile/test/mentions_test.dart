import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/chat_markdown.dart';
import 'package:mobile/core/mention.dart';
import 'package:mobile/core/message_envelope.dart';
import 'package:mobile/models/group.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/chat/chat_details_page.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/services/drafts.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/home_page_widgets.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

const meId = 'cccccccc-cccc-cccc-cccc-cccccccccccc';
const aliceId = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const bobId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const sam1 = '11111111-1111-1111-1111-111111111111';
const sam2 = '22222222-2222-2222-2222-222222222222';

GroupMember member(String id, String name, String username) => GroupMember(
  userId: id,
  username: username,
  displayName: name,
  role: 'member',
);

class MemoryDrafts implements DraftStore {
  final Map<String, Draft> saved = {};

  @override
  Future<Map<String, Draft>> all() async => {...saved};

  @override
  Future<void> save(String chatId, Draft draft) async => saved[chatId] = draft;

  @override
  Future<void> delete(String chatId) async => saved.remove(chatId);
}

/// A widget on its own, with what the chat list tile reads.
class MultiProviderApp extends StatelessWidget {
  final InboxController inbox;
  final Widget child;

  const MultiProviderApp({super.key, required this.inbox, required this.child});

  @override
  Widget build(BuildContext context) => MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ChangeNotifierProvider(create: (_) => AuthState()),
      ChangeNotifierProvider.value(value: inbox),
      ChangeNotifierProvider(create: (_) => GroupDetailsController()),
    ],
    child: MaterialApp(
      theme: AppThemes.getTheme(ThemeType.frost),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the format', () {
    test('a mention is the name and the ID', () {
      expect(
        mentionToken('Alice Smith', aliceId.toUpperCase()),
        '@[Alice Smith]($aliceId)',
      );
    });

    test('a name can not break out of it', () {
      expect(mentionToken('A[l](i)\nce', aliceId), '@[Alice]($aliceId)');
    });

    test('finds who is mentioned, once each', () {
      // Written by another app, the ID may be in capitals.
      final text =
          'hi ${mentionToken('Alice', aliceId)} and @[Al](${aliceId.toUpperCase()}), '
          '${mentionToken('Bob', bobId)}';
      expect(mentionedIds(text), {aliceId, bobId});
    });

    test('is not fooled by things that only look like one', () {
      expect(mentionedIds('@[Alice](not-an-id)'), isEmpty);
      expect(mentionedIds('@[Al\nice]($aliceId)'), isEmpty);
      expect(mentionedIds('[Alice]($aliceId)'), isEmpty);
      expect(mentionedIds('@Alice'), isEmpty);
      expect(mentionedIds('@[]($aliceId)'), isEmpty);
    });

    test('knows whether a user is mentioned', () {
      final text = 'hey ${mentionToken('Alice', aliceId)}';
      expect(mentionsUser(text, aliceId), isTrue);
      expect(mentionsUser(text, aliceId.toUpperCase()), isTrue);
      expect(mentionsUser(text, bobId), isFalse);
      expect(mentionsUser(text, null), isFalse);
    });

    test('reads as plain @Name where only a line of text shows', () {
      expect(
        plainMentions('hey ${mentionToken('Alice', aliceId)}, ok?'),
        'hey @Alice, ok?',
      );
      expect(plainMentions('no mentions @here'), 'no mentions @here');
    });

    test('keeps the readable text of a message plain in previews', () {
      final content = MessageEnvelope.plain(
        'hey ${mentionToken('Alice', aliceId)}',
      );
      expect(MessageEnvelope.preview(content), 'hey @Alice');
      expect(
        MessageEnvelope.preview('raw ${mentionToken('B', bobId)}'),
        'raw @B',
      );
    });

    test('a message has a plain text too', () {
      final message = testMessage('m', 'hey ${mentionToken('Alice', aliceId)}');
      expect(message.plainText, 'hey @Alice');
      expect(message.text, contains(aliceId));
    });
  });

  group('turning a mention into text and back', () {
    test('what is shown is @Name, and sending puts the IDs back', () {
      final stored =
          'hi ${mentionToken('Alice', aliceId)} and ${mentionToken('Bob', bobId)}!';
      final shown = decodeMentions(stored);
      expect(shown.text, 'hi @Alice and @Bob!');
      expect(shown.mentions, {'@Alice': aliceId, '@Bob': bobId});
      expect(encodeMentions(shown.text, shown.mentions), stored);
    });

    test('only whole names count', () {
      final map = {'@Alice': aliceId};
      expect(encodeMentions('@Alicia', map), '@Alicia');
      expect(encodeMentions('mail@Alice', map), 'mail@Alice');
      expect(
        encodeMentions('@Alice, hi', map),
        '${mentionToken('Alice', aliceId)}, hi',
      );
      expect(
        encodeMentions('(@Alice)', map),
        '(${mentionToken('Alice', aliceId)})',
      );
    });

    test('the longest name wins', () {
      final map = {'@Sam': sam1, '@Sam Jones': sam2};
      expect(
        encodeMentions('@Sam Jones and @Sam', map),
        '${mentionToken('Sam Jones', sam2)} and ${mentionToken('Sam', sam1)}',
      );
    });

    test('a name that was edited away is not a mention', () {
      final map = {'@Alice': aliceId};
      expect(encodeMentions('hi Alice', map), 'hi Alice');
      expect(encodeMentions('hi @Ali', map), 'hi @Ali');
    });

    test('works with names that are not plain ASCII or have symbols', () {
      final map = {'@Zoë': aliceId, '@A.B (x)': bobId};
      expect(map.keys.last, '@A.B (x)');
      expect(
        encodeMentions('@Zoë!', {'@Zoë': aliceId}),
        '${mentionToken('Zoë', aliceId)}!',
      );
      expect(encodeMentions('@Zoëx', {'@Zoë': aliceId}), '@Zoëx');
    });

    test('one name for two people keeps the second as it is stored', () {
      final stored =
          '${mentionToken('Sam', sam1)} ${mentionToken('Sam', sam2)}';
      final shown = decodeMentions(stored);
      expect(shown.text, '@Sam ${mentionToken('Sam', sam2)}');
      expect(shown.mentions, {'@Sam': sam1});
    });

    test('a message without any is left alone', () {
      final shown = decodeMentions('plain text @here');
      expect(shown.text, 'plain text @here');
      expect(shown.mentions, isEmpty);
      expect(encodeMentions('plain text @here', {}), 'plain text @here');
    });
  });

  group('as Markdown', () {
    test('the name inside is not touched', () {
      final token = mentionToken('a__b *c*', aliceId);
      expect(prepareChatMarkdown('hi $token'), 'hi $token');
      expect(prepareChatMarkdown('2*3*4 $token'), contains(token));
    });

    test('becomes a mention, not a link', () {
      final doc = md.Document(
        extensionSet: chatMarkdownExtensions,
        encodeHtml: false,
      );
      final nodes = doc.parseInline('hi ${mentionToken('Alice', aliceId)}!');
      final elements = nodes.whereType<md.Element>().toList();
      expect(elements, hasLength(1));
      expect(elements.single.tag, 'mention');
      expect(elements.single.textContent, 'Alice');
      expect(elements.single.attributes['id'], aliceId);
    });

    test('other Markdown around it still works', () {
      final doc = md.Document(extensionSet: chatMarkdownExtensions);
      final nodes = doc.parseInline(
        '**bold** ${mentionToken('Alice', aliceId)} [site](https://example.com)',
      );
      expect(nodes.whereType<md.Element>().map((e) => e.tag), [
        'strong',
        'mention',
        'a',
      ]);
    });
  });

  group('in the chat list', () {
    InboxController inboxWith(String id) => InboxController()
      ..hasLoadedOnce = true
      ..inbox = [
        InboxItem(
          id: id,
          title: 'Crew',
          lastMessage: 'x',
          timestamp: DateTime(2026),
          isGroup: true,
        ),
      ];

    test('a mention is noted with the unread message', () {
      final inbox = inboxWith('g1');
      inbox.updateLocalInboxState(
        'g1',
        'hi',
        DateTime(2026),
        true,
        mentionsMe: true,
      );
      expect(inbox.isMentioned('g1'), isTrue);
      expect(inbox.isMentioned('G1'), isTrue);
    });

    test('a read message does not count', () {
      final inbox = inboxWith('g1');
      inbox.updateLocalInboxState(
        'g1',
        'hi',
        DateTime(2026),
        false,
        mentionsMe: true,
      );
      expect(inbox.isMentioned('g1'), isFalse);
    });

    test('is dropped once the chat is read', () {
      final inbox = inboxWith('g1');
      inbox.updateLocalInboxState(
        'g1',
        'hi',
        DateTime(2026),
        true,
        mentionsMe: true,
      );
      inbox.clearUnread('g1');
      expect(inbox.isMentioned('g1'), isFalse);
    });

    group('from the server', () {
      Future<InboxController> receive(
        Map<String, dynamic> extra, {
        String text = '',
        String chat = 'g1',
      }) async {
        final inbox = inboxWith(chat);
        final handler = ChatEventHandler(
          inboxController: inbox,
          activeChatController: TestChat(),
          currentUserIdProvider: () => meId,
        );
        await handler.handleIncomingEvent({
          'type': 'chat',
          'message_id': 'm1',
          'sender_id': bobId,
          'timestamp': DateTime(2026).toIso8601String(),
          'content': MessageEnvelope.plain(text),
          ...extra,
        });
        return inbox;
      }

      test('a group message that mentions you is noted', () async {
        final inbox = await receive({
          'group_id': 'g1',
        }, text: 'hi ${mentionToken('Me', meId.toUpperCase())}');
        expect(inbox.isMentioned('g1'), isTrue);
        expect(inbox.inbox.single.lastMessage, 'hi @Me');
      });

      test('one that mentions someone else is not', () async {
        final inbox = await receive({
          'group_id': 'g1',
        }, text: 'hi ${mentionToken('Alice', aliceId)}');
        expect(inbox.isMentioned('g1'), isFalse);
      });

      test('a direct message is not, whatever it says', () async {
        final inbox = await receive(
          {},
          text: 'hi ${mentionToken('Me', meId)}',
          chat: bobId,
        );
        expect(inbox.isMentioned(bobId), isFalse);
        expect(inbox.inbox.single.unreadCount, 1, reason: 'it did arrive');
      });

      test('one that mentions nobody is not', () async {
        final inbox = await receive({'group_id': 'g1'}, text: 'hi all');
        expect(inbox.isMentioned('g1'), isFalse);
      });
    });
  });

  group('in a group chat', () {
    final members = [
      member(meId, 'Me', 'me.0000'),
      member(aliceId, 'Alice', 'alice.1111'),
      member(bobId, 'Bob', 'bob.2222'),
    ];

    Future<TestChat> show(
      WidgetTester tester, {
      List<Message> messages = const [],
      List<GroupMember>? people,
      bool isGroup = true,
      TestChat? chat,
    }) =>
        showTestChat(
          tester,
          messages: messages,
          chatId: 'g1',
          isGroup: isGroup,
          chat: chat,
          members: people ?? members,
          auth: TestAuth(meId),
        ).then((c) async {
          await tester.pumpAndSettle();
          return c;
        });

    /// Types [text] with the cursor at its end, as a keyboard does.
    Future<void> type(WidgetTester tester, String text) async {
      await tester.showKeyboard(find.byType(TextField).last);
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        ),
      );
      // The list above the box takes a moment to open.
      await tester.pumpAndSettle();
    }

    Finder suggestion(String id) => find.byKey(ValueKey('mention-$id'));

    String boxText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField).last).controller!.text;

    testWidgets('typing @ offers the other members', (tester) async {
      await show(tester);
      await type(tester, '@');
      expect(suggestion(aliceId), findsOneWidget);
      expect(suggestion(bobId), findsOneWidget);
      expect(suggestion(meId), findsNothing, reason: 'not yourself');
    });

    testWidgets('narrows as you type, by name or username', (tester) async {
      await show(tester);
      await type(tester, 'hello @al');
      expect(suggestion(aliceId), findsOneWidget);
      expect(suggestion(bobId), findsNothing);

      await type(tester, 'hello @bob.2');
      expect(suggestion(bobId), findsOneWidget);
      expect(suggestion(aliceId), findsNothing);

      await type(tester, 'hello @zzz');
      expect(suggestion(bobId), findsNothing);
    });

    testWidgets('an @ in the middle of a word is not a mention', (
      tester,
    ) async {
      await show(tester);
      await type(tester, 'write to alice@al');
      expect(suggestion(aliceId), findsNothing);
    });

    testWidgets('goes away after a space or when the @ is gone', (
      tester,
    ) async {
      await show(tester);
      await type(tester, '@Alice ');
      expect(suggestion(aliceId), findsNothing);
      await type(tester, '@');
      expect(suggestion(aliceId), findsOneWidget);
      await type(tester, 'hello');
      expect(suggestion(aliceId), findsNothing);
    });

    testWidgets('a name of two words still shows after the first one', (
      tester,
    ) async {
      await show(tester, people: [member(sam1, 'Sam Jones', 'sam.j')]);
      await type(tester, '@sam');
      expect(suggestion(sam1), findsOneWidget);
      await type(tester, '@sam ');
      expect(suggestion(sam1), findsNothing, reason: 'a space ends it');
    });

    testWidgets('are only for groups', (tester) async {
      await show(tester, isGroup: false);
      await type(tester, '@');
      expect(suggestion(aliceId), findsNothing);
    });

    testWidgets('picking writes @Name, and the message goes by ID', (
      tester,
    ) async {
      final chat = await show(tester);
      await type(tester, 'hey @al');
      await tester.tap(suggestion(aliceId));
      await tester.pump();
      expect(boxText(tester), 'hey @Alice ');
      expect(suggestion(aliceId), findsNothing);

      await type(tester, 'hey @Alice, come here');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(
        chat.sent.single.text,
        'hey ${mentionToken('Alice', aliceId)}, come here',
      );
    });

    testWidgets('a mention that was edited away is sent as typed', (
      tester,
    ) async {
      final chat = await show(tester);
      await type(tester, '@al');
      await tester.tap(suggestion(aliceId));
      await tester.pump();
      await type(tester, 'never mind alice');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.single.text, 'never mind alice');
    });

    testWidgets('a mention is not remembered for the next message', (
      tester,
    ) async {
      final chat = await show(tester);
      await type(tester, '@al');
      await tester.tap(suggestion(aliceId));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      await type(tester, 'typing @Alice by hand');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.first.text, contains(aliceId));
      expect(chat.sent.last.text, 'typing @Alice by hand');
    });

    testWidgets('two people with the same name are told apart by username', (
      tester,
    ) async {
      final chat = await show(
        tester,
        people: [
          member(sam1, 'Sam', 'sam.one'),
          member(sam2, 'Sam', 'sam.two'),
        ],
      );
      await type(tester, '@sam');
      expect(suggestion(sam1), findsOneWidget);
      expect(suggestion(sam2), findsOneWidget);
      await tester.tap(suggestion(sam2));
      await tester.pump();
      expect(boxText(tester), '@sam.two ');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.single.text, mentionToken('sam.two', sam2));
    });

    testWidgets('editing shows @Name and saves the ID', (tester) async {
      final mine = testMessage(
        'm1',
        'hi ${mentionToken('Alice', aliceId)}',
        sender: 'me',
      );
      final chat = await show(tester, messages: [mine]);
      await tester.longPress(find.text('@Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(boxText(tester), 'hi @Alice');

      await type(tester, 'hi @Alice, and welcome');
      await tester.tap(find.byIcon(Icons.check_rounded).last);
      await tester.pumpAndSettle();
      expect(
        chat.edited.single.$2,
        'hi ${mentionToken('Alice', aliceId)}, and welcome',
      );
    });

    testWidgets('replying to a mention quotes it as plain text', (
      tester,
    ) async {
      await show(
        tester,
        messages: [
          testMessage(
            'm1',
            'hi ${mentionToken('Alice', aliceId)}',
            sender: bobId,
          ),
        ],
      );
      await tester.longPress(find.text('@Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.text('hi @Alice'), findsOneWidget);
      expect(find.textContaining(aliceId), findsNothing);
    });

    testWidgets('a draft keeps the mention', (tester) async {
      final store = MemoryDrafts();
      Drafts.instance = Drafts(store: store);
      addTearDown(() => Drafts.instance = Drafts());

      await show(tester);
      await type(tester, '@al');
      await tester.tap(suggestion(aliceId));
      await tester.pump();
      await type(tester, 'ask @Alice later');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        store.saved['g1']!.text,
        'ask ${mentionToken('Alice', aliceId)} later',
      );

      await show(tester);
      expect(boxText(tester), 'ask @Alice later');
      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
    });
  });

  group('in a message', () {
    final members = [
      member(meId, 'Me', 'me.0000'),
      member(aliceId, 'Alicia', 'alice.1111'),
    ];

    Future<void> show(WidgetTester tester, String content) => showTestChat(
      tester,
      messages: [testMessage('m1', content, sender: bobId)],
      chatId: 'g1',
      isGroup: true,
      members: members,
      auth: TestAuth(meId),
    );

    testWidgets('shows the name the member has now', (tester) async {
      await show(tester, 'hello ${mentionToken('Alice', aliceId)}!');
      await tester.pumpAndSettle();
      expect(find.text('@Alicia'), findsOneWidget);
      expect(find.text('@Alice'), findsNothing);
    });

    testWidgets('marks a mention of you', (tester) async {
      final semantics = tester.ensureSemantics();
      await show(
        tester,
        'hello ${mentionToken('Me', meId)} and ${mentionToken('Alice', aliceId)}',
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Mentions you'), findsOneWidget);
      expect(find.bySemanticsLabel('Mention of Alicia'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('tapping one opens that member', (tester) async {
      await show(tester, 'hello ${mentionToken('Alice', aliceId)}');
      await tester.pumpAndSettle();
      await tester.tap(find.text('@Alicia'));
      await tester.pumpAndSettle();
      final page = tester.widget<ChatDetailsPage>(find.byType(ChatDetailsPage));
      expect(page.chatId, aliceId);
      expect(page.chatName, 'Alicia');
      expect(page.username, 'alice.1111');
      expect(page.isGroup, isFalse);
      expect(page.openedFromGroup, isTrue);
    });

    testWidgets('tapping yourself does nothing', (tester) async {
      await show(tester, 'hello ${mentionToken('Me', meId)}');
      await tester.pumpAndSettle();
      await tester.tap(find.text('@Me'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsPage), findsNothing);
    });

    testWidgets('someone who left says so', (tester) async {
      await show(tester, 'hello ${mentionToken('Gone', bobId)}');
      await tester.pumpAndSettle();
      await tester.tap(find.text('@Gone'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatDetailsPage), findsNothing);
      expect(
        find.text('That person is no longer in this group.'),
        findsOneWidget,
      );
    });

    testWidgets('is read as text by apps that do not know mentions', (
      tester,
    ) async {
      // What an older app would be given: the same Markdown, as a link.
      final doc = md.Document();
      final nodes = doc.parseInline('hello ${mentionToken('Alice', aliceId)}');
      expect(nodes.whereType<md.Element>().single.tag, 'a');
    });
  });

  group('on the home screen', () {
    InboxController inboxWith(String id) => InboxController()
      ..hasLoadedOnce = true
      ..inbox = [
        InboxItem(
          id: id,
          title: 'Crew',
          lastMessage: 'x',
          timestamp: DateTime(2026),
          isGroup: true,
        ),
      ];

    testWidgets('the chat shows an @ while a mention is unread', (
      tester,
    ) async {
      final inbox = inboxWith('g1');
      inbox.inbox.single.unreadCount = 2;
      await tester.pumpWidget(
        MultiProviderApp(
          inbox: inbox,
          child: ConversationTile(
            conversation: inbox.inbox.single,
            onTap: () {},
          ),
        ),
      );
      expect(find.text('@'), findsNothing);
      inbox.updateLocalInboxState(
        'g1',
        'hi',
        DateTime(2026),
        true,
        mentionsMe: true,
      );
      await tester.pump();
      expect(find.text('@'), findsOneWidget);
      inbox.clearUnread('g1');
      await tester.pump();
      expect(find.text('@'), findsNothing);
      // The group's members are asked for, in the background.
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
