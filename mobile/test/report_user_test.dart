import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/pages/chat/report_user.dart';
import 'package:mobile/services/blocked_users.dart';
import 'package:mobile/services/reports.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/themes/theme_provider.dart';
import 'package:provider/provider.dart';

import 'chat_harness.dart';

class FakeReports implements ReportsApi {
  final List<
    ({
      String userId,
      ReportReason reason,
      String note,
      List<AttachedMessage> messages,
    })
  >
  sent = [];
  Object? fail;

  @override
  Future<void> send({
    required String userId,
    required ReportReason reason,
    required String note,
    required List<AttachedMessage> messages,
  }) async {
    if (fail != null) throw fail!;
    sent.add((userId: userId, reason: reason, note: note, messages: messages));
  }
}

const bob = BlockedUser(id: 'u-bob', username: 'bob.1234', displayName: 'Bob');
final noon = DateTime.utc(2026, 11, 21, 12);

({bool fromReported, String? text, DateTime at}) msg(
  String? text, {
  bool fromReported = true,
  int minute = 0,
}) => (
  fromReported: fromReported,
  text: text,
  at: noon.add(Duration(minutes: minute)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  group('the messages that go with a report', () {
    test('are the last five, oldest first', () {
      final out = messagesForReport([
        for (var i = 0; i < 8; i++) msg('m$i', minute: i),
      ]);
      expect(out.map((m) => m.text), ['m3', 'm4', 'm5', 'm6', 'm7']);
    });

    test('say who sent each one', () {
      final out = messagesForReport([
        msg('hello', fromReported: true),
        msg('stop it', fromReported: false, minute: 1),
      ]);
      expect(out.map((m) => m.fromReported), [true, false]);
    });

    test('leave out what can not be read', () {
      final out = messagesForReport([
        msg(null),
        msg('   '),
        msg('real', minute: 1),
      ]);
      expect(out.map((m) => m.text), ['real']);
    });

    test('are cut to the length the server takes', () {
      final out = messagesForReport([msg('${'a' * 1500}  ')]);
      expect(out.single.text.length, ReportLimits.messageText);
    });

    test('go as the server expects them', () {
      final json = messagesForReport([msg('hi')]).single.toJson();
      expect(json, {
        'from_reported': true,
        'text': 'hi',
        'at': '2026-11-21T12:00:00.000Z',
      });
    });

    test('can be none', () => expect(messagesForReport(const []), isEmpty));
  });

  group('reporting from a chat', () {
    late FakeReports api;
    late List<String> blocked;
    late bool? result;

    setUp(() {
      api = FakeReports();
      blocked = [];
      result = null;
    });

    Future<void> open(
      WidgetTester tester, {
      bool alreadyBlocked = false,
      List<AttachedMessage> messages = const [],
      Future<String?> Function(BlockedUser)? block,
    }) async {
      await tester.pumpWidget(
        MultiProvider(
          providers: [ChangeNotifierProvider(create: (_) => ThemeProvider())],
          child: MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () async {
                      result = await reportUser(
                        context,
                        user: bob,
                        api: api,
                        alreadyBlocked: alreadyBlocked,
                        recentMessages: () => messages,
                        block:
                            block ??
                            (u) async {
                              blocked.add(u.id);
                              return null;
                            },
                      );
                    },
                    child: const Text('Report'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
    }

    final attached = [
      AttachedMessage(fromReported: true, text: 'buy coins', at: noon),
    ];

    testWidgets('needs a reason before it can be sent', (tester) async {
      await open(tester);
      expect(find.text('Report Bob'), findsOneWidget);
      final send = find.widgetWithText(FilledButton, 'Send report');
      expect(tester.widget<FilledButton>(send).onPressed, isNull);

      await tester.tap(find.text('Spam'));
      await tester.pump();
      expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    });

    testWidgets('sends the reason and the note, and nothing else by default', (
      tester,
    ) async {
      await open(tester, messages: attached);
      await tester.tap(find.text('Harassment or abuse'));
      await tester.enterText(find.byType(TextField), '  keeps messaging me ');
      await tester.tap(find.widgetWithText(FilledButton, 'Send report'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      final sent = api.sent.single;
      expect(sent.userId, 'u-bob');
      expect(sent.reason, ReportReason.harassment);
      expect(sent.note, 'keeps messaging me');
      expect(sent.messages, isEmpty, reason: 'messages need the person\'s yes');
      expect(blocked, isEmpty);
      expect(find.text('Report sent. Thank you.'), findsOneWidget);
    });

    testWidgets('attaches the messages only after being told they are sent', (
      tester,
    ) async {
      await open(tester, messages: attached);
      expect(
        find.text(
          'These messages will be sent to the server admin as plain text.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Spam'));
      await tester.tap(find.text('Include the last few messages'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send report'));
      await tester.pumpAndSettle();

      expect(api.sent.single.messages.single.text, 'buy coins');
    });

    testWidgets('has no message option for a chat with nothing to send', (
      tester,
    ) async {
      await open(tester);
      expect(find.text('Include the last few messages'), findsNothing);
    });

    testWidgets('can block them at the same time', (tester) async {
      await open(tester);
      await tester.tap(find.text('Spam'));
      await tester.tap(find.text('Also block Bob'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send report'));
      await tester.pumpAndSettle();

      expect(api.sent, hasLength(1));
      expect(blocked, ['u-bob']);
      expect(find.text('Report sent. Bob is blocked.'), findsOneWidget);
    });

    testWidgets('does not offer to block someone already blocked', (
      tester,
    ) async {
      await open(tester, alreadyBlocked: true);
      expect(find.text('Also block Bob'), findsNothing);
    });

    testWidgets('says so if the report was sent but the block failed', (
      tester,
    ) async {
      await open(tester, block: (_) async => 'No connection');
      await tester.tap(find.text('Something else'));
      await tester.tap(find.text('Also block Bob'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send report'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
      expect(find.textContaining('wasn\'t blocked'), findsOneWidget);
    });

    testWidgets('does not block if the report could not be sent', (
      tester,
    ) async {
      api.fail = Exception('offline');
      await open(tester);
      await tester.tap(find.text('Spam'));
      await tester.tap(find.text('Also block Bob'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Send report'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
      expect(blocked, isEmpty);
      expect(find.textContaining('Couldn\'t send the report'), findsOneWidget);
    });

    testWidgets('sends nothing if cancelled', (tester) async {
      await open(tester);
      await tester.tap(find.text('Spam'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(result, isFalse);
      expect(api.sent, isEmpty);
    });
  });

  group('the chat menu', () {
    testWidgets('offers Report in a direct chat', (tester) async {
      await showTestChat(tester, messages: [testMessage('m1', 'hello')]);
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Report'), findsOneWidget);

      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportDialog), findsOneWidget);
      // The one message in the chat could be attached, if they say so.
      expect(find.text('Include the last few messages'), findsOneWidget);
    });

    testWidgets('does not offer it in a group', (tester) async {
      await showTestChat(
        tester,
        messages: [testMessage('m1', 'hello')],
        isGroup: true,
      );
      await tester.tap(find.byTooltip('More'));
      await tester.pumpAndSettle();
      expect(find.text('Report'), findsNothing);
    });
  });
}
