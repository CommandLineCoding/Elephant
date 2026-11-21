import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/group_details_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/services/nicknames.dart';
import 'package:mobile/services/push/push_notifier.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:mobile/widgets/home_page_widgets.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

class MemoryStore implements NicknameStore {
  final Map<String, String> saved;
  int writes = 0;
  bool failReads = false;
  bool failWrites = false;

  MemoryStore([Map<String, String>? saved]) : saved = {...?saved};

  @override
  Future<Map<String, String>> all() async {
    if (failReads) throw Exception('disk');
    return {...saved};
  }

  @override
  Future<void> save(String userId, String nickname) async {
    if (failWrites) throw Exception('disk');
    writes++;
    saved[userId] = nickname;
  }

  @override
  Future<void> delete(String userId) async {
    if (failWrites) throw Exception('disk');
    writes++;
    saved.remove(userId);
  }
}

InboxItem chat(String id, String title, {bool group = false}) => InboxItem(
  id: id,
  title: title,
  username: 'alex.1234',
  lastMessage: 'hi',
  timestamp: DateTime(2026, 11, 21),
  isGroup: group,
  unreadCount: 2,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the nicknames', () {
    test(
      'are used in place of the contact\'s name, and nothing else changes',
      () async {
        final n = Nicknames(store: MemoryStore());
        await n.set('U-ALEX', '  Alex   from   work ');
        expect(
          n.of('u-alex'),
          'Alex from work',
          reason: 'ids are not case sensitive',
        );
        expect(n.nameFor('u-alex', 'Alex'), 'Alex from work');
        expect(n.nameFor('u-other', 'Alex'), 'Alex');
        expect(n.of('u-other'), isNull);
      },
    );

    test('clearing one goes back to the contact\'s own name', () async {
      final store = MemoryStore();
      final n = Nicknames(store: store);
      await n.set('u1', 'Boss');
      await n.set('u1', '   ');
      expect(n.of('u1'), isNull);
      expect(n.nameFor('u1', 'Alex Smith'), 'Alex Smith');
      expect(store.saved, isEmpty);
    });

    test('are cut to thirty characters', () async {
      final n = Nicknames(store: MemoryStore());
      await n.set('u1', 'x' * 50);
      expect(n.of('u1')!.length, Nicknames.maxLength);
      await n.set('u2', '🐘' * 40);
      expect(n.of('u2')!.runes.length, Nicknames.maxLength);
    });

    test('are saved and read back after a restart', () async {
      final store = MemoryStore();
      final first = Nicknames(store: store);
      await first.set('u1', 'Boss');
      await first.set('u2', 'Mum');

      final later = Nicknames(store: store);
      expect(later.of('u1'), isNull, reason: 'not read yet');
      await later.load();
      expect(later.of('u1'), 'Boss');
      expect(later.of('u2'), 'Mum');
    });

    test('one set while loading wins over the saved one', () async {
      final store = MemoryStore({'u1': 'Old'});
      final n = Nicknames(store: store);
      final loading = n.load();
      await n.set('u1', 'New');
      await loading;
      expect(n.of('u1'), 'New');
    });

    test('are forgotten on sign-out', () async {
      final n = Nicknames(store: MemoryStore());
      await n.set('u1', 'Boss');
      n.reset();
      expect(n.of('u1'), isNull);
    });

    test('keep working if the disk fails', () async {
      final store = MemoryStore({'u1': 'Boss'})
        ..failReads = true
        ..failWrites = true;
      final n = Nicknames(store: store);
      await n.load();
      await n.set('u2', 'Mum');
      expect(n.of('u2'), 'Mum');
      store.failReads = false;
      await n.load();
      expect(n.of('u1'), 'Boss', reason: 'a failed read can be tried again');
    });

    test('tell listeners, and not when nothing changed', () async {
      final n = Nicknames(store: MemoryStore());
      var calls = 0;
      n.addListener(() => calls++);
      await n.set('u1', 'Boss');
      expect(calls, 1);
      await n.set('u1', 'Boss');
      await n.set('u9', '');
      expect(calls, 1);
    });
  });

  group('where a name is shown', () {
    setUp(() => Nicknames.instance = Nicknames(store: MemoryStore()));
    tearDown(() => Nicknames.instance = Nicknames());

    test('a direct chat uses the nickname, a group keeps its name', () async {
      await Nicknames.instance.set('u1', 'Boss');
      await Nicknames.instance.set('g1', 'Never');
      expect(chat('u1', 'Alex Smith').shownTitle, 'Boss');
      expect(
        chat('g1', 'Weekend Trek', group: true).shownTitle,
        'Weekend Trek',
      );
      expect(chat('u2', 'Bob').shownTitle, 'Bob');
    });

    test('a notification says the nickname, not the display name', () async {
      await Nicknames.instance.set('u1', 'Boss');
      expect(
        notificationText(chat('u1', 'Alex Smith'), showName: true).title,
        'Boss',
      );
      expect(
        notificationText(chat('u1', 'Alex Smith'), showName: false).title,
        'Elephant',
      );
    });

    testWidgets('the chat list shows it and follows changes', (tester) async {
      final item = chat('u1', 'Alex Smith');
      final inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [item];
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
              body: ConversationTile(conversation: item, onTap: () {}),
            ),
          ),
        ),
      );
      expect(find.text('Alex Smith'), findsOneWidget);

      await Nicknames.instance.set('u1', 'Boss');
      await tester.pump();
      expect(find.text('Boss'), findsOneWidget);
      expect(find.text('Alex Smith'), findsNothing);

      await Nicknames.instance.set('u1', '');
      await tester.pump();
      expect(find.text('Alex Smith'), findsOneWidget);
    });
  });
}
