import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/chat_prefs.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/pages/home/archived_chats_page.dart';
import 'package:mobile/pages/home/home_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/services/push/push_notifier.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

InboxItem chat(
  String id,
  String title, {
  int unread = 0,
  bool group = false,
  int minutesAgo = 0,
}) => InboxItem(
  id: id,
  title: title,
  username: group ? null : '${title.toLowerCase()}.1234',
  lastMessage: 'last message from $title',
  timestamp: DateTime.now().subtract(Duration(minutes: minutesAgo)),
  isGroup: group,
  unreadCount: unread,
);

InboxController inboxOf(List<InboxItem> items) => InboxController()
  ..hasLoadedOnce = true
  ..inbox = items;

List<String> ids(List<InboxItem> items) => [for (final i in items) i.id];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the settings of a chat', () {
    test('nothing set is the default', () {
      expect(ChatPrefs.none.isDefault, isTrue);
      expect(ChatPrefs.none.isMuted(), isFalse);
      expect(const ChatPrefs(archived: true).isDefault, isFalse);
      expect(ChatPrefs(pinnedAt: DateTime(2026)).isPinned, isTrue);
    });

    test('muting lasts until a time, or for ever', () {
      final soon = ChatPrefs(
        mutedUntil: DateTime.now().add(const Duration(hours: 1)),
      );
      final over = ChatPrefs(
        mutedUntil: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      expect(soon.isMuted(), isTrue);
      expect(over.isMuted(), isFalse);
      expect(
        soon.isMuted(DateTime.now().add(const Duration(hours: 2))),
        isFalse,
      );
      expect(ChatPrefs(mutedUntil: ChatPrefs.forever).isMuted(), isTrue);
      expect(ChatPrefs(mutedUntil: ChatPrefs.forever).mutedForever, isTrue);
      expect(soon.mutedForever, isFalse);
    });

    test('round-trips through a database row', () {
      final prefs = ChatPrefs(
        pinnedAt: DateTime.fromMillisecondsSinceEpoch(1000),
        archived: true,
        mutedUntil: ChatPrefs.forever,
      );
      final back = ChatPrefs.fromRow(prefs.toRow('abc'));
      expect(back.pinnedAt, prefs.pinnedAt);
      expect(back.archived, isTrue);
      expect(back.mutedUntil, ChatPrefs.forever);
      expect(prefs.toRow('abc')['chat_id'], 'abc');
      expect(ChatPrefs.fromRow({'chat_id': 'x'}).isDefault, isTrue);
    });
  });

  group('pinning', () {
    test('puts a chat on top, and unpinning puts it back', () async {
      final inbox = inboxOf([chat('a', 'A'), chat('b', 'B'), chat('c', 'C')]);
      expect(ids(inbox.chats), ['a', 'b', 'c']);

      expect(await inbox.setPinned('c', true), isNull);
      expect(ids(inbox.chats), ['c', 'a', 'b']);
      expect(inbox.prefsOf('c').isPinned, isTrue);

      await inbox.setPinned('c', false);
      expect(ids(inbox.chats), ['a', 'b', 'c']);
    });

    test('only three at a time', () async {
      final inbox = inboxOf([for (final i in 'abcd'.split('')) chat(i, i)]);
      for (final id in ['a', 'b', 'c']) {
        expect(await inbox.setPinned(id, true), isNull);
      }
      final error = await inbox.setPinned('d', true);
      expect(error, contains('up to 3'));
      expect(inbox.prefsOf('d').isPinned, isFalse);

      await inbox.setPinned('a', false);
      expect(await inbox.setPinned('d', true), isNull);
    });

    test('pinned chats keep the list\'s order among themselves', () async {
      final inbox = inboxOf([
        chat('a', 'A'),
        chat('b', 'B'),
        chat('c', 'C'),
        chat('d', 'D'),
      ]);
      await inbox.setPinned('d', true);
      await inbox.setPinned('b', true);
      expect(ids(inbox.chats), ['b', 'd', 'a', 'c']);
    });

    test('ids are matched without regard to case', () async {
      final inbox = inboxOf([chat('ABC', 'A')]);
      await inbox.setPinned('abc', true);
      expect(inbox.prefsOf('AbC').isPinned, isTrue);
    });

    test('pins apply to groups too', () async {
      final inbox = inboxOf([
        chat('g1', 'Crew', group: true),
        chat('g2', 'Club', group: true),
      ]);
      await inbox.setPinned('g2', true);
      expect(ids(inbox.shownGroups), ['g2', 'g1']);
    });
  });

  group('archiving', () {
    test('moves a chat out of the list and into Archived', () async {
      final inbox = inboxOf([chat('a', 'A'), chat('b', 'B')]);
      await inbox.setArchived('a', true);
      expect(ids(inbox.chats), ['b']);
      expect(ids(inbox.archivedChats), ['a']);

      await inbox.setArchived('a', false);
      expect(ids(inbox.chats), ['a', 'b']);
      expect(inbox.archivedChats, isEmpty);
    });

    test('archiving unpins', () async {
      final inbox = inboxOf([chat('a', 'A')]);
      await inbox.setPinned('a', true);
      await inbox.setArchived('a', true);
      expect(inbox.prefsOf('a').isPinned, isFalse);
      await inbox.setArchived('a', false);
      expect(inbox.prefsOf('a').isPinned, isFalse);
    });

    test('a new message leaves it archived, unless asked', () async {
      final inbox = inboxOf([chat('a', 'A'), chat('b', 'B')]);
      await inbox.setArchived('a', true);

      inbox.updateLocalInboxState('a', 'hello', DateTime.now(), true);
      expect(inbox.prefsOf('a').archived, isTrue);

      inbox.unarchiveOnMessage = true;
      inbox.updateLocalInboxState('a', 'hello again', DateTime.now(), true);
      expect(inbox.prefsOf('a').archived, isFalse);
    });

    test('a message I send does not unarchive it', () async {
      final inbox = inboxOf([chat('a', 'A')])..unarchiveOnMessage = true;
      await inbox.setArchived('a', true);
      inbox.updateLocalInboxState('a', 'mine', DateTime.now(), false);
      expect(inbox.prefsOf('a').archived, isTrue);
    });

    test('deleting a chat forgets its settings', () async {
      final inbox = inboxOf([chat('a', 'A')]);
      await inbox.setPinned('a', true);
      inbox.removeChat('a').ignore();
      expect(inbox.prefsOf('a').isPinned, isFalse);
    });
  });

  group('muting', () {
    test('for a while, for ever, and not any more', () async {
      final inbox = inboxOf([chat('a', 'A')]);
      await inbox.mute('a', duration: const Duration(hours: 8));
      expect(inbox.prefsOf('a').isMuted(), isTrue);
      expect(inbox.prefsOf('a').mutedForever, isFalse);

      await inbox.mute('a');
      expect(inbox.prefsOf('a').mutedForever, isTrue);

      await inbox.unmute('a');
      expect(inbox.prefsOf('a').isMuted(), isFalse);
    });

    test('muting keeps a chat where it is', () async {
      final inbox = inboxOf([chat('a', 'A'), chat('b', 'B')]);
      await inbox.mute('b');
      expect(ids(inbox.chats), ['a', 'b']);
    });

    test('archived and muted chats do not count towards the badge', () async {
      final inbox = inboxOf([
        chat('a', 'A', unread: 2),
        chat('b', 'B', unread: 1),
        chat('c', 'C', unread: 4),
        chat('d', 'D'),
      ]);
      expect(inbox.unreadChats, 3);
      await inbox.mute('b');
      expect(inbox.unreadChats, 2);
      await inbox.setArchived('c', true);
      expect(inbox.unreadChats, 1);
      await inbox.unmute('b');
      expect(inbox.unreadChats, 2);
    });

    test('an expired mute counts for nothing', () async {
      final inbox = inboxOf([chat('a', 'A', unread: 1)]);
      await inbox.mute('a', duration: const Duration(milliseconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(inbox.prefsOf('a').isMuted(), isFalse);
      expect(inbox.unreadChats, 1);
    });
  });

  group('notifications', () {
    InboxItem unreadChat(String id, int minutesAgo) =>
        chat(id, id, unread: 1, minutesAgo: minutesAgo);

    test('a muted chat does not notify, the others do', () {
      final due = chatsToNotify(
        [unreadChat('a', 1), unreadChat('B', 2), unreadChat('c', 3)],
        {},
        since: DateTime.now().subtract(const Duration(days: 1)),
        muted: {'b'},
      );
      expect(ids(due), ['a', 'c']);
    });

    test('nothing is muted by default', () {
      final due = chatsToNotify(
        [unreadChat('a', 1)],
        {},
        since: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(ids(due), ['a']);
    });
  });

  group('on the home screen', () {
    Future<InboxController> showHome(
      WidgetTester tester,
      List<InboxItem> items,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.reset);
      final inbox = inboxOf(items);
      final active = TestChat();
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(create: (_) => AuthState()),
            ChangeNotifierProvider.value(value: inbox),
            ChangeNotifierProvider<ActiveChatController>.value(value: active),
            ChangeNotifierProvider(create: (_) => GroupController()),
            ChangeNotifierProvider(create: (_) => ChatSearchController()),
            ChangeNotifierProvider(create: (_) => GroupDetailsController()),
            ChangeNotifierProvider(
              create: (_) => ChatConnectionController(
                eventHandler: ChatEventHandler(
                  inboxController: inbox,
                  activeChatController: active,
                  currentUserIdProvider: () => 'me',
                ),
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: const HomePage(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      return inbox;
    }

    /// The home screen never stops animating (the connection banner), so
    /// pumpAndSettle would never return.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> chooseFromMenu(
      WidgetTester tester,
      String chatTitle,
      String action,
    ) async {
      await tester.longPress(find.text(chatTitle));
      await settle(tester);
      await tester.tap(find.text(action));
      await settle(tester);
    }

    double top(WidgetTester tester, String title) =>
        tester.getTopLeft(find.text(title)).dy;

    testWidgets('Pin to top moves a chat up and marks it', (tester) async {
      await showHome(tester, [chat('a', 'Alice'), chat('b', 'Bruno')]);
      expect(top(tester, 'Alice'), lessThan(top(tester, 'Bruno')));
      expect(find.bySemanticsLabel('Pinned'), findsNothing);

      await chooseFromMenu(tester, 'Bruno', 'Pin to top');
      expect(top(tester, 'Bruno'), lessThan(top(tester, 'Alice')));
      expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);

      await chooseFromMenu(tester, 'Bruno', 'Unpin');
      expect(top(tester, 'Alice'), lessThan(top(tester, 'Bruno')));
      expect(find.byIcon(Icons.push_pin_rounded), findsNothing);
    });

    testWidgets('a fourth pin says there is no room', (tester) async {
      await showHome(tester, [
        for (final n in ['Alice', 'Bruno', 'Cleo', 'Dara']) chat(n, n),
      ]);
      for (final n in ['Alice', 'Bruno', 'Cleo']) {
        await chooseFromMenu(tester, n, 'Pin to top');
      }
      await chooseFromMenu(tester, 'Dara', 'Pin to top');
      expect(find.textContaining('up to 3'), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_rounded), findsNWidgets(3));
    });

    testWidgets('Archive moves a chat to the Archived row and page', (
      tester,
    ) async {
      await showHome(tester, [
        chat('a', 'Alice'),
        chat('b', 'Bruno', unread: 2),
      ]);
      expect(find.byType(ArchivedRow), findsNothing);

      await chooseFromMenu(tester, 'Bruno', 'Archive');
      expect(find.text('Bruno'), findsNothing);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.byType(ArchivedRow), findsOneWidget);
      expect(find.text('Archived'), findsOneWidget);

      await tester.tap(find.text('Archived'));
      await settle(tester);
      expect(find.byType(ArchivedChatsPage), findsOneWidget);
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);

      await chooseFromMenu(tester, 'Bruno', 'Unarchive');
      expect(find.text('No archived chats'), findsOneWidget);

      await tester.pageBack();
      await settle(tester);
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.byType(ArchivedRow), findsNothing);
    });

    testWidgets('with every chat archived, Archived is still reachable', (
      tester,
    ) async {
      await showHome(tester, [chat('a', 'Alice')]);
      await chooseFromMenu(tester, 'Alice', 'Archive');
      expect(find.text('Archived'), findsOneWidget);
      expect(find.text('No conversations yet'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
    });

    testWidgets('the Archived page can bring chats back on a new message', (
      tester,
    ) async {
      final inbox = await showHome(tester, [chat('a', 'Alice')]);
      await chooseFromMenu(tester, 'Alice', 'Archive');
      await tester.tap(find.text('Archived'));
      await settle(tester);

      expect(inbox.unarchiveOnMessage, isFalse);
      await tester.tap(find.text('Unarchive when a message arrives'));
      await settle(tester);
      expect(inbox.unarchiveOnMessage, isTrue);
    });

    testWidgets('searching finds archived chats too', (tester) async {
      await showHome(tester, [chat('a', 'Alice'), chat('b', 'Bruno')]);
      await chooseFromMenu(tester, 'Bruno', 'Archive');
      await tester.enterText(find.byType(TextField).first, 'bruno');
      await settle(tester);
      expect(find.text('Bruno'), findsOneWidget);
    });

    testWidgets('Mute asks how long, and shows it', (tester) async {
      final inbox = await showHome(tester, [chat('a', 'Alice', unread: 3)]);

      await chooseFromMenu(tester, 'Alice', 'Mute');
      expect(find.text('Mute notifications for…'), findsOneWidget);
      expect(find.text('8 hours'), findsOneWidget);
      expect(find.text('1 week'), findsOneWidget);
      expect(find.text('Always'), findsOneWidget);
      await tester.tap(find.text('1 week'));
      await settle(tester);

      expect(inbox.prefsOf('a').isMuted(), isTrue);
      final until = inbox.prefsOf('a').mutedUntil!;
      expect(
        until.difference(DateTime.now()).inDays,
        inInclusiveRange(6, 7),
        reason: 'a week from now',
      );
      expect(find.byIcon(Icons.notifications_off_rounded), findsOneWidget);

      await chooseFromMenu(tester, 'Alice', 'Unmute');
      expect(find.byIcon(Icons.notifications_off_rounded), findsNothing);
      expect(inbox.prefsOf('a').isMuted(), isFalse);
    });

    testWidgets('a muted chat\'s unread count is grey', (tester) async {
      await showHome(tester, [
        chat('a', 'Alice', unread: 3),
        chat('b', 'Bruno', unread: 5),
      ]);
      Color? badgeColor(String count) {
        final badge = find.ancestor(
          of: find.text(count),
          matching: find.byType(DecoratedBox),
        );
        return (tester.widget<DecoratedBox>(badge.first).decoration
                as BoxDecoration)
            .color;
      }

      final before = badgeColor('3');
      expect(badgeColor('5'), before, reason: 'both look the same unmuted');
      await chooseFromMenu(tester, 'Bruno', 'Mute');
      await tester.tap(find.text('Always'));
      await settle(tester);

      expect(badgeColor('3'), before);
      expect(badgeColor('5'), isNot(before));
    });

    testWidgets('Always and 8 hours', (tester) async {
      final inbox = await showHome(tester, [chat('a', 'Alice')]);
      await chooseFromMenu(tester, 'Alice', 'Mute');
      await tester.tap(find.text('8 hours'));
      await settle(tester);
      expect(
        inbox.prefsOf('a').mutedUntil!.difference(DateTime.now()).inHours,
        inInclusiveRange(7, 8),
      );

      await chooseFromMenu(tester, 'Alice', 'Unmute');
      await chooseFromMenu(tester, 'Alice', 'Mute');
      await tester.tap(find.text('Always'));
      await settle(tester);
      expect(inbox.prefsOf('a').mutedForever, isTrue);
    });

    testWidgets('an archived chat offers Unarchive, and no Pin', (
      tester,
    ) async {
      final inbox = await showHome(tester, [chat('a', 'Alice')]);
      inbox.setArchived('a', true).ignore();
      await tester.pump();
      await tester.tap(find.text('Archived'));
      await settle(tester);

      await tester.longPress(find.text('Alice'));
      await settle(tester);
      expect(find.text('Unarchive'), findsOneWidget);
      expect(find.text('Pin to top'), findsNothing);
    });

    testWidgets('groups can be pinned and muted in the Groups tab', (
      tester,
    ) async {
      final inbox = await showHome(tester, [
        chat('g1', 'Crew', group: true),
        chat('g2', 'Club', group: true),
      ]);
      await tester.tap(find.text('Groups').last);
      await settle(tester);
      expect(top(tester, 'Crew'), lessThan(top(tester, 'Club')));

      await chooseFromMenu(tester, 'Club', 'Pin to top');
      expect(top(tester, 'Club'), lessThan(top(tester, 'Crew')));
      expect(inbox.prefsOf('g2').isPinned, isTrue);
    });
  });
}
