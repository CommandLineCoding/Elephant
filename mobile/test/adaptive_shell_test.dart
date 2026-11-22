import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/models/inbox_item.dart';
import 'package:mobile/pages/chat/chat_page.dart';
import 'package:mobile/pages/home/conversation_actions.dart';
import 'package:mobile/themes/app_themes.dart';
import 'package:mobile/widgets/adaptive_shell.dart';

import 'chat_harness.dart';

void setScreen(WidgetTester tester, double width, double height) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

final bob = InboxItem(
  id: 'u2',
  title: 'Bob',
  username: 'bob.1234',
  lastMessage: 'hi',
  timestamp: DateTime(2026, 11, 22, 9),
  isGroup: false,
);

/// A stand-in chat list with one row that opens Bob's chat.
class FakeList extends StatelessWidget {
  const FakeList({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => openConversation(context, bob),
        child: const Text('Open Bob'),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(mockPlatformChannels);

  test('a screen is wide from 840 logical pixels', () {
    expect(wideScreenWidth, 840);
  });

  group('the shell', () {
    Future<void> pumpShell(WidgetTester tester, Widget child) =>
        tester.pumpWidget(
          MaterialApp(
            theme: AppThemes.getTheme(ThemeType.frost),
            home: AdaptiveShell(child: child),
          ),
        );

    testWidgets('shows only the list on a narrow screen', (tester) async {
      setScreen(tester, 839, 800);
      await pumpShell(tester, const Text('the list'));
      expect(find.text('the list'), findsOne);
      expect(find.text('Select a chat'), findsNothing);
    });

    testWidgets('shows the list beside an empty pane when wide', (
      tester,
    ) async {
      setScreen(tester, 840, 800);
      await pumpShell(tester, const Text('the list'));
      expect(find.text('the list'), findsOne);
      expect(find.text('Select a chat'), findsOne);
      // The list keeps to its own width.
      expect(
        tester.getTopLeft(find.text('Select a chat')).dx,
        greaterThan(listPaneWidth),
      );
    });

    testWidgets('keeps the list when the screen turns wide', (tester) async {
      setScreen(tester, 600, 800);
      await pumpShell(tester, const _Counter());
      final before = tester.state<_CounterState>(find.byType(_Counter));
      before.bump();
      await tester.pump();
      expect(find.text('count 1'), findsOne);

      setScreen(tester, 1000, 800);
      await tester.pump();
      expect(find.text('Select a chat'), findsOne);
      expect(find.text('count 1'), findsOne, reason: 'the list kept its state');
      expect(
        identical(tester.state<_CounterState>(find.byType(_Counter)), before),
        isTrue,
      );
    });
  });

  group('opening a chat', () {
    Future<TestChat> showHome(WidgetTester tester) => showTestChat(
      tester,
      messages: [testMessage('a', 'hello from bob')],
      wrap: (_) => const AdaptiveShell(child: FakeList()),
    );

    testWidgets('takes over the screen when narrow', (tester) async {
      setScreen(tester, 600, 900);
      await showHome(tester);
      await tester.tap(find.text('Open Bob'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOne);
      expect(find.text('Open Bob'), findsNothing);
    });

    testWidgets('opens beside the list when wide', (tester) async {
      setScreen(tester, 1000, 800);
      await showHome(tester);
      expect(find.text('Select a chat'), findsOne);

      await tester.tap(find.text('Open Bob'));
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsOne);
      expect(
        find.text('Open Bob'),
        findsOne,
        reason: 'the list is still there',
      );
      expect(find.text('Select a chat'), findsNothing);
      expect(find.text('hello from bob'), findsOne);
    });

    testWidgets('another chat replaces the one shown', (tester) async {
      setScreen(tester, 1000, 800);
      await showHome(tester);
      final pane = DetailPane.maybeOf(tester.element(find.text('Open Bob')))!;
      pane.show(const Text('first chat'), chatId: 'a');
      await tester.pumpAndSettle();
      pane.show(const Text('second chat'), chatId: 'b');
      await tester.pumpAndSettle();
      expect(find.text('first chat'), findsNothing);
      expect(find.text('second chat'), findsOne);
      expect(pane.shownChat.value, 'b');

      // One step back is the empty state, not the first chat.
      pane.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('first chat'), findsNothing);
      expect(find.text('Select a chat'), findsOne);
    });

    testWidgets('back in the pane returns to the empty state', (tester) async {
      setScreen(tester, 1000, 800);
      await showHome(tester);
      await tester.tap(find.text('Open Bob'));
      await tester.pumpAndSettle();

      final shell = DetailPane.maybeOf(tester.element(find.text('Open Bob')))!;
      expect(shell.shownChat.value, 'u2');
      shell.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsNothing);
      expect(find.text('Select a chat'), findsOne);
      expect(shell.shownChat.value, isNull);
    });
  });
}

class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;

  void bump() => setState(() => n++);

  @override
  Widget build(BuildContext context) => Text('count $n');
}
