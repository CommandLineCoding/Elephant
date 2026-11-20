import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/services/drafts.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/home_page_widgets.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

/// Drafts kept in memory, like the database does.
class MemoryDrafts implements DraftStore {
  final Map<String, Draft> saved = {};
  Object? failWith;
  Completer<void>? holdReads;
  int reads = 0;

  @override
  Future<Map<String, Draft>> all() async {
    reads++;
    await holdReads?.future;
    if (failWith != null) throw failWith!;
    return {...saved};
  }

  @override
  Future<void> save(String chatId, Draft draft) async {
    if (failWith != null) throw failWith!;
    saved[chatId] = draft;
  }

  @override
  Future<void> delete(String chatId) async {
    if (failWith != null) throw failWith!;
    saved.remove(chatId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  late MemoryDrafts store;
  setUp(() {
    store = MemoryDrafts();
    Drafts.instance = Drafts(store: store);
  });
  tearDown(() => Drafts.instance = Drafts());

  group('the drafts', () {
    test('keeps and drops one per chat, without regard to case', () async {
      final drafts = Drafts.instance;
      await drafts.save('U2', 'hello', replyToId: 'm1');
      expect(drafts.of('u2')!.text, 'hello');
      expect(drafts.of('u2')!.replyToId, 'm1');
      expect(store.saved.keys, ['u2']);

      await drafts.save('u2', 'hello again');
      expect(drafts.of('U2')!.text, 'hello again');
      expect(drafts.of('u2')!.replyToId, isNull);

      await drafts.clear('U2');
      expect(drafts.of('u2'), isNull);
      expect(store.saved, isEmpty);
    });

    test('text of only spaces is no draft', () async {
      final drafts = Drafts.instance;
      await drafts.save('u2', 'hello');
      await drafts.save('u2', '  \n ');
      expect(drafts.of('u2'), isNull);
      expect(store.saved, isEmpty);
    });

    test('tells listeners only when something changed', () async {
      final drafts = Drafts.instance;
      var changes = 0;
      drafts.addListener(() => changes++);
      await drafts.save('u2', 'a');
      await drafts.save('u2', 'a');
      expect(changes, 1);
      await drafts.save('u2', 'a', replyToId: 'm1');
      expect(changes, 2);
      await drafts.clear('u2');
      await drafts.clear('u2');
      expect(changes, 3);
    });

    test('reads the saved ones once, and keeps what was typed since', () async {
      store.saved['u2'] = const Draft('old');
      store.saved['u3'] = const Draft('other');
      final drafts = Drafts.instance;
      store.holdReads = Completer();
      final loading = drafts.load();
      await drafts.save('u2', 'new');
      store.holdReads!.complete();
      await loading;
      await drafts.load();
      expect(store.reads, 1);
      expect(drafts.of('u2')!.text, 'new');
      expect(drafts.of('u3')!.text, 'other');
    });

    test(
      'a store that fails does not lose the draft or break typing',
      () async {
        store.failWith = Exception('disk full');
        final drafts = Drafts.instance;
        await drafts.save('u2', 'still here');
        expect(drafts.of('u2')!.text, 'still here');
        await drafts.load();
        expect(drafts.of('u2')!.text, 'still here');
        await drafts.clear('u2');
        expect(drafts.of('u2'), isNull);
      },
    );

    test('a failed first read is tried again', () async {
      store.saved['u2'] = const Draft('kept');
      store.failWith = Exception('locked');
      final drafts = Drafts.instance;
      await drafts.load();
      expect(drafts.of('u2'), isNull);
      store.failWith = null;
      await drafts.load();
      expect(drafts.of('u2')!.text, 'kept');
    });

    test('is forgotten at sign-out', () async {
      final drafts = Drafts.instance;
      await drafts.save('u2', 'secret');
      drafts.reset();
      expect(drafts.of('u2'), isNull);
    });
  });

  group('in the chat list', () {
    InboxItem item({bool mine = false}) => InboxItem(
      id: 'u2',
      title: 'Bob',
      username: 'bob.1234',
      lastMessage: 'last message',
      lastMessageSender: mine ? 'me' : 'u2',
      timestamp: DateTime(2026),
      isGroup: false,
    );

    Future<void> show(WidgetTester tester, InboxItem chat) async {
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [chat];
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(create: (_) => AuthState()),
            ChangeNotifierProvider.value(value: inbox),
            ChangeNotifierProvider(create: (_) => GroupDetailsController()),
          ],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: Scaffold(
              body: ConversationTile(conversation: chat, onTap: () {}),
            ),
          ),
        ),
      );
    }

    testWidgets('shows the last message when there is no draft', (
      tester,
    ) async {
      await show(tester, item());
      expect(find.textContaining('last message'), findsOneWidget);
      expect(find.textContaining('Draft'), findsNothing);
    });

    testWidgets('shows a draft in red instead, and follows changes', (
      tester,
    ) async {
      await show(tester, item(mine: true));
      expect(find.byType(DeliveryTick), findsOneWidget);

      await Drafts.instance.save('u2', 'half a thought\nacross lines');
      await tester.pump();
      expect(
        find.textContaining('Draft: half a thought across lines'),
        findsOneWidget,
      );
      expect(find.textContaining('last message'), findsNothing);
      expect(find.byType(DeliveryTick), findsNothing);

      final rich = tester.widget<RichText>(
        find.textContaining('Draft: ', findRichText: true),
      );
      final spans = <TextSpan>[];
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == 'Draft: ') spans.add(span);
        return true;
      });
      expect(
        spans.single.style!.color,
        AppThemes.getTheme(ThemeType.frost).colorScheme.error,
      );

      await Drafts.instance.clear('u2');
      await tester.pump();
      expect(find.textContaining('last message'), findsOneWidget);
      expect(find.byType(DeliveryTick), findsOneWidget);
    });
  });

  group('in the chat', () {
    final theirs = testMessage('m1', 'their question');

    Future<void> open(WidgetTester tester) =>
        showTestChat(tester, messages: [theirs]);

    Future<void> leave(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField).last, text);
      await tester.pump();
    }

    Future<void> reply(WidgetTester tester) async {
      await tester.longPress(find.text('their question'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
    }

    String boxText(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField).last).controller!.text;

    testWidgets('leaving keeps what was typed, and it comes back', (
      tester,
    ) async {
      await open(tester);
      await tester.pumpAndSettle();
      await type(tester, 'not done yet');
      await leave(tester);
      expect(store.saved['u2']!.text, 'not done yet');
      expect(store.saved['u2']!.replyToId, isNull);

      await open(tester);
      await tester.pumpAndSettle();
      expect(boxText(tester), 'not done yet');
    });

    testWidgets('the message being replied to comes back too', (tester) async {
      await open(tester);
      await tester.pumpAndSettle();
      await reply(tester);
      await type(tester, 'my answer');
      await leave(tester);
      expect(store.saved['u2']!.replyToId, 'm1');

      await open(tester);
      await tester.pumpAndSettle();
      expect(boxText(tester), 'my answer');
      expect(find.text('Replying to Bob'), findsOneWidget);
    });

    testWidgets('a reply to a message that is gone comes back as text', (
      tester,
    ) async {
      store.saved['u2'] = const Draft('still here', replyToId: 'vanished');
      await open(tester);
      await tester.pumpAndSettle();
      expect(boxText(tester), 'still here');
      expect(find.textContaining('Replying to'), findsNothing);
    });

    testWidgets('is saved while typing, not only on leaving', (tester) async {
      await open(tester);
      await tester.pumpAndSettle();
      await type(tester, 'typing');
      expect(store.saved, isEmpty, reason: 'waits for a pause');
      await tester.pump(const Duration(milliseconds: 900));
      expect(store.saved['u2']!.text, 'typing');
    });

    testWidgets('emptying the box drops the draft', (tester) async {
      store.saved['u2'] = const Draft('old');
      await open(tester);
      await tester.pumpAndSettle();
      await type(tester, '');
      await leave(tester);
      expect(store.saved, isEmpty);
    });

    testWidgets('sending clears it', (tester) async {
      store.saved['u2'] = const Draft('to send');
      final chat = await showTestChat(tester, messages: [theirs]);
      await tester.pumpAndSettle();
      expect(boxText(tester), 'to send');

      await tester.tap(find.byIcon(Icons.arrow_upward_rounded).last);
      await tester.pumpAndSettle();
      expect(chat.sent.single.text, 'to send');
      expect(store.saved, isEmpty);
      await leave(tester);
      expect(store.saved, isEmpty);
    });

    testWidgets('leaving before it was read does not wipe it', (tester) async {
      store.saved['u2'] = const Draft('precious');
      store.holdReads = Completer();
      await open(tester);
      await tester.pump();
      await leave(tester);
      store.holdReads!.complete();
      await tester.pump();
      expect(store.saved['u2']!.text, 'precious');
    });

    testWidgets('editing does not become the draft, and the draft returns', (
      tester,
    ) async {
      final mine = testMessage('m2', 'typo here', sender: 'me');
      await showTestChat(tester, messages: [theirs, mine]);
      await tester.pumpAndSettle();
      await type(tester, 'half written');

      await tester.longPress(find.text('typo here'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(boxText(tester), 'typo here');
      await tester.pump(const Duration(milliseconds: 900));
      expect(store.saved['u2']?.text, isNot('typo here'));

      await tester.tap(find.byTooltip('Cancel'));
      await tester.pumpAndSettle();
      expect(boxText(tester), 'half written');
      await leave(tester);
      expect(store.saved['u2']!.text, 'half written');
    });
  });
}
