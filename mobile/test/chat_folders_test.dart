import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/chat_connection_controller.dart';
import 'package:mobile/controllers/chat/chat_search_controller.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/chat_folder.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/pages/home/home_page.dart';
import 'package:mobile/pages/settings/chat_folders.dart';
import 'package:mobile/providers/group_controller_provider.dart';
import 'package:mobile/services/chat/chat_event_handler.dart';
import 'package:mobile/services/chat_folders.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

/// Folders kept in memory, like the database does.
class MemoryFolders implements ChatFolderStore {
  final Map<String, ChatFolder> saved = {};
  final Map<String, int> positions = {};
  Object? failWith;
  Completer<void>? holdReads;
  int reads = 0;

  @override
  Future<List<ChatFolder>> all() async {
    reads++;
    await holdReads?.future;
    if (failWith != null) throw failWith!;
    final list = saved.values.toList()
      ..sort((a, b) => positions[a.id]!.compareTo(positions[b.id]!));
    return list;
  }

  @override
  Future<void> save(ChatFolder folder, int position) async {
    if (failWith != null) throw failWith!;
    saved[folder.id] = folder;
    positions[folder.id] = position;
  }

  @override
  Future<void> delete(String id) async {
    if (failWith != null) throw failWith!;
    saved.remove(id);
  }
}

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

List<String> ids(List<InboxItem> items) => [for (final i in items) i.id];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  late MemoryFolders store;
  setUp(() {
    store = MemoryFolders();
    ChatFolders.instance = ChatFolders(store: store);
  });
  tearDown(() => ChatFolders.instance = ChatFolders());

  final chats = [
    chat('a', 'Alice', unread: 2),
    chat('b', 'Bruno'),
    chat('g', 'Crew', group: true, unread: 1),
    chat('h', 'Hikers', group: true),
  ];

  group('the filters', () {
    final work = const ChatFolder(id: 'f1', name: 'Work', chatIds: {'a', 'g'});

    test('All lets everything through', () {
      expect(ids(ChatFilter.apply(ChatFilter.all, chats, [])), [
        'a',
        'b',
        'g',
        'h',
      ]);
    });

    test('Unread keeps chats with unread messages', () {
      expect(ids(ChatFilter.apply(ChatFilter.unread, chats, [])), ['a', 'g']);
    });

    test('Groups keeps groups', () {
      expect(ids(ChatFilter.apply(ChatFilter.groups, chats, [])), ['g', 'h']);
    });

    test('a folder keeps its chats, in the order of the list', () {
      expect(ids(ChatFilter.apply('f1', chats, [work])), ['a', 'g']);
    });

    test('a folder finds chats without regard to case', () {
      final upper = [chat('ABC-1', 'Shouting')];
      const folder = ChatFolder(id: 'f1', name: 'x', chatIds: {'abc-1'});
      expect(ids(ChatFilter.apply('f1', upper, [folder])), ['ABC-1']);
    });

    test('a folder that is gone lets everything through', () {
      expect(ids(ChatFilter.apply('f9', chats, [work])), hasLength(4));
    });

    test('knows the built-in ones', () {
      expect(ChatFilter.isBuiltIn('all'), isTrue);
      expect(ChatFilter.isBuiltIn('unread'), isTrue);
      expect(ChatFilter.isBuiltIn('groups'), isTrue);
      expect(ChatFilter.isBuiltIn('f1'), isFalse);
    });
  });

  group('the folders', () {
    test('makes, renames and deletes, keeping them in the store', () async {
      final folders = ChatFolders.instance;
      expect(await folders.create('  Family ', {'A', 'b'}), isNull);
      final id = folders.folders.single.id;
      expect(folders.folders.single.name, 'Family');
      expect(folders.folders.single.chatIds, {'a', 'b'});
      expect(store.saved[id]!.name, 'Family');

      expect(await folders.update(id, 'Close family', {'c'}), isNull);
      expect(folders.byId(id)!.name, 'Close family');
      expect(folders.byId(id)!.chatIds, {'c'});
      expect(store.saved[id]!.chatIds, {'c'});

      await folders.delete(id);
      expect(folders.folders, isEmpty);
      expect(store.saved, isEmpty);
    });

    test('keeps the order they were made in', () async {
      final folders = ChatFolders.instance;
      await folders.create('One', {});
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await folders.create('Two', {});
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await folders.create('Three', {});
      expect(
        [for (final f in folders.folders) f.name],
        ['One', 'Two', 'Three'],
      );
      final again = ChatFolders(store: store);
      await again.load();
      expect([for (final f in again.folders) f.name], ['One', 'Two', 'Three']);
    });

    test('names must be there, short and different', () async {
      final folders = ChatFolders.instance;
      expect(await folders.create('   ', {}), isNotNull);
      expect(await folders.create('x' * 21, {}), isNotNull);
      expect(await folders.create('x' * 20, {}), isNull);
      expect(await folders.create('X' * 20, {}), contains('already'));
      expect(folders.folders, hasLength(1));
    });

    test('a folder can keep its own name when edited', () async {
      final folders = ChatFolders.instance;
      await folders.create('Work', {});
      final id = folders.folders.single.id;
      expect(await folders.update(id, 'Work', {'a'}), isNull);
      await folders.create('Home', {});
      expect(await folders.update(id, 'home', {}), contains('already'));
      expect(folders.byId(id)!.name, 'Work');
    });

    test('there is a limit', () async {
      final folders = ChatFolders.instance;
      for (var i = 0; i < ChatFolders.maxFolders; i++) {
        expect(await folders.create('Folder $i', {}), isNull);
      }
      expect(await folders.create('One more', {}), contains('up to'));
      expect(folders.folders, hasLength(ChatFolders.maxFolders));
    });

    test('editing a folder that is gone says so', () async {
      expect(await ChatFolders.instance.update('nope', 'x', {}), isNotNull);
    });

    test('a chat that is gone leaves every folder', () async {
      final folders = ChatFolders.instance;
      await folders.create('One', {'a', 'b'});
      await folders.create('Two', {'a'});
      await folders.create('Three', {'z'});
      var changes = 0;
      folders.addListener(() => changes++);
      await folders.forgetChat('A');
      expect(
        [for (final f in folders.folders) f.chatIds],
        [
          {'b'},
          <String>{},
          {'z'},
        ],
      );
      expect(store.saved[folders.folders.first.id]!.chatIds, {'b'});
      expect(changes, 1);
      await folders.forgetChat('nobody');
      expect(changes, 1);
    });

    test('removing a chat from the app takes it out of its folders', () async {
      await ChatFolders.instance.create('One', {'a', 'b'});
      final inbox = InboxController()..inbox = [chat('a', 'Alice')];
      // Not awaited: what follows is the cache, which needs a database.
      unawaited(inbox.removeChat('a').catchError((_) {}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ChatFolders.instance.folders.single.chatIds, {'b'});
    });

    test('reads the saved ones once, and keeps what was made since', () async {
      final first = ChatFolders(store: store);
      await first.create('Saved', {});
      final folders = ChatFolders.instance;
      store.holdReads = Completer();
      final loading = folders.load();
      await folders.create('New', {});
      store.holdReads!.complete();
      await loading;
      await folders.load();
      expect(store.reads, 1);
      expect([
        for (final f in folders.folders) f.name,
      ], containsAll(['Saved', 'New']));
      expect(folders.folders, hasLength(2));
    });

    test('a store that fails does not break them', () async {
      store.failWith = Exception('disk full');
      final folders = ChatFolders.instance;
      expect(await folders.create('Kept', {'a'}), isNull);
      expect(folders.folders.single.name, 'Kept');
      await folders.load();
      expect(folders.folders.single.name, 'Kept');
      await folders.delete(folders.folders.single.id);
      expect(folders.folders, isEmpty);
    });

    test('a failed first read is tried again', () async {
      await ChatFolders(store: store).create('Saved', {});
      store.failWith = Exception('locked');
      final folders = ChatFolders.instance;
      await folders.load();
      expect(folders.folders, isEmpty);
      store.failWith = null;
      await folders.load();
      expect(folders.folders.single.name, 'Saved');
    });

    test('are forgotten at sign-out', () async {
      final folders = ChatFolders.instance;
      await folders.create('One', {});
      folders.reset();
      expect(folders.folders, isEmpty);
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
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = items;
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

    Future<void> pick(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey('filter-$key')));
      await settle(tester);
    }

    testWidgets('the filters sit above the chats', (tester) async {
      await showHome(tester, chats);
      expect(find.byKey(const ValueKey('filter-all')), findsOneWidget);
      expect(find.text('Unread 2'), findsOneWidget);
      expect(find.byKey(const ValueKey('filter-groups')), findsOneWidget);
      for (final name in ['Alice', 'Bruno', 'Crew', 'Hikers']) {
        expect(find.text(name), findsOneWidget);
      }
      // The group tiles ask for their members.
      await settle(tester);
    });

    testWidgets('are not shown when there are no chats', (tester) async {
      await showHome(tester, []);
      expect(find.byKey(const ValueKey('filter-all')), findsNothing);
      expect(find.byKey(const ValueKey('filter-unread')), findsNothing);
    });

    testWidgets('Unread shows only chats with unread messages', (tester) async {
      await showHome(tester, chats);
      await pick(tester, ChatFilter.unread);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Crew'), findsOneWidget);
      expect(find.text('Bruno'), findsNothing);
      expect(find.text('Hikers'), findsNothing);
    });

    testWidgets('Groups shows only groups', (tester) async {
      await showHome(tester, chats);
      await pick(tester, ChatFilter.groups);
      expect(find.text('Crew'), findsOneWidget);
      expect(find.text('Hikers'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
    });

    testWidgets('a folder shows its chats, and All brings them back', (
      tester,
    ) async {
      await ChatFolders.instance.create('Work', {'b', 'h'});
      final id = ChatFolders.instance.folders.single.id;
      await showHome(tester, chats);
      await settle(tester);
      await pick(tester, id);
      expect(find.text('Bruno'), findsOneWidget);
      expect(find.text('Hikers'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);

      await pick(tester, ChatFilter.all);
      expect(find.text('Alice'), findsOneWidget);
    });

    testWidgets('a filter with nothing in it says so', (tester) async {
      await showHome(tester, [chat('b', 'Bruno')]);
      await pick(tester, ChatFilter.unread);
      expect(find.text('All caught up'), findsOneWidget);
      await pick(tester, ChatFilter.groups);
      expect(find.text('No groups'), findsOneWidget);
      expect(find.text('Bruno'), findsNothing);
    });

    testWidgets('an empty folder says how to fill it', (tester) async {
      await ChatFolders.instance.create('Empty', {});
      final id = ChatFolders.instance.folders.single.id;
      await showHome(tester, chats);
      await settle(tester);
      await pick(tester, id);
      expect(find.text('Nothing in Empty'), findsOneWidget);
    });

    testWidgets('a deleted folder falls back to All', (tester) async {
      await ChatFolders.instance.create('Work', {'b'});
      final id = ChatFolders.instance.folders.single.id;
      final inbox = await showHome(tester, chats);
      inbox.setArchived('h', true);
      await settle(tester);
      await pick(tester, id);
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Archived'), findsNothing);

      await ChatFolders.instance.delete(id);
      await settle(tester);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Work'), findsNothing);
      expect(find.text('Archived'), findsOneWidget, reason: 'back on All');
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('filter-all')))
            .selected,
        isTrue,
      );
    });

    testWidgets('searching looks through every chat, not just the filter', (
      tester,
    ) async {
      await showHome(tester, chats);
      await pick(tester, ChatFilter.groups);
      await tester.enterText(find.byType(TextField).first, 'alice');
      await settle(tester);
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Unread 2'), findsNothing, reason: 'filters hide');
    });

    testWidgets('the Archived row is only under All', (tester) async {
      final inbox = await showHome(tester, chats);
      inbox.setArchived('b', true);
      await settle(tester);
      expect(find.text('Archived'), findsOneWidget);
      await pick(tester, ChatFilter.groups);
      expect(find.text('Archived'), findsNothing);
      await pick(tester, ChatFilter.all);
      expect(find.text('Archived'), findsOneWidget);
    });

    testWidgets('pressing and holding a folder opens it', (tester) async {
      await ChatFolders.instance.create('Work', {'b'});
      final id = ChatFolders.instance.folders.single.id;
      await showHome(tester, chats);
      await settle(tester);
      await tester.longPress(find.byKey(ValueKey('filter-$id')));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
      expect(find.text('Edit folder'), findsOneWidget);
    });
  });

  group('in settings', () {
    Future<void> show(
      WidgetTester tester, {
      Widget page = const ChatFoldersPage(),
      List<InboxItem>? items,
    }) async {
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = items ?? chats;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider.value(value: inbox),
          ],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('explains folders when there are none', (tester) async {
      await show(tester);
      expect(find.textContaining('Folders sort your chats'), findsOneWidget);
      expect(find.text('New folder'), findsOneWidget);
    });

    testWidgets('lists the folders with how many chats are in them', (
      tester,
    ) async {
      await ChatFolders.instance.create('Work', {'a', 'b'});
      await ChatFolders.instance.create('Solo', {'a'});
      await ChatFolders.instance.create('Empty', {});
      await show(tester);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('2 chats'), findsOneWidget);
      expect(find.text('1 chat'), findsOneWidget);
      expect(find.text('No chats'), findsOneWidget);
    });

    testWidgets('makes a folder with the chats ticked', (tester) async {
      await show(tester);
      await tester.tap(find.text('New folder'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Friends');
      await tester.tap(find.byKey(const ValueKey('pick-a')));
      await tester.tap(find.byKey(const ValueKey('pick-g')));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final folder = ChatFolders.instance.folders.single;
      expect(folder.name, 'Friends');
      expect(folder.chatIds, {'a', 'g'});
      expect(find.text('Friends'), findsOneWidget);
      expect(find.text('2 chats'), findsOneWidget);
    });

    testWidgets('shows why a folder can not be saved, and stays', (
      tester,
    ) async {
      await ChatFolders.instance.create('Work', {});
      await show(tester, page: const ChatFolderEditorPage());
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Give the folder a name.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'work');
      await tester.pump();
      expect(find.text('Give the folder a name.'), findsNothing);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('already have a folder'), findsOneWidget);
      expect(ChatFolders.instance.folders, hasLength(1));
    });

    testWidgets('changes a folder: its name and its chats', (tester) async {
      await ChatFolders.instance.create('Work', {'a'});
      await show(tester);
      await tester.tap(find.text('Work'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<CheckboxListTile>(find.byKey(const ValueKey('pick-a')))
            .value,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), 'Office');
      await tester.tap(find.byKey(const ValueKey('pick-a')));
      await tester.tap(find.byKey(const ValueKey('pick-b')));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final folder = ChatFolders.instance.folders.single;
      expect(folder.name, 'Office');
      expect(folder.chatIds, {'b'});
    });

    testWidgets('deleting asks first, and keeps the chats', (tester) async {
      await ChatFolders.instance.create('Work', {'a'});
      final folder = ChatFolders.instance.folders.single;
      await show(tester, page: ChatFolderEditorPage(folder: folder));
      await tester.tap(find.byTooltip('Delete folder'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The chats stay'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(ChatFolders.instance.folders, hasLength(1));

      await tester.tap(find.byTooltip('Delete folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(ChatFolders.instance.folders, isEmpty);
    });

    testWidgets('New folder is off once there are ten', (tester) async {
      for (var i = 0; i < ChatFolders.maxFolders; i++) {
        await ChatFolders.instance.create('Folder $i', {});
      }
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 2400);
      addTearDown(tester.view.reset);
      await show(tester);
      expect(find.textContaining('up to 10 folders'), findsOneWidget);
      await tester.tap(find.text('New folder'));
      await tester.pumpAndSettle();
      expect(find.text('Folder name'), findsNothing);
    });
  });
}
