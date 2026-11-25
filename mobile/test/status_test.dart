import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/controllers/auth_state.dart';
import 'package:mobile/controllers/chat/active_chat_controller.dart';
import 'package:mobile/controllers/chat/inbox_controller.dart';
import 'package:mobile/core/status_content.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/models/status.dart';
import 'package:mobile/pages/status/status_composer_page.dart';
import 'package:mobile/pages/status/status_viewer_page.dart';
import 'package:mobile/services/nicknames.dart';
import 'package:mobile/services/statuses.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/status_strip.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_harness.dart';

final t0 = DateTime(2026, 11, 22, 12);

class MemoryStore implements StatusStore {
  final Map<String, StatusPost> rows = {};

  @override
  Future<List<StatusPost>> all() async => rows.values.toList();

  @override
  Future<void> save(StatusPost post) async => rows[post.id] = post;

  @override
  Future<void> markViewed(String id) async {
    final p = rows[id];
    if (p != null) rows[id] = p.copyWith(viewed: true);
  }

  @override
  Future<void> delete(String id) async => rows.remove(id);

  @override
  Future<void> deleteExpired(DateTime now) async =>
      rows.removeWhere((_, p) => p.isExpired(now));
}

class FakeRemote implements StatusRemote {
  List<RemoteStatus> inbox = [];
  List<RemoteOwnStatus> mine = [];
  final List<List<Map<String, String>>> posted = [];

  /// When a post is said to have been made. The service tests run on a fake
  /// clock, so a fixed time suits them; the widget tests run on the real one,
  /// and set this to now, or the status would run out as the calendar moves on.
  DateTime postedAt = t0;
  final List<String> deleted = [];
  final List<String> viewed = [];
  Object? failReceived;
  Object? failPost;
  Object? failDelete;
  int receivedCalls = 0;

  @override
  Future<List<RemoteStatus>> received() async {
    receivedCalls++;
    if (failReceived != null) throw failReceived!;
    return inbox;
  }

  @override
  Future<List<RemoteOwnStatus>> own() async => mine;

  @override
  Future<PostedStatus> post(List<Map<String, String>> copies) async {
    if (failPost != null) throw failPost!;
    posted.add(copies);
    return PostedStatus(
      id: 'posted-${posted.length}',
      createdAt: postedAt,
      expiresAt: postedAt.add(const Duration(hours: 24)),
      recipients: copies.length,
    );
  }

  @override
  Future<void> delete(String id) async {
    if (failDelete != null) throw failDelete!;
    deleted.add(id);
  }

  @override
  Future<void> view(String id) async => viewed.add(id);
}

/// Seals as "sealed:USER:TEXT"; anything else can't be read. Counts how
/// often it was asked to read, since Signal can only read a copy once.
class FakeCrypto implements StatusCrypto {
  final Set<String> noKeys = {};
  final List<String> decrypted = [];

  @override
  Future<String?> encrypt(String userId, String plaintext) async =>
      noKeys.contains(userId) ? null : 'sealed:$userId:$plaintext';

  @override
  Future<String?> decrypt(String senderId, String content) async {
    decrypted.add(content);
    final prefix = 'sealed:$senderId:';
    return content.startsWith(prefix) ? content.substring(prefix.length) : null;
  }
}

String body(String text, {int bg = 0, int font = 0}) =>
    StatusContent(text: text, background: bg, font: font).encode();

RemoteStatus remote(
  String id,
  String author,
  String text, {
  DateTime? at,
  Duration life = const Duration(hours: 20),
  bool viewed = false,
  String? content,
}) => RemoteStatus(
  id: id,
  authorId: author,
  content: content ?? 'sealed:$author:${body(text)}',
  createdAt: at ?? t0,
  expiresAt: (at ?? t0).add(life),
  viewed: viewed,
);

InboxItem chat(String id, {bool group = false, bool request = false}) =>
    InboxItem(
      id: id,
      title: 'Person $id',
      lastMessage: 'hi',
      timestamp: t0,
      isGroup: group,
      isRequest: request,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('a status\'s content', () {
    test('round-trips', () {
      final c = StatusContent.tryParse(body('Hello 👋', bg: 3, font: 2))!;
      expect(c.text, 'Hello 👋');
      expect(c.background, 3);
      expect(c.font, 2);
      expect(c.fontFamily, 'monospace');
      expect(c.backgroundColor, StatusStyle.backgrounds[3]);
    });

    test('is cut to 700 characters, counting an emoji as one', () {
      final long = '👋' * 800;
      expect(StatusContent.clean(long).runes.length, 700);
      expect(StatusContent.clean('  hi  '), 'hi');
      expect(
        StatusContent.tryParse(body(long))!.text.runes.length,
        StatusContent.maxLength,
      );
    });

    test('falls back to the first colour and font it does not know', () {
      final raw = jsonEncode({'v': 1, 'text': 'x', 'bg': 99, 'font': -1});
      final c = StatusContent.tryParse(raw)!;
      expect((c.background, c.font), (0, 0));
      final odd = jsonEncode({'v': 1, 'text': 'x', 'bg': 'red', 'font': null});
      expect(StatusContent.tryParse(odd)!.background, 0);
    });

    test('is not read if it is not one', () {
      for (final raw in [
        '',
        'plain text',
        '[]',
        jsonEncode({'v': 2, 'text': 'from a newer app'}),
        jsonEncode({'v': 1}),
        jsonEncode({'v': 1, 'text': 5}),
        jsonEncode({'v': 1, 'text': '   '}),
      ]) {
        expect(StatusContent.tryParse(raw), isNull, reason: raw);
      }
    });
  });

  group('words around a status', () {
    test('says how long ago', () {
      expect(statusAge(t0, t0.add(const Duration(seconds: 30))), 'Just now');
      expect(statusAge(t0, t0.add(const Duration(minutes: 5))), '5 min ago');
      expect(statusAge(t0, t0.add(const Duration(minutes: 59))), '59 min ago');
      expect(statusAge(t0, t0.add(const Duration(hours: 3))), '3 h ago');
    });

    test('quotes the status in a private reply', () {
      const status = StatusContent(text: 'Trip   to the\nlake');
      expect(
        statusReplyText(status, '  Sounds fun  '),
        '↩️ Status: “Trip to the lake”\n\nSounds fun',
      );
      final long = statusReplyText(StatusContent(text: 'a' * 100), 'x');
      expect(long, contains('${'a' * 60}…”'));
      expect(long.contains('a' * 61), isFalse);
    });
  });

  group('who a status goes to', () {
    test(
      'is the people chatted with, once, not groups, requests or blocked',
      () {
        final got = statusRecipients(
          [
            chat('A'),
            chat('b'),
            chat('a'),
            chat('crew', group: true),
            chat('c', request: true),
            chat('d'),
          ],
          blocked: {'d'},
        );
        expect(got, ['a', 'b']);
      },
    );
  });

  group('the service', () {
    late MemoryStore store;
    late FakeRemote server;
    late FakeCrypto crypto;
    late DateTime now;
    late Statuses statuses;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      store = MemoryStore();
      server = FakeRemote();
      crypto = FakeCrypto();
      now = t0.add(const Duration(minutes: 5));
      statuses = Statuses(
        store: store,
        remote: server,
        crypto: crypto,
        clock: () => now,
      );
    });

    test('reads what came, once, and keeps it', () async {
      server.inbox = [remote('s1', 'ava', 'Hello')];
      await statuses.refresh('me');
      expect(statuses.postsBy('ava').single.content!.text, 'Hello');
      expect(store.rows['s1']!.content!.text, 'Hello');

      await statuses.refresh('me');
      await statuses.refresh('me');
      expect(
        crypto.decrypted,
        hasLength(1),
        reason: 'Signal reads a copy once',
      );
    });

    test('remembers it after a restart, without reading it again', () async {
      server.inbox = [remote('s1', 'ava', 'Hello')];
      await statuses.refresh('me');
      final again = Statuses(
        store: store,
        remote: server,
        crypto: crypto,
        clock: () => now,
      );
      await again.load();
      expect(again.postsBy('ava').single.content!.text, 'Hello');
      await again.refresh('me');
      expect(crypto.decrypted, hasLength(1));
    });

    test(
      'hides one it can read but not understand, such as a newer one',
      () async {
        server.inbox = [
          remote(
            's1',
            'ava',
            '',
            content:
                'sealed:ava:${jsonEncode({'v': 2, 'text': 'from the future'})}',
          ),
        ];
        await statuses.refresh('me');
        expect(statuses.postsBy('ava'), isEmpty);
        expect(statuses.others('me'), isEmpty);
      },
    );

    test('keeps what it cannot read, hidden and not tried again', () async {
      server.inbox = [
        remote('s1', 'ava', '', content: 'sealed:someone-else:x'),
      ];
      await statuses.refresh('me');
      await statuses.refresh('me');
      expect(statuses.postsBy('ava'), isEmpty);
      expect(statuses.others('me'), isEmpty);
      expect(store.rows.containsKey('s1'), isTrue);
      expect(crypto.decrypted, hasLength(1));
    });

    test('one person\'s statuses come oldest first', () async {
      server.inbox = [
        remote('new', 'ava', 'second', at: t0.add(const Duration(minutes: 2))),
        remote('old', 'ava', 'first'),
      ];
      await statuses.refresh('me');
      expect(statuses.postsBy('ava').map((p) => p.id), ['old', 'new']);
    });

    test('lists people with something new first, then by recency', () async {
      server.inbox = [
        remote(
          '1',
          'seen-recent',
          'a',
          at: t0.add(const Duration(minutes: 4)),
          viewed: true,
        ),
        remote('2', 'new-old', 'b'),
        remote('3', 'new-recent', 'c', at: t0.add(const Duration(minutes: 3))),
        remote('4', 'me', 'my own'),
      ];
      await statuses.refresh('me');
      expect(statuses.others('me').map((o) => o.authorId), [
        'new-recent',
        'new-old',
        'seen-recent',
      ]);
      expect(statuses.others('me').first.unseen, isTrue);
      expect(statuses.others('me').last.unseen, isFalse);
    });

    test('leaves out muted people, and brings them back', () async {
      server.inbox = [remote('1', 'ava', 'a'), remote('2', 'ben', 'b')];
      await statuses.refresh('me');
      await statuses.mute('AVA');
      expect(statuses.isMuted('ava'), isTrue);
      expect(statuses.others('me').map((o) => o.authorId), ['ben']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('status_muted'), ['ava']);

      await statuses.unmute('ava');
      expect(statuses.others('me'), hasLength(2));
    });

    test('forgets muted people after sign-out', () async {
      await statuses.mute('ava');
      statuses.reset();
      expect(statuses.isMuted('ava'), isFalse);
    });

    test('drops statuses that have run out', () async {
      server.inbox = [
        remote('live', 'ava', 'a'),
        remote('gone', 'ben', 'b', life: const Duration(minutes: 1)),
      ];
      await statuses.refresh('me');
      expect(statuses.postsBy('ben'), isEmpty);
      expect(statuses.postsBy('ava'), hasLength(1));
      expect(store.rows.containsKey('gone'), isFalse);

      now = t0.add(const Duration(hours: 21));
      expect(statuses.postsBy('ava'), isEmpty, reason: 'it ran out meanwhile');
    });

    test('drops a status its author took down', () async {
      server.inbox = [remote('s1', 'ava', 'a'), remote('s2', 'ava', 'b')];
      await statuses.refresh('me');
      server.inbox = [remote('s2', 'ava', 'b')];
      await statuses.refresh('me');
      expect(statuses.postsBy('ava').map((p) => p.id), ['s2']);
      expect(store.rows.keys, ['s2']);
    });

    test('keeps what it has if the server cannot be reached', () async {
      server.inbox = [remote('s1', 'ava', 'a')];
      await statuses.refresh('me');
      server.failReceived = DioException(requestOptions: RequestOptions());
      await statuses.refresh('me');
      expect(statuses.postsBy('ava'), hasLength(1));
    });

    test('shares one fetch between calls that overlap', () async {
      await Future.wait([statuses.refresh('me'), statuses.refresh('me')]);
      expect(server.receivedCalls, 1);
    });

    test('learns who saw the person\'s own status', () async {
      server.mine = [
        RemoteOwnStatus(
          id: 'mine-1',
          createdAt: t0,
          expiresAt: t0.add(const Duration(hours: 24)),
          viewers: [StatusViewer(userId: 'ava', viewedAt: t0)],
        ),
      ];
      await statuses.refresh('me');
      expect(statuses.viewersOf('MINE-1').single.userId, 'ava');
      expect(statuses.viewersOf('other'), isEmpty);
    });

    test('drops an own status that is gone from the server', () async {
      server.mine = [
        RemoteOwnStatus(
          id: 'mine-1',
          createdAt: t0,
          expiresAt: t0.add(const Duration(hours: 24)),
          viewers: const [],
        ),
      ];
      await statuses.post(
        myId: 'me',
        text: 'hi',
        background: 0,
        font: 0,
        recipients: ['ava'],
      );
      expect(statuses.postsBy('me'), hasLength(1));
      await statuses.refresh('me'); // the server only knows "mine-1"
      expect(statuses.postsBy('me'), isEmpty);
    });

    group('posting', () {
      test('encrypts a copy for each person and keeps its own', () async {
        final result = await statuses.post(
          myId: 'ME',
          text: '  Hello  ',
          background: 2,
          font: 1,
          recipients: ['ava', 'ben'],
        );
        expect(result.error, isNull);
        expect(result.sent, 2);
        expect(result.skipped, 0);

        final copies = server.posted.single;
        expect(copies.map((c) => c['recipient_id']), ['ava', 'ben']);
        final plain = copies.first['content']!.replaceFirst('sealed:ava:', '');
        final sent = StatusContent.tryParse(plain)!;
        expect((sent.text, sent.background, sent.font), ('Hello', 2, 1));

        final mine = statuses.postsBy('me').single;
        expect(mine.id, 'posted-1');
        expect(mine.content!.text, 'Hello');
        expect(mine.viewed, isTrue);
        expect(store.rows.containsKey('posted-1'), isTrue);
      });

      test('says who it could not be encrypted for', () async {
        crypto.noKeys.add('ben');
        final result = await statuses.post(
          myId: 'me',
          text: 'hi',
          background: 0,
          font: 0,
          recipients: ['ava', 'ben', 'cy'],
        );
        expect(result.sent, 2);
        expect(result.skipped, 1);
        expect(server.posted.single.map((c) => c['recipient_id']), [
          'ava',
          'cy',
        ]);
      });

      test('says so if nobody could get it', () async {
        crypto.noKeys.addAll(['ava', 'ben']);
        final result = await statuses.post(
          myId: 'me',
          text: 'hi',
          background: 0,
          font: 0,
          recipients: ['ava', 'ben'],
        );
        expect(result.error, contains('encryption'));
        expect(server.posted, isEmpty);
        expect(statuses.postsBy('me'), isEmpty);
      });

      test('needs words and people', () async {
        final blank = await statuses.post(
          myId: 'me',
          text: '   ',
          background: 0,
          font: 0,
          recipients: ['ava'],
        );
        expect(blank.error, contains('Write something'));
        final lonely = await statuses.post(
          myId: 'me',
          text: 'hi',
          background: 0,
          font: 0,
          recipients: [],
        );
        expect(lonely.error, contains('Chat with someone'));
        expect(server.posted, isEmpty);
      });

      test('goes to at most 200 people', () async {
        final many = [for (var i = 0; i < 250; i++) 'u$i'];
        final result = await statuses.post(
          myId: 'me',
          text: 'hi',
          background: 0,
          font: 0,
          recipients: many,
        );
        expect(server.posted.single, hasLength(200));
        expect(result.sent, 200);
      });

      test('keeps nothing if the server refuses', () async {
        server.failPost = DioException(
          requestOptions: RequestOptions(),
          response: Response(
            requestOptions: RequestOptions(),
            statusCode: 429,
            data: {'error': 'You can post 20 statuses a day'},
          ),
        );
        final result = await statuses.post(
          myId: 'me',
          text: 'hi',
          background: 0,
          font: 0,
          recipients: ['ava'],
        );
        expect(result.error, isNotNull);
        expect(statuses.postsBy('me'), isEmpty);
        expect(store.rows, isEmpty);
      });

      test('cuts words to 700 characters', () async {
        await statuses.post(
          myId: 'me',
          text: 'x' * 900,
          background: 0,
          font: 0,
          recipients: ['ava'],
        );
        expect(statuses.postsBy('me').single.content!.text.length, 700);
      });
    });

    group('viewing', () {
      test('marks it seen here and tells the server, once', () async {
        server.inbox = [remote('s1', 'ava', 'a')];
        await statuses.refresh('me');
        final post = statuses.postsBy('ava').single;
        await statuses.markViewed(post);
        expect(statuses.postsBy('ava').single.viewed, isTrue);
        expect(store.rows['s1']!.viewed, isTrue);
        expect(server.viewed, ['s1']);

        await statuses.markViewed(statuses.postsBy('ava').single);
        expect(server.viewed, ['s1'], reason: 'already seen');
        expect(statuses.others('me').single.unseen, isFalse);
      });

      test('never counts the person\'s own status as seen by them', () async {
        await statuses.post(
          myId: 'me',
          text: 'hi',
          background: 0,
          font: 0,
          recipients: ['ava'],
        );
        await statuses.markViewed(statuses.postsBy('me').single);
        expect(server.viewed, isEmpty);
      });

      test('tells the server about one seen while offline', () async {
        server.inbox = [remote('s1', 'ava', 'a')];
        await statuses.refresh('me');
        server.failReceived = Exception('offline');
        await statuses.markViewed(statuses.postsBy('ava').single);
        server.viewed.clear();
        server.failReceived = null;
        await statuses.refresh('me');
        await Future<void>.delayed(Duration.zero);
        expect(server.viewed, ['s1']);
      });

      test('takes on what another phone saw', () async {
        server.inbox = [remote('s1', 'ava', 'a')];
        await statuses.refresh('me');
        server.inbox = [remote('s1', 'ava', 'a', viewed: true)];
        await statuses.refresh('me');
        expect(statuses.postsBy('ava').single.viewed, isTrue);
        expect(store.rows['s1']!.viewed, isTrue);
      });
    });

    group('deleting', () {
      Future<StatusPost> own() async {
        await statuses.post(
          myId: 'me',
          text: 'hi',
          background: 0,
          font: 0,
          recipients: ['ava'],
        );
        return statuses.postsBy('me').single;
      }

      test('takes it down for everyone', () async {
        final post = await own();
        expect(await statuses.delete(post), isNull);
        expect(server.deleted, ['posted-1']);
        expect(statuses.postsBy('me'), isEmpty);
        expect(store.rows, isEmpty);
      });

      test('counts one the server no longer has as done', () async {
        final post = await own();
        server.failDelete = DioException(
          requestOptions: RequestOptions(),
          response: Response(requestOptions: RequestOptions(), statusCode: 404),
        );
        expect(await statuses.delete(post), isNull);
        expect(statuses.postsBy('me'), isEmpty);
      });

      test('keeps it, and says why, if the server cannot be reached', () async {
        final post = await own();
        server.failDelete = DioException(requestOptions: RequestOptions());
        expect(await statuses.delete(post), isNotNull);
        expect(statuses.postsBy('me'), hasLength(1));
      });
    });
  });

  group('in the app', () {
    late MemoryStore store;
    late FakeRemote server;
    late FakeCrypto crypto;
    late Statuses statuses;
    late InboxController inbox;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      Nicknames.instance = Nicknames(store: _NoNicknames());
      store = MemoryStore();
      server = FakeRemote()..postedAt = DateTime.now();
      crypto = FakeCrypto();
      statuses = Statuses(
        store: store,
        remote: server,
        crypto: crypto,
        clock: DateTime.now,
      );
      inbox = InboxController()
        ..hasLoadedOnce = true
        ..inbox = [chat('ava'), chat('ben')];
    });

    Future<TestChat> pump(WidgetTester tester, Widget home) async {
      final chatController = TestChat()..currentUserIdProvider = () => 'me';
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthState>(create: (_) => TestAuth('me')),
            ChangeNotifierProvider.value(value: inbox),
            ChangeNotifierProvider<ActiveChatController>.value(
              value: chatController,
            ),
          ],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: Scaffold(body: home),
          ),
        ),
      );
      return chatController;
    }

    Future<void> seed(List<RemoteStatus> remotes) async {
      server.inbox = remotes;
      await statuses.refresh('me');
    }

    RemoteStatus fresh(String id, String author, String text) => remote(
      id,
      author,
      text,
      at: DateTime.now(),
      life: const Duration(hours: 23),
    );

    testWidgets('the strip shows your status and the people with one', (
      tester,
    ) async {
      await seed([fresh('1', 'ava', 'a'), fresh('2', 'ben', 'b')]);
      await tester.runAsync(() async {});
      await pump(tester, StatusStrip(statuses: statuses));
      expect(find.text('Your status'), findsOne);
      expect(find.text('Person'), findsNWidgets(2));
      expect(find.text('Your'), findsNothing);
      expect(find.bySemanticsLabel('Person ava, new status'), findsOne);
      expect(find.bySemanticsLabel(RegExp('new status')), findsWidgets);
    });

    testWidgets(
      'the strip opens the composer when there is no status of yours',
      (tester) async {
        await pump(tester, StatusStrip(statuses: statuses));
        await tester.tap(find.text('Your status'));
        await tester.pumpAndSettle();
        expect(find.byType(StatusComposerPage), findsOne);
      },
    );

    testWidgets('the strip opens a viewer for someone else\'s', (tester) async {
      await seed([fresh('1', 'ava', 'Hello there')]);
      await pump(tester, StatusStrip(statuses: statuses));
      await tester.tap(find.byKey(const ValueKey('status-ava')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(StatusViewerPage), findsOne);
      expect(find.text('Hello there'), findsOne);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the composer will not post nothing, and limits length', (
      tester,
    ) async {
      await pump(tester, StatusComposerPage(statuses: statuses));
      FilledButton post() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Post'),
      );
      expect(post().onPressed, isNull);
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(post().onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'x' * 800);
      await tester.pump();
      expect(find.text('700/700'), findsOne);
      expect(
        tester
            .widget<TextField>(find.byType(TextField))
            .controller!
            .text
            .length,
        700,
        reason: 'a long paste keeps what fits',
      );
      expect(post().onPressed, isNotNull);
    });

    testWidgets('the composer posts to the people you chat with', (
      tester,
    ) async {
      await pump(tester, StatusComposerPage(statuses: statuses));
      expect(find.textContaining('Goes to 2 people'), findsOne);
      await tester.enterText(find.byType(TextField), 'Gone fishing');
      await tester.pump();
      // Pick the third colour and the Serif font first.
      await tester.tap(find.bySemanticsLabel('Background 3'));
      await tester.tap(find.text('Serif'));
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Post'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      final copies = server.posted.single;
      expect(copies.map((c) => c['recipient_id']), ['ava', 'ben']);
      final sent = StatusContent.tryParse(
        copies.first['content']!.replaceFirst('sealed:ava:', ''),
      )!;
      expect((sent.text, sent.background, sent.font), ('Gone fishing', 2, 1));
    });

    testWidgets('the composer says when there is nobody yet', (tester) async {
      inbox.inbox = [chat('crew', group: true), chat('req', request: true)];
      await pump(tester, StatusComposerPage(statuses: statuses));
      expect(find.text('Nobody to send it to yet'), findsOne);
    });

    Future<TestChat> viewer(WidgetTester tester, List<String> authors) async {
      final c = await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    StatusViewerPage(authors: authors, statuses: statuses),
              ),
            ),
            child: const Text('open viewer'),
          ),
        ),
      );
      await tester.tap(find.text('open viewer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      return c;
    }

    testWidgets('the viewer plays one status, then the next, then closes', (
      tester,
    ) async {
      await seed([
        remote(
          '1',
          'ava',
          'first',
          at: DateTime.now().subtract(const Duration(minutes: 2)),
          life: const Duration(hours: 23),
        ),
        remote(
          '2',
          'ava',
          'second',
          at: DateTime.now().subtract(const Duration(minutes: 1)),
          life: const Duration(hours: 23),
        ),
      ]);
      await viewer(tester, ['ava']);
      expect(find.text('first'), findsOne);

      await tester.pump(const Duration(seconds: 6));
      expect(find.text('second'), findsOne, reason: 'moved on by itself');
      expect(statuses.postsBy('ava').every((p) => p.viewed), isTrue);
      expect(server.viewed.toSet(), {'1', '2'});
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byType(StatusViewerPage), findsNothing);
    });

    testWidgets('tapping the right skips ahead and the left goes back', (
      tester,
    ) async {
      await seed([
        remote(
          '1',
          'ava',
          'first',
          at: DateTime.now().subtract(const Duration(minutes: 2)),
          life: const Duration(hours: 23),
        ),
        remote(
          '2',
          'ava',
          'second',
          at: DateTime.now().subtract(const Duration(minutes: 1)),
          life: const Duration(hours: 23),
        ),
      ]);
      await viewer(tester, ['ava']);
      final size = tester.getSize(find.byType(Scaffold).last);
      await tester.tapAt(Offset(size.width * 0.8, 300));
      await tester.pump();
      expect(find.text('second'), findsOne);
      await tester.tapAt(Offset(size.width * 0.1, 300));
      await tester.pump();
      expect(find.text('first'), findsOne);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('holding pauses it', (tester) async {
      await seed([
        remote(
          '1',
          'ava',
          'first',
          at: DateTime.now().subtract(const Duration(minutes: 2)),
          life: const Duration(hours: 23),
        ),
        remote(
          '2',
          'ava',
          'second',
          at: DateTime.now().subtract(const Duration(minutes: 1)),
          life: const Duration(hours: 23),
        ),
      ]);
      await viewer(tester, ['ava']);
      final gesture = await tester.startGesture(const Offset(200, 400));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 8));
      expect(find.text('first'), findsOne, reason: 'held, so it stays');
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('second'), findsOne);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('goes on to the next person', (tester) async {
      await seed([
        fresh('1', 'ava', 'from ava'),
        fresh('2', 'ben', 'from ben'),
      ]);
      await viewer(tester, ['ava', 'ben']);
      expect(find.text('from ava'), findsOne);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('from ben'), findsOne);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('starts at the first one not seen', (tester) async {
      await seed([
        remote(
          '1',
          'ava',
          'old news',
          at: DateTime.now().subtract(const Duration(minutes: 2)),
          life: const Duration(hours: 23),
          viewed: true,
        ),
        remote(
          '2',
          'ava',
          'new news',
          at: DateTime.now().subtract(const Duration(minutes: 1)),
          life: const Duration(hours: 23),
        ),
      ]);
      await viewer(tester, ['ava']);
      expect(find.text('new news'), findsOne);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a private reply is a normal message quoting the status', (
      tester,
    ) async {
      await seed([fresh('1', 'ava', 'Gone fishing')]);
      final chatController = await viewer(tester, ['ava']);
      await tester.enterText(find.byType(TextField), 'Catch anything?');
      await tester.tap(find.byTooltip('Send reply'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final sent = chatController.sent.single;
      expect(sent.targetId, 'ava');
      expect(sent.isGroup, isFalse);
      expect(sent.text, '↩️ Status: “Gone fishing”\n\nCatch anything?');
      expect(find.text('Reply sent'), findsOne);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('muting someone ends their statuses', (tester) async {
      await seed([
        fresh('1', 'ava', 'from ava'),
        fresh('2', 'ben', 'from ben'),
      ]);
      await viewer(tester, ['ava', 'ben']);
      // The preferences load on a real clock, not the test's.
      await tester.runAsync(SharedPreferences.getInstance);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mute status'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(statuses.isMuted('ava'), isTrue);
      expect(find.text('from ben'), findsOne, reason: 'on to the next person');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    Future<void> postOwn(WidgetTester tester) async {
      await tester.runAsync(
        () => statuses.post(
          myId: 'me',
          text: 'My own words',
          background: 1,
          font: 0,
          recipients: ['ava', 'ben'],
        ),
      );
    }

    testWidgets('your own status shows who has seen it, not a reply box', (
      tester,
    ) async {
      await postOwn(tester);
      server.mine = [
        RemoteOwnStatus(
          id: 'posted-1',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(hours: 23)),
          viewers: [StatusViewer(userId: 'ava', viewedAt: DateTime.now())],
        ),
      ];
      await tester.runAsync(() => statuses.refresh('me'));
      await viewer(tester, ['me']);
      expect(find.text('My own words'), findsOne);
      expect(find.text('Your status'), findsOne);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Seen by 1'), findsOne);
      expect(server.viewed, isEmpty, reason: 'your own isn\'t "seen"');

      await tester.tap(find.text('Seen by 1'));
      await tester.pumpAndSettle();
      expect(find.text('Person'), findsNothing);
      expect(find.text('Person ava'), findsOne);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('your own status can be deleted, after asking', (tester) async {
      await postOwn(tester);
      server.mine = [
        RemoteOwnStatus(
          id: 'posted-1',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(hours: 23)),
          viewers: const [],
        ),
      ];
      await viewer(tester, ['me']);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete this status?'), findsOne);
      await tester.runAsync(() async {
        await tester.tap(find.text('Delete').last);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(server.deleted, ['posted-1']);
      expect(statuses.postsBy('me'), isEmpty);
      expect(find.byType(StatusViewerPage), findsNothing);
    });

    test('a status is shown for longer when it is longer', () {
      expect(
        statusDuration(const StatusContent(text: 'hi')),
        const Duration(milliseconds: 5080),
      );
      expect(
        statusDuration(StatusContent(text: 'x' * 400)),
        const Duration(milliseconds: 15000),
      );
      expect(
        statusDuration(StatusContent(text: 'x' * 100)),
        const Duration(milliseconds: 9000),
      );
    });
  });
}

class _NoNicknames implements NicknameStore {
  @override
  Future<Map<String, String>> all() async => {};
  @override
  Future<void> save(String userId, String nickname) async {}
  @override
  Future<void> delete(String userId) async {}
}
