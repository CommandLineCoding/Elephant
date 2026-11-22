import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/broadcast_list.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/message.dart';
import 'package:mobile/pages/broadcast/broadcast_lists_page.dart';
import 'package:mobile/pages/broadcast/broadcast_page.dart';
import 'package:mobile/pages/new%20chat/select_contact_page.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/broadcast_lists.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

class MemoryStore implements BroadcastListStore {
  final Map<String, (BroadcastList, int)> rows = {};
  bool failing = false;

  @override
  Future<List<BroadcastList>> all() async {
    if (failing) throw StateError('disk');
    final sorted = rows.values.toList()..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final r in sorted) r.$1];
  }

  @override
  Future<void> save(BroadcastList list, int position) async {
    if (failing) throw StateError('disk');
    rows[list.id] = (list, position);
  }

  @override
  Future<void> delete(String id) async {
    if (failing) throw StateError('disk');
    rows.remove(id);
  }
}

const ava = BroadcastMember(id: 'u-ava', name: 'Ava');
const ben = BroadcastMember(id: 'u-ben', name: 'Ben');
const cy = BroadcastMember(id: 'u-cy', name: 'Cy');

/// A chat that can't reach one person.
class FlakyChat extends TestChat {
  final Set<String> unreachable = {};

  @override
  Future<(String?, Message?)> sendTo(
    String targetId, {
    required bool isGroup,
    required String text,
    Message? replyingTo,
    bool silent = false,
  }) async {
    if (unreachable.contains(targetId)) return ('No encryption keys.', null);
    return super.sendTo(
      targetId,
      isGroup: isGroup,
      text: text,
      replyingTo: replyingTo,
      silent: silent,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  late MemoryStore store;
  late BroadcastLists lists;
  setUp(() {
    store = MemoryStore();
    lists = BroadcastLists(store: store);
    BroadcastLists.instance = lists;
  });

  group('the model', () {
    test('keeps its people through storage', () {
      final json = BroadcastList.encodeMembers([ava, ben]);
      final back = BroadcastList.decodeMembers(json);
      expect(back.map((m) => (m.id, m.name)), [
        ('u-ava', 'Ava'),
        ('u-ben', 'Ben'),
      ]);
    });

    test('a damaged row gives fewer people, not an error', () {
      expect(BroadcastList.decodeMembers('not json'), isEmpty);
      expect(BroadcastList.decodeMembers('{"a":1}'), isEmpty);
      expect(
        BroadcastList.decodeMembers('[{"id":"u1","name":"A"},{"x":1},5]'),
        hasLength(1),
      );
      expect(BroadcastList.decodeMembers('[{"id":"u1"}]').single.name, '');
    });
  });

  group('the lists', () {
    test('make a list, with its people, and keep it', () async {
      final (list, error) = await lists.create('  Hikers ', [ava, ben]);
      expect(error, isNull);
      expect(list!.name, 'Hikers');
      expect(lists.lists.single.members, hasLength(2));
      expect(store.rows[list.id]!.$1.name, 'Hikers');
    });

    test('refuse a list that makes no sense', () async {
      expect((await lists.create('', [ava])).$2, isNotNull);
      expect((await lists.create('   ', [ava])).$2, isNotNull);
      expect((await lists.create('Empty', [])).$2, contains('at least one'));
      expect(
        (await lists.create('x' * (BroadcastLists.maxNameLength + 1), [
          ava,
        ])).$2,
        contains('Keep the name'),
      );
      final many = [
        for (var i = 0; i <= BroadcastLists.maxMembers; i++)
          BroadcastMember(id: 'u$i', name: 'P$i'),
      ];
      expect((await lists.create('Big', many)).$2, contains('up to 50'));
      expect(lists.lists, isEmpty);
    });

    test('names are unique, ignoring case', () async {
      await lists.create('Hikers', [ava]);
      expect((await lists.create('hikers', [ben])).$2, contains('already'));
    });

    test('there is a limit to how many', () async {
      for (var i = 0; i < BroadcastLists.maxLists; i++) {
        expect((await lists.create('L$i', [ava])).$2, isNull);
      }
      expect((await lists.create('One more', [ava])).$2, contains('up to 20'));
    });

    test('the same person twice is once', () async {
      final (list, _) = await lists.create('Dupes', [
        ava,
        const BroadcastMember(id: 'U-AVA', name: 'Ava again'),
        ben,
      ]);
      expect(list!.members.map((m) => m.name), ['Ava', 'Ben']);
    });

    test('rename and change the people', () async {
      final (list, _) = await lists.create('Hikers', [ava]);
      await lists.create('Other', [ben]);
      expect(await lists.update(list!.id, 'Walkers', [ava, cy]), isNull);
      expect(lists.byId(list.id)!.name, 'Walkers');
      expect(lists.byId(list.id)!.members.map((m) => m.id), ['u-ava', 'u-cy']);
      expect(store.rows[list.id]!.$1.name, 'Walkers');
      // Keeping its own name is fine; taking another list's is not.
      expect(await lists.update(list.id, 'Walkers', [ava]), isNull);
      expect(await lists.update(list.id, 'other', [ava]), contains('already'));
      expect(await lists.update('nope', 'X', [ava]), contains('gone'));
    });

    test('delete', () async {
      final (list, _) = await lists.create('Hikers', [ava]);
      await lists.delete(list!.id);
      expect(lists.lists, isEmpty);
      expect(store.rows, isEmpty);
    });

    test(
      'a blocked person leaves every list, and an empty list goes',
      () async {
        final (both, _) = await lists.create('Both', [ava, ben]);
        final (only, _) = await lists.create('Only Ava', [ava]);
        await lists.forgetPerson('U-AVA');
        expect(lists.byId(both!.id)!.members.map((m) => m.id), ['u-ben']);
        expect(lists.byId(only!.id), isNull);
        expect(store.rows.keys, [both.id]);
      },
    );

    test('load once, and keep a list made while loading', () async {
      final other = BroadcastLists(store: store);
      await store.save(
        const BroadcastList(id: 'b1', name: 'Saved', members: [ava]),
        0,
      );
      final made = other.create('New', [ben]);
      await other.load();
      await made;
      expect(other.lists.map((l) => l.name), containsAll(['Saved', 'New']));
      await other.load();
      expect(other.lists, hasLength(2));
    });

    test('a store that fails does not break the lists in memory', () async {
      store.failing = true;
      final (list, error) = await lists.create('Hikers', [ava]);
      expect(error, isNull);
      expect(lists.byId(list!.id), isNotNull);
      await lists.load();
      await lists.delete(list.id);
      expect(lists.lists, isEmpty);
    });

    test('reset forgets them, at sign-out', () async {
      await lists.create('Hikers', [ava]);
      lists.reset();
      expect(lists.lists, isEmpty);
    });
  });

  group('in the app', () {
    Future<(FlakyChat, InboxController)> showBroadcast(
      WidgetTester tester,
      String listId,
    ) async {
      final chat = FlakyChat();
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [
          for (final m in [ava, ben, cy])
            InboxItem(
              id: m.id,
              title: m.name,
              lastMessage: 'hi',
              timestamp: DateTime(2026, 11, 22, 9),
              isGroup: false,
            ),
        ];
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<ActiveChatController>.value(value: chat),
            ChangeNotifierProvider.value(value: inbox),
          ],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: BroadcastPage(listId: listId),
          ),
        ),
      );
      return (chat, inbox);
    }

    testWidgets('a message goes to each person on their own', (tester) async {
      final (list, _) = await lists.create('Hikers', [ava, ben, cy]);
      final (chat, inbox) = await showBroadcast(tester, list!.id);
      expect(find.text('3 people'), findsOne);

      await tester.enterText(find.byType(TextField), 'Meet at 7');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(milliseconds: 50));

      expect(chat.sent.map((s) => s.targetId), ['u-ava', 'u-ben', 'u-cy']);
      expect(
        chat.sent.every((s) => s.text == 'Meet at 7' && !s.isGroup),
        isTrue,
      );
      expect(
        inbox.inbox.every((i) => i.lastMessage == 'Meet at 7'),
        isTrue,
        reason: 'each person\'s chat shows what was sent',
      );
      expect(find.text('Sent to 3 people'), findsOne);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('who could not be reached can be tried again', (tester) async {
      final (list, _) = await lists.create('Hikers', [ava, ben, cy]);
      final (chat, inbox) = await showBroadcast(tester, list!.id);
      chat.unreachable.add('u-ben');

      await tester.enterText(find.byType(TextField), 'Meet at 7');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining("Couldn't send to Ben"), findsOne);
      expect(find.text('Not sent to 1 person.'), findsOne);
      expect(chat.sent.map((s) => s.targetId), ['u-ava', 'u-cy']);
      String previewOf(String id) =>
          inbox.inbox.firstWhere((i) => i.id == id).lastMessage;
      expect(previewOf('u-ava'), 'Meet at 7');
      expect(previewOf('u-ben'), 'hi', reason: 'it never reached Ben');

      chat.unreachable.clear();
      await tester.tap(find.text('Try again'));
      await tester.pump(const Duration(milliseconds: 50));
      // Only Ben is sent to again.
      expect(chat.sent.map((s) => s.targetId), ['u-ava', 'u-cy', 'u-ben']);
      expect(find.textContaining('Not sent to'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('nothing is sent for a blank message', (tester) async {
      final (list, _) = await lists.create('Hikers', [ava]);
      final (chat, _) = await showBroadcast(tester, list!.id);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.send_rounded),
            )
            .onPressed,
        isNull,
      );
      expect(chat.sent, isEmpty);
    });

    testWidgets('deleting the list asks first, then goes back', (tester) async {
      final (list, _) = await lists.create('Hikers', [ava]);
      await showBroadcast(tester, list!.id);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete list'));
      await tester.pumpAndSettle();
      expect(find.text('Delete "Hikers"?'), findsOne);
      await tester.tap(find.text('Delete').last);
      await tester.pumpAndSettle();
      expect(lists.lists, isEmpty);
    });

    testWidgets('the lists page shows them, or says there are none', (
      tester,
    ) async {
      Future<void> show() => tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: const BroadcastListsPage(),
        ),
      );
      await show();
      expect(find.text('No broadcast lists'), findsOne);

      await lists.create('Hikers', [ava, ben]);
      await tester.pump();
      expect(find.text('Hikers'), findsOne);
      expect(find.text('2 people'), findsOne);
    });

    testWidgets('the row says how many', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Scaffold(
            body: BroadcastListsRow(count: 2, onTap: () => tapped++),
          ),
        ),
      );
      expect(find.text('Broadcast lists'), findsOne);
      expect(find.text('2'), findsOne);
      await tester.tap(find.text('Broadcast lists'));
      expect(tapped, 1);
    });

    Future<void> showPicker(WidgetTester tester, Widget page) async {
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [
          for (final m in [ava, ben, cy])
            InboxItem(
              id: m.id,
              title: m.name,
              username: '${m.name.toLowerCase()}.1234',
              lastMessage: 'hi',
              timestamp: DateTime(2026, 11, 22, 9),
              isGroup: false,
            ),
        ];
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: inbox),
            ChangeNotifierProvider(create: (_) => ChatSearchController()),
            ChangeNotifierProvider(create: (_) => GroupController()),
            ChangeNotifierProvider<ActiveChatController>(
              create: (_) => FlakyChat(),
            ),
          ],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => page),
                  ),
                  child: const Text('open picker'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open picker'));
      await tester.pumpAndSettle();
    }

    testWidgets('pick people, name the list, and it is made', (tester) async {
      await showPicker(tester, const SelectContactPage(forBroadcast: true));
      expect(find.text('New broadcast'), findsOne);
      await tester.tap(find.text('Ava'));
      await tester.tap(find.text('Cy'));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOne);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Name your list'), findsOne);
      await tester.enterText(find.byType(TextField).last, 'Hikers');
      await tester.pump();
      await tester.tap(find.text('Create list'));
      await tester.pumpAndSettle();

      final list = lists.lists.single;
      expect(list.name, 'Hikers');
      expect(list.members.map((m) => m.id), ['u-ava', 'u-cy']);
      // It opens the new list.
      expect(find.byType(BroadcastPage), findsOne);
    });

    testWidgets('editing starts from the people already on the list', (
      tester,
    ) async {
      final (list, _) = await lists.create('Hikers', [ava, ben]);
      await showPicker(tester, SelectContactPage(editing: list));
      expect(find.text('Edit list'), findsOne);
      expect(find.text('2 selected'), findsOne);
      await tester.tap(find.text('Cy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(lists.byId(list!.id)!.members.map((m) => m.id), [
        'u-ava',
        'u-ben',
        'u-cy',
      ]);
    });

    testWidgets('a name that is taken is explained, not saved', (tester) async {
      await lists.create('Hikers', [ava]);
      await showPicker(tester, const SelectContactPage(forBroadcast: true));
      await tester.tap(find.text('Ben'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'hikers');
      await tester.pump();
      await tester.tap(find.text('Create list'));
      await tester.pumpAndSettle();
      expect(find.text('You already have a list with that name.'), findsOne);
      expect(lists.lists, hasLength(1));
      // Leave the way people do, with the providers still there.
      Navigator.of(
        tester.element(find.byType(SelectContactPage)),
      ).popUntil((route) => route.isFirst);
      await tester.pumpAndSettle();
    });
  });
}
