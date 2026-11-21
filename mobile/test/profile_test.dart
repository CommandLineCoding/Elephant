import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/core/profile_limits.dart';
import 'package:mobile/models/user.dart';
import 'package:mobile/pages/settings/accounts.dart';
import 'package:mobile/services/peer_profiles.dart';
import 'package:mobile/themes/app_themes.dart';

import 'chat_harness.dart';

UserModel user({
  String bio = '',
  Map<String, dynamic>? status,
  String id = 'u2',
}) => UserModel.fromJson({
  'id': id,
  'username': 'bob.1234',
  'display_name': 'Bob',
  'bio': bio,
  'status': ?status,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);
  tearDown(() => PeerProfiles.instance = PeerProfiles());

  group('reading a profile', () {
    test('has an about text and a status', () {
      final u = user(
        bio: '  Cyclist.  ',
        status: {
          'emoji': '🚴',
          'text': 'On a ride',
          'expires_at': '2999-01-01T00:00:00Z',
        },
      );
      expect(u.bio, 'Cyclist.');
      expect(u.hasStatus(), isTrue);
      expect(u.statusLine(), '🚴 On a ride');
      expect(u.statusExpiresAt, isNotNull);
    });

    test('from an older server has neither', () {
      final u = UserModel.fromJson({'id': 'u', 'username': 'a.1234'});
      expect(u.bio, '');
      expect(u.hasStatus(), isFalse);
      expect(u.statusLine(), isNull);
    });

    test('a status with no end lasts, and an ended one does not show', () {
      expect(user(status: {'emoji': '🌴', 'text': 'Away'}).hasStatus(), isTrue);
      final ended = user(
        status: {
          'emoji': '🚴',
          'text': 'On a ride',
          'expires_at': '2020-01-01T00:00:00Z',
        },
      );
      expect(ended.hasStatus(), isFalse);
      expect(ended.statusLine(), isNull);
    });

    test('an emoji alone, or words alone, is a status', () {
      expect(user(status: {'emoji': '🎧'}).statusLine(), '🎧');
      expect(user(status: {'text': 'Busy'}).statusLine(), 'Busy');
      expect(user(status: {'emoji': '', 'text': ''}).hasStatus(), isFalse);
    });
  });

  group('how long a status lasts', () {
    final now = DateTime(2026, 11, 21, 15, 30);

    test('by choice', () {
      expect(StatusDuration.never.from(now), isNull);
      expect(StatusDuration.hour.from(now), const Duration(hours: 1));
      expect(StatusDuration.fourHours.from(now), const Duration(hours: 4));
      expect(StatusDuration.week.from(now), const Duration(days: 7));
    });

    test('today ends at midnight, and is never under a minute', () {
      expect(
        StatusDuration.today.from(now),
        const Duration(hours: 8, minutes: 30),
      );
      expect(
        StatusDuration.today.from(DateTime(2026, 11, 21, 23, 59, 30)),
        const Duration(minutes: 1),
      );
    });
  });

  group('other people\'s profiles', () {
    test('are loaded once and kept for five minutes', () async {
      var asked = 0;
      var now = DateTime(2026, 11, 21, 12);
      final profiles = PeerProfiles(
        fetch: (id) async {
          asked++;
          return user(bio: 'asked $asked', id: id);
        },
        clock: () => now,
      );
      expect(profiles.of('U2'), isNull);
      await profiles.load('u2');
      expect(
        profiles.of('U2')!.bio,
        'asked 1',
        reason: 'ids are not case sensitive',
      );

      await profiles.load('U2');
      expect(asked, 1);
      now = now.add(const Duration(minutes: 4));
      await profiles.load('u2');
      expect(asked, 1);
      now = now.add(const Duration(minutes: 2));
      await profiles.load('u2');
      expect(asked, 2);
      expect(profiles.of('u2')!.bio, 'asked 2');
    });

    test('are not asked for twice at once', () async {
      var asked = 0;
      final profiles = PeerProfiles(
        fetch: (id) async {
          asked++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return user(id: id);
        },
      );
      await Future.wait([profiles.load('u2'), profiles.load('u2')]);
      expect(asked, 1);
    });

    test('stay as they were if loading fails', () async {
      var fail = false;
      var now = DateTime(2026, 11, 21, 12);
      final profiles = PeerProfiles(
        fetch: (id) async {
          if (fail) throw Exception('offline');
          return user(bio: 'before', id: id);
        },
        clock: () => now,
      );
      await profiles.load('u2');
      fail = true;
      now = now.add(const Duration(minutes: 10));
      await profiles.load('u2');
      expect(profiles.of('u2')!.bio, 'before');
    });

    test('tell listeners, and are forgotten on sign-out', () async {
      final profiles = PeerProfiles(fetch: (id) async => user(id: id));
      var calls = 0;
      profiles.addListener(() => calls++);
      await profiles.load('u2');
      expect(calls, 1);
      profiles.reset();
      expect(profiles.of('u2'), isNull);
      expect(calls, 2);
    });
  });

  group('the status dialog', () {
    Future<StatusChoice?> open(
      WidgetTester tester, {
      String emoji = '',
      String text = '',
    }) async {
      StatusChoice? result;
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result = await showDialog<StatusChoice>(
                    context: context,
                    builder: (_) => StatusDialog(emoji: emoji, text: text),
                  );
                  closed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      addTearDown(() => closed);
      return result;
    }

    FilledButton save(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));

    testWidgets('says who can see it', (tester) async {
      await open(tester);
      expect(find.textContaining('Anyone who can look you up'), findsOneWidget);
    });

    testWidgets(
      'can not be saved empty, and has no Clear when there is nothing to clear',
      (tester) async {
        await open(tester);
        expect(save(tester).onPressed, isNull);
        expect(find.text('Clear'), findsNothing);

        await tester.enterText(find.byType(TextField).last, 'Busy');
        await tester.pump();
        expect(save(tester).onPressed, isNotNull);
      },
    );

    testWidgets('a suggested emoji fills the emoji box', (tester) async {
      await open(tester);
      await tester.tap(find.widgetWithText(ActionChip, '🚴'));
      await tester.pump();
      expect(
        save(tester).onPressed,
        isNotNull,
        reason: 'an emoji alone is a status',
      );
    });

    testWidgets('returns what was chosen', (tester) async {
      StatusChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showDialog<StatusChoice>(
                  context: context,
                  builder: (_) => const StatusDialog(),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ActionChip, '🎧'));
      await tester.enterText(find.byType(TextField).last, '  Focus time ');
      await tester.tap(find.text('1 hour'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(result!.emoji, '🎧');
      expect(result!.text, 'Focus time');
      expect(result!.duration, StatusDuration.hour);
      expect(result!.isClear, isFalse);
    });

    testWidgets('Clear returns an empty choice', (tester) async {
      StatusChoice? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppThemes.getTheme(ThemeType.frost),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => result = await showDialog<StatusChoice>(
                  context: context,
                  builder: (_) =>
                      const StatusDialog(emoji: '🚴', text: 'On a ride'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('On a ride'), findsOneWidget);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(result!.isClear, isTrue);
    });
  });

  group('the chat header', () {
    testWidgets('shows their status under the name, else their username', (
      tester,
    ) async {
      PeerProfiles.instance = PeerProfiles(
        fetch: (id) async =>
            user(id: id, status: {'emoji': '🚴', 'text': 'On a ride'}),
      );
      await showTestChat(tester, messages: [testMessage('m1', 'hi')]);
      await tester.pumpAndSettle();
      expect(find.textContaining('On a ride'), findsOneWidget);
      expect(find.text('@bob.1234'), findsNothing);
    });

    testWidgets('keeps the username when they have no status', (tester) async {
      PeerProfiles.instance = PeerProfiles(fetch: (id) async => user(id: id));
      await showTestChat(tester, messages: [testMessage('m1', 'hi')]);
      expect(find.text('@bob.1234'), findsOneWidget);
    });
  });
}
